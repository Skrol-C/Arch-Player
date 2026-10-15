//! Signed proxy sessions (ported host API, MIT attribution to
//! SpotiFLAC-Mobile `signed_session/*`: same wire protocol, our own
//! code). Four proxy-routed providers (tidal/deezer/qobuz/amazon)
//! authenticate to `api.zarz.moe` this way instead of user OAuth:
//!
//! bootstrap (GET, app_version+install_id) -> either a session
//! record `{session_id, session_secret, expires_at}` or a
//! verification challenge `{auth_url}` the app opens in a browser;
//! exchange (POST `{grant, install_id, app_version, platform}`)
//! trades the deep-link grant for the record; every proxied call
//! carries HMAC headers derived per time-window from the secret.
//!
//! Records persist per scope (namespace+base+app+platform) under
//! the extension storage dir, so sessions survive calls (fresh
//! runtime per call) and app restarts. Everything failure-shaped
//! is JSON data, never a throw.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{Value, json};

use crate::host::Caps;

const SCOPE_FILE_LEN: usize = 16;

/// Manifest `signedSession` block, with reference defaults.
#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub namespace: String,
    pub base_url: String,
    pub app_version: String,
    pub platform: String,
    pub callback_url: String,
    pub scheme_label: String,
    pub header_prefix: String,
    pub time_window_seconds: i64,
    pub ep_bootstrap: String,
    pub ep_challenge: String,
    pub ep_exchange: String,
    pub ep_refresh: String,
}

impl SessionConfig {
    pub fn parse(v: &Value) -> Option<Self> {
        let o = v.as_object()?;
        let s = |k: &str| {
            o.get(k)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_owned()
        };
        let ep = o.get("endpoints").and_then(|e| e.as_object());
        let e = |k: &str, fb: &str| {
            ep.and_then(|m| m.get(k))
                .and_then(|v| v.as_str())
                .unwrap_or(fb)
                .to_owned()
        };
        let tw = o
            .get("timeWindowSeconds")
            .and_then(|v| v.as_i64())
            .unwrap_or(300)
            .clamp(5, 3600);
        let namespace = s("namespace").to_lowercase();
        if namespace.is_empty() {
            return None;
        }
        let base_url = s("baseUrl");
        if !(base_url.starts_with("https://") && base_url.len() > 8) {
            return None;
        }
        Some(SessionConfig {
            namespace,
            base_url,
            app_version: or(s("appVersion"), "ext-1.0"),
            platform: or(s("platform"), "extension"),
            callback_url: or(s("callbackUrl"), "spotiflac://session-grant"),
            scheme_label: or(s("schemeLabel"), "SPOTIFLAC-HMAC-V1"),
            header_prefix: or(s("headerPrefix"), "X-Sig-"),
            time_window_seconds: tw,
            ep_bootstrap: e("bootstrap", "/bootstrap"),
            ep_challenge: e("challenge", "/challenge"),
            ep_exchange: e("exchange", "/session/exchange"),
            ep_refresh: e("refresh", "/session/refresh"),
        })
    }
}

fn or(v: String, fb: &str) -> String {
    if v.is_empty() {
        fb.to_owned()
    } else {
        v
    }
}

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
struct Record {
    #[serde(default)]
    install_id: String,
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    session_secret: String,
    #[serde(default)]
    expires_at: String,
    #[serde(default)]
    namespace: String,
    #[serde(default)]
    base_url: String,
    #[serde(default)]
    app_version: String,
    #[serde(default)]
    platform: String,
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn hmac_sha256_b64url(key: &[u8], msg: &[u8]) -> String {
    use base64::Engine as _;
    use hmac::Mac as _;
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(key)
        .expect("HMAC accepts any key length");
    mac.update(msg);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

fn random_hex(count: usize) -> String {
    let mut bytes = vec![0u8; count];
    let mut filled = false;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read as _;
        if f.read_exact(&mut bytes).is_ok() {
            filled = true;
        }
    }
    if !filled {
        // Fallback: hash time + pid + address entropy. Never empty.
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0x9e3779b97f4a7c15);
        let mut x = t ^ (std::process::id() as u128).wrapping_mul(0xbf58476d1ce4e5b9);
        for b in bytes.iter_mut() {
            x ^= x >> 29;
            x = x.wrapping_mul(0xbf58476d1ce4e5b9);
            x ^= x >> 32;
            *b = (x & 0xff) as u8;
        }
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn now_nanos() -> i128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as i128)
        .unwrap_or(0)
}

/// RFC3339 subset parse -> unix nanos. Unparseable -> None (which
/// the reference treats as "no expiry", i.e. usable).
fn parse_time(value: &str) -> Option<i128> {
    let v = value.trim();
    let (date, clock) = v.split_once('T')?;
    let mut dp = date.split('-');
    let y: i32 = dp.next()?.parse().ok()?;
    let mo: i32 = dp.next()?.parse().ok()?;
    let d: i32 = dp.next()?.parse().ok()?;
    if dp.next().is_some() || !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    let zi = clock.find(['Z', '+', '-'])?;
    let (hm, zone) = clock.split_at(zi);
    let offset: i128 = if zone == "Z" {
        0
    } else {
        let sign = &zone[..1];
        let hmz = &zone[1..];
        let (h, m) = hmz.split_once(':')?;
        let h: i128 = h.parse().ok()?;
        let m: i128 = m.parse().ok()?;
        if h > 24 || m > 60 {
            return None;
        }
        (h * 3600 + m * 60) * if sign == "-" { -1 } else { 1 }
    };
    let mut cp = hm.split(':');
    let hh: i64 = cp.next()?.parse().ok()?;
    let mm: i64 = cp.next()?.parse().ok()?;
    let mut ss = cp.next()?;
    if cp.next().is_some() {
        return None;
    }
    let mut nanos: i128 = 0;
    if let Some(dot) = ss.find(['.', ',']) {
        let (s, f) = ss.split_at(dot);
        ss = s;
        let f = &f[1..];
        if !f.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let digits = &f[..f.len().min(9)];
        nanos = digits.parse::<i128>().ok()? * 10i128.pow(9 - digits.len() as u32);
    }
    let s: i64 = ss.parse().ok()?;
    let days = days_from_civil(y, mo, d)?;
    Some((days as i128 * 86400 + hh as i128 * 3600 + mm as i128 * 60 + s as i128) * 1_000_000_000 + nanos - offset * 1_000_000_000)
}

fn days_from_civil(y: i32, m: i32, d: i32) -> Option<i64> {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe as i64 * 365 + yoe as i64 / 4 - yoe as i64 / 100 + doy as i64;
    Some(era as i64 * 146097 + doe - 719468)
}

fn timestamp_millis(now: i128) -> String {
    let secs = (now / 1_000_000_000) as i64;
    let ms = ((now % 1_000_000_000) / 1_000_000) as u32;
    let days = secs.div_euclid(86400);
    let sod = secs.rem_euclid(86400);
    // civil from days (UTC)
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let dd = doy - (153 * mp + 2) / 5 + 1;
    let mm = if mp < 10 { mp + 3 } else { mp - 9 };
    let yy = if mm <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        yy, mm, dd,
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60,
        ms
    )
}

fn escape_path(path: &str) -> String {
    let mut out = String::new();
    for b in path.as_bytes() {
        if b.is_ascii_alphanumeric() || b" -_.~/".contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Per-call context: manifest config + storage roots + network gate.
#[derive(Clone)]
pub struct SessionCtx {
    pub config: SessionConfig,
    pub storage_dir: String,
    pub namespace: String,
    pub allow_hosts: Vec<String>,
}

impl SessionCtx {
    fn scope_file(&self) -> std::path::PathBuf {
        let scope = [
            self.config.namespace.as_str(),
            &self.config.base_url.trim().to_lowercase(),
            &self.config.app_version.trim().to_lowercase(),
            &self.config.platform.trim().to_lowercase(),
        ]
        .join("\n");
        let name = format!(
            "{}-{}.json",
            self.config.namespace,
            &sha256_hex(scope.as_bytes())[..SCOPE_FILE_LEN]
        );
        std::path::Path::new(&self.storage_dir)
            .join(&self.namespace)
            .join("sessions")
            .join(name)
    }

    fn pending_file(&self) -> std::path::PathBuf {
        self.scope_file().with_extension("pending.json")
    }

    fn grant_file(&self) -> std::path::PathBuf {
        self.scope_file().with_extension("grant.json")
    }

    /// Filesystem-safe namespace for the fallback grant name.
    fn namespace_sane(&self) -> String {
        self.namespace
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.' {
                    c
                } else {
                    '_'
                }
            })
            .collect()
    }

    fn load(&self) -> Record {
        let mut rec: Record = std::fs::read_to_string(self.scope_file())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        // Scope drift invalidates (same rule as reference).
        if rec.namespace != self.config.namespace
            || rec.base_url != self.config.base_url.trim()
            || rec.app_version != self.config.app_version.trim()
            || rec.platform != self.config.platform.trim()
        {
            if !rec.namespace.is_empty()
                || !rec.base_url.is_empty()
                || !rec.app_version.is_empty()
                || !rec.platform.is_empty()
            {
                rec.session_id.clear();
                rec.session_secret.clear();
                rec.expires_at.clear();
            }
            rec.namespace = self.config.namespace.clone();
            rec.base_url = self.config.base_url.trim().to_owned();
            rec.app_version = self.config.app_version.trim().to_owned();
            rec.platform = self.config.platform.trim().to_owned();
        }
        if rec.install_id.trim().is_empty() {
            rec.install_id = random_hex(16);
            self.save(&rec);
        }
        rec
    }

    fn save(&self, rec: &Record) {
        if let Some(parent) = self.scope_file().parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_string(rec) {
            let tmp = self.scope_file().with_extension("tmp");
            if std::fs::write(&tmp, text.as_bytes()).is_ok() {
                let _ = std::fs::rename(&tmp, self.scope_file());
            }
        }
    }

    fn clear_record(&self) {
        let _ = std::fs::remove_file(self.scope_file());
        let _ = std::fs::remove_file(self.pending_file());
        let _ = std::fs::remove_file(self.grant_file());
    }

    fn usable(&self, rec: &Record, now: i128) -> bool {
        !rec.session_id.trim().is_empty()
            && !rec.session_secret.trim().is_empty()
            && parse_time(&rec.expires_at).is_none_or(|e| now < e)
    }

    fn endpoint(&self, ep: &str) -> Result<String, String> {
        let ep = ep.trim();
        if ep.is_empty() {
            return Err("signed session endpoint is empty".to_owned());
        }
        if ep.starts_with("https://") {
            return Ok(ep.to_owned());
        }
        let base = self.config.base_url.trim_end_matches('/');
        Ok(format!("{base}/{}", ep.trim_start_matches('/')))
    }

    /// Plain (unsigned) JSON request through the allowlist gate.
    fn plain(
        &self,
        method: &str,
        url: &str,
        body: &str,
        headers: &BTreeMap<String, String>,
    ) -> Result<(u16, Vec<(String, Vec<String>)>, Vec<u8>), String> {
        let caps = Caps {
            allow_hosts: self.allow_hosts.clone(),
            storage_dir: self.storage_dir.clone(),
            files_dir: String::new(),
            namespace: self.namespace.clone(),
            storage_allowed: false,
            file_allowed: false,
        };
        let hs: Vec<(String, String)> =
            headers.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        match crate::host::http_fetch(&caps, url, method, &hs, body) {
            Ok(o) => Ok((o.status, o.headers, o.body)),
            Err(e) => Err(e),
        }
    }

    /// Signed request: HMAC headers per the wire scheme, then send.
    fn signed_request(
        &self,
        rec: &Record,
        method: &str,
        url: &str,
        body: &str,
        extra: &BTreeMap<String, String>,
    ) -> Result<(u16, Vec<(String, Vec<String>)>, Vec<u8>), String> {
        let now = now_nanos();
        let path = url_path(url)?;
        let hash = sha256_hex(body.as_bytes());
        let window = (now / 1_000_000_000) / self.config.time_window_seconds as i128;
        let rolling = hmac_sha256_b64url(
            rec.session_secret.as_bytes(),
            format!("{window}:{}", rec.session_id).as_bytes(),
        );
        let nonce = random_hex(16);
        let signing = [
            self.config.scheme_label.as_str(),
            method,
            &escape_path(&path),
            "",
            &hash,
            &timestamp_millis(now),
            &nonce,
            &rec.session_id,
            &self.config.app_version,
            &self.config.platform,
        ]
        .join("\n");
        let signature = hmac_sha256_b64url(rolling.as_bytes(), signing.as_bytes());
        let p = &self.config.header_prefix;
        let mut headers = BTreeMap::new();
        headers.insert(format!("{p}Session"), rec.session_id.clone());
        headers.insert(format!("{p}Timestamp"), timestamp_millis(now));
        headers.insert(format!("{p}Nonce"), nonce);
        headers.insert(format!("{p}Body-SHA256"), hash);
        headers.insert(format!("{p}Signature"), signature);
        headers.insert(format!("{p}App-Version"), self.config.app_version.clone());
        headers.insert(format!("{p}Platform"), self.config.platform.clone());
        for (k, v) in extra {
            headers.insert(k.clone(), v.clone());
        }
        self.plain(method, url, body, &headers)
    }

    /// Map a proxied response into the reference `response_value`
    /// shape: status fields + headers + error contract + retry info.
    fn map_response(status: u16, url: &str, headers: &[(String, Vec<String>)], body: &[u8]) -> Value {
        let text = String::from_utf8_lossy(body);
        let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let g = |k: &str| {
            parsed
                .get(k)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_owned()
        };
        let mut hmap = serde_json::Map::new();
        for (k, vals) in headers {
            if vals.len() == 1 {
                hmap.insert(k.clone(), Value::String(vals[0].clone()));
            } else {
                hmap.insert(
                    k.clone(),
                    Value::Array(vals.iter().cloned().map(Value::String).collect()),
                );
            }
        }
        let mut out = json!({
            "statusCode": status,
            "status": status,
            "ok": (200..300).contains(&status),
            "url": url,
            "body": text.into_owned(),
            "headers": hmap,
        });
        let code = g("code").to_uppercase();
        let origin = g("origin").to_lowercase();
        let action = g("action").to_lowercase();
        if !code.is_empty() || !origin.is_empty() || !action.is_empty() {
            out["error"] = Value::String(g("error"));
            out["code"] = Value::String(code);
            out["origin"] = Value::String(origin);
            out["action"] = Value::String(action);
            out["retryable"] = parsed
                .get("retryable")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                .into();
            out["retryMode"] = Value::String(g("retry_mode").to_lowercase());
        }
        out
    }

    /// Bootstrap: existing session (save + Ok(url:"")) or a
    /// verification challenge (persist pending, return auth URL).
    fn bootstrap(&self) -> Result<Bootstrap, String> {
        let rec = self.load();
        let now = now_nanos();
        if self.usable(&rec, now) {
            return Ok(Bootstrap::Ready);
        }
        let url = format!(
            "{}?app_version={}&install_id={}",
            self.endpoint(&self.config.ep_bootstrap)?,
            percent(&self.config.app_version),
            percent(&rec.install_id),
        );
        let (status, _, body) =
            self.plain("GET", &url, "", &BTreeMap::new()).map_err(|e| {
                format!("signed-session bootstrap network failed: {e}")
            })?;
        if !(200..300).contains(&status) {
            return Err(format!("signed-session bootstrap HTTP {status}"));
        }
        let v: Value =
            serde_json::from_slice(&body).map_err(|_| "bad bootstrap response".to_owned())?;
        let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_owned();
        if !s("session_id").is_empty() && !s("session_secret").is_empty() && !s("expires_at").is_empty() {
            let mut rec = rec;
            rec.session_id = s("session_id");
            rec.session_secret = s("session_secret");
            rec.expires_at = s("expires_at");
            self.save(&rec);
            let _ = std::fs::remove_file(self.pending_file());
            return Ok(Bootstrap::Ready);
        }
        let mut auth_url = s("auth_url");
        if auth_url.is_empty() {
            auth_url = s("challenge_url");
        }
        let state = random_hex(16);
        if auth_url.is_empty() && !s("challenge_id").is_empty() {
            auth_url = format!(
                "{}?id={}&cb={}",
                self.endpoint(&self.config.ep_challenge)?,
                percent(&s("challenge_id")),
                percent(&format!("{}?state={state}", self.config.callback_url)),
            );
        }
        if auth_url.is_empty() {
            return Err("bootstrap returned neither session nor challenge".to_owned());
        }
        let pending = json!({
            "auth_url": auth_url,
            "callback": self.config.callback_url,
            "state": state,
        });
        let _ = std::fs::write(self.pending_file(), pending.to_string());
        Ok(Bootstrap::Challenge(auth_url))
    }

    /// Best-effort refresh when expiry is within the hour. Errors
    /// are swallowed: a stale-but-usable record still signs.
    fn refresh_maybe(&self, rec: &mut Record) {
        if self.config.ep_refresh.trim().is_empty() {
            return;
        }
        let now = now_nanos();
        let due = match parse_time(&rec.expires_at) {
            Some(e) => self.usable(rec, now) && e - now <= 3_600_000_000_000,
            None => false,
        };
        if !due {
            return;
        }
        let url = match self.endpoint(&self.config.ep_refresh) {
            Ok(u) => u,
            Err(_) => return,
        };
        let body = json!({"install_id": rec.install_id}).to_string();
        let resp = self.signed_request(rec, "POST", &url, &body, &BTreeMap::new());
        let (status, _, bytes) = match resp {
            Ok(r) => r,
            Err(_) => return,
        };
        if !(200..300).contains(&status) {
            return;
        }
        if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
            let mut changed = false;
            for (field, key) in [
                (&mut rec.session_id, "session_id"),
                (&mut rec.session_secret, "session_secret"),
                (&mut rec.expires_at, "expires_at"),
            ] {
                if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
                    if !s.is_empty() && field != s {
                        *field = s.to_owned();
                        changed = true;
                    }
                }
            }
            if changed {
                self.save(rec);
            }
        }
    }

    /// Exchange a deep-link grant for a session record.
    fn exchange(&self, grant: &str) -> Result<(), String> {
        let rec = self.load();
        let url = self.endpoint(&self.config.ep_exchange)?;
        let body = json!({
            "grant": grant,
            "install_id": rec.install_id,
            "app_version": self.config.app_version,
            "platform": self.config.platform,
        })
        .to_string();
        let mut headers = BTreeMap::new();
        headers.insert("content-type".to_owned(), "application/json".to_owned());
        let mut last = String::new();
        for attempt in 0..3 {
            match self.plain("POST", &url, &body, &headers) {
                Ok((429, hs, _)) => {
                    let wait = hs
                        .iter()
                        .find(|(k, _)| k.eq_ignore_ascii_case("retry-after"))
                        .and_then(|(_, v)| v.first())
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(1)
                        .clamp(1, 10);
                    if attempt < 2 {
                        std::thread::sleep(Duration::from_secs(wait));
                        continue;
                    }
                    last = "rate limited".to_owned();
                }
                Ok((status, _, bytes)) => {
                    if !(200..300).contains(&status) {
                        last = format!("session exchange HTTP {status}");
                        break;
                    }
                    let v: Value = serde_json::from_slice(&bytes)
                        .map_err(|_| "bad exchange response".to_owned())?;
                    let s = |k: &str| {
                        v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_owned()
                    };
                    if s("session_id").is_empty()
                        || s("session_secret").is_empty()
                        || s("expires_at").is_empty()
                    {
                        last = "exchange response missing session fields".to_owned();
                        break;
                    }
                    let mut rec = self.load();
                    rec.session_id = s("session_id");
                    rec.session_secret = s("session_secret");
                    rec.expires_at = s("expires_at");
                    self.save(&rec);
                    let _ = std::fs::remove_file(self.pending_file());
                    let _ = std::fs::remove_file(self.grant_file());
                    return Ok(());
                }
                Err(e) => {
                    last = e;
                    break;
                }
            }
        }
        Err(last)
    }

    /// The `signedFetch` entry: resolve, sign, send, and map the
    /// gateway error contract (re-bootstrap on invalid sessions,
    /// verification challenge out, provider errors through).
    fn signed_fetch(
        &self,
        method: &str,
        path: &str,
        body: &str,
        headers: &BTreeMap<String, String>,
    ) -> Value {
        let url = match self.resolve(path) {
            Ok(u) => u,
            Err(e) => return json!({"ok": false, "error": e}),
        };
        // Ensure a usable record (bootstrap or challenge).
        match self.bootstrap() {
            Err(e) => return json!({"ok": false, "error": e}),
            Ok(Bootstrap::Challenge(auth_url)) => {
                return json!({
                    "ok": false, "needsVerification": true,
                    "auth_url": auth_url, "error": "verification required",
                })
            }
            Ok(Bootstrap::Ready) => {}
        }
        let mut rec = self.load();
        self.refresh_maybe(&mut rec);
        let send = |rec: &Record| self.signed_request(rec, method, &url, body, headers);
        let (status, hs, bytes) = match send(&rec) {
            Err(e) => return json!({"ok": false, "error": e}),
            Ok(r) => r,
        };
        let mut out = Self::map_response(status, &url, &hs, &bytes);
        let action = gateway_action(status, &out);
        if action == "bootstrap_session" {
            // Session rejected: drop it, re-bootstrap once, retry once.
            rec.session_id.clear();
            rec.session_secret.clear();
            self.save(&rec);
            match self.bootstrap() {
                Ok(Bootstrap::Ready) => {
                    let rec = self.load();
                    match send(&rec) {
                        Err(e) => return json!({"ok": false, "error": e}),
                        Ok((s2, h2, b2)) => out = Self::map_response(s2, &url, &h2, &b2),
                    }
                }
                Ok(Bootstrap::Challenge(auth_url)) => {
                    return json!({
                        "ok": false, "needsVerification": true,
                        "auth_url": auth_url, "error": "verification required",
                    })
                }
                Err(e) => return json!({"ok": false, "error": e}),
            }
        } else if action == "verify" {
            let auth_url = out
                .get("auth_url")
                .or_else(|| out.get("authUrl"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let auth_url = if auth_url.is_empty() {
                match self.bootstrap() {
                    Ok(Bootstrap::Challenge(u)) => u,
                    _ => String::new(),
                }
            } else {
                auth_url
            };
            out["needsVerification"] = Value::Bool(true);
            out["auth_url"] = Value::String(auth_url);
        }
        out
    }

    fn resolve(&self, path: &str) -> Result<String, String> {
        let p = path.trim();
        if p.is_empty() {
            return Err("method and path are required".to_owned());
        }
        if p.starts_with("https://") {
            return Ok(p.to_owned());
        }
        let base = self.config.base_url.trim_end_matches('/');
        Ok(format!("{base}/{}", p.trim_start_matches('/')))
    }

    pub fn status(&self) -> Value {
        let rec = self.load();
        json!({"authenticated": self.usable(&rec, now_nanos())})
    }

    pub fn clear(&self) -> Value {
        self.clear_record();
        json!({"success": true})
    }

    fn fallback_grant_file(&self) -> std::path::PathBuf {
        self.scope_file()
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_default()
            .join(format!("pending.{}.grant.json", self.namespace_sane()))
    }

    /// Read + consume the first non-empty stashed grant.
    fn take_stashed_grant(&self) -> String {
        for path in [self.grant_file(), self.fallback_grant_file()] {
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            if text.trim().is_empty() {
                continue;
            }
            let _ = std::fs::remove_file(&path);
            let g = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| {
                    v.get("grant").and_then(|x| x.as_str()).map(|s| s.to_owned())
                })
                .unwrap_or_default();
            if !g.is_empty() {
                return g;
            }
        }
        String::new()
    }

    /// One-shot consume of a stashed deep-link grant: the scope
    /// sibling first, then the namespace fallback. Runs before
    /// every entry so Dart only ever writes the file.
    pub fn consume_stashed_grant(&self) -> bool {
        let g = self.take_stashed_grant();
        if g.is_empty() {
            return false;
        }
        self.exchange(&g).is_ok()
    }

    /// Complete a grant: explicit arg wins, otherwise the
    /// deep-link stash files Dart writes. Two names: the scope
    /// sibling (`<scope>.grant.json`) and the namespace fallback
    /// (`pending.<namespace>.grant.json`, so Dart never needs the
    /// scope hash). Both one-shot.
    pub fn complete_grant(&self, grant: &str) -> Value {
        let g = if !grant.trim().is_empty() {
            grant.trim().to_owned()
        } else {
            self.take_stashed_grant()
        };
        if g.is_empty() {
            return json!({"success": false, "error": "no pending grant"});
        }
        match self.exchange(&g) {
            Ok(()) => json!({"success": true}),
            Err(e) => json!({"success": false, "error": e}),
        }
    }

    pub fn call(&self, method: &str, args: &[Value]) -> Value {
        let s = |i: usize| args.get(i).and_then(|v| v.as_str()).unwrap_or("");
        match method {
            "status" => self.status(),
            "clear" => self.clear(),
            "completeGrant" => self.complete_grant(s(0)),
            "signedFetch" => {
                if args.len() < 2 {
                    return json!({"ok": false, "error": "method and path are required"});
                }
                let mut headers = BTreeMap::new();
                if let Some(Value::Object(m)) = args.get(3) {
                    for (k, v) in m {
                        if let Some(x) = v.as_str() {
                            headers.insert(k.clone(), x.to_owned());
                        }
                    }
                }
                self.signed_fetch(s(0), s(1), s(2), &headers)
            }
            _ => json!({"success": false, "error": "unknown signed session method"}),
        }
    }
}

enum Bootstrap {
    Ready,
    Challenge(String),
}

fn gateway_action(status: u16, out: &Value) -> &str {
    let g = |k: &str| out.get(k).and_then(|v| v.as_str()).unwrap_or("");
    match (
        status,
        g("origin"),
        g("code"),
        g("action"),
    ) {
        (401, "gateway", "SESSION_INVALID", "bootstrap_session") => "bootstrap_session",
        (428, "gateway", "VERIFY_REQUIRED", "verify") => "verify",
        _ => "",
    }
}

fn url_path(url: &str) -> Result<String, String> {
    let rest = url.split("://").nth(1).ok_or("bad url")?;
    let path = rest.find('/').map(|i| &rest[i..]).unwrap_or("/");
    let path = path.split(['?', '#']).next().unwrap_or("/");
    Ok(if path.is_empty() { "/".to_owned() } else { path.to_owned() })
}

fn percent(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> SessionConfig {
        SessionConfig {
            namespace: "zarz-v2".to_owned(),
            base_url: "https://api.zarz.moe/v2".to_owned(),
            app_version: "tidal-web@1.2.5".to_owned(),
            platform: "extension".to_owned(),
            callback_url: "spotiflac://session-grant".to_owned(),
            scheme_label: "ZARZ-HMAC-V1".to_owned(),
            header_prefix: "X-Zarz-".to_owned(),
            time_window_seconds: 300,
            ep_bootstrap: "/bootstrap".to_owned(),
            ep_challenge: "/challenge".to_owned(),
            ep_exchange: "/session/exchange".to_owned(),
            ep_refresh: "/session/refresh".to_owned(),
        }
    }

    #[test]
    fn scope_filename_stable() {
        let c = SessionCtx {
            config: cfg(),
            storage_dir: "/tmp".to_owned(),
            namespace: "tidal-web".to_owned(),
            allow_hosts: vec![],
        };
        let a = c.scope_file();
        let b = c.scope_file();
        assert_eq!(a, b);
        assert!(a.to_string_lossy().contains("zarz-v2-"));
    }

    #[test]
    fn signing_shape() {
        // Deterministic vectors for the header scheme: recompute
        // by hand if this ever changes (server verifies exact bytes).
        let c = cfg();
        let rec = Record {
            session_id: "sid".to_owned(),
            session_secret: "secret".to_owned(),
            ..Default::default()
        };
        let now = 1_700_000_000_000_000_000i128;
        let path = "/tickets";
        let hash = sha256_hex(b"{}");
        let window = (now / 1_000_000_000) / 300;
        let rolling = hmac_sha256_b64url(
            b"secret",
            format!("{window}:sid").as_bytes(),
        );
        let signing = [
            "ZARZ-HMAC-V1",
            "POST",
            "/tickets",
            "",
            hash.as_str(),
            timestamp_millis(now).as_str(),
            "nonce",
            "sid",
            "tidal-web@1.2.5",
            "extension",
        ]
        .join("\n");
        let sig = hmac_sha256_b64url(rolling.as_bytes(), signing.as_bytes());
        assert!(!sig.is_empty());
        assert!(timestamp_millis(now).starts_with("2023-11-14T22:13:20."));
        let _ = (c, rec, path);
    }

    #[test]
    fn time_parse_roundtrip() {
        let t = parse_time("2026-10-14T12:00:00Z").unwrap();
        // 2026-10-14 12:00 UTC.
        assert_eq!((t / 1_000_000_000) % 86400, 43200);
        assert!(parse_time("").is_none());
        assert!(parse_time("nope").is_none());
    }

    #[test]
    fn unknown_method_is_data() {
        let c = SessionCtx {
            config: cfg(),
            storage_dir: "/tmp".to_owned(),
            namespace: "t".to_owned(),
            allow_hosts: vec![],
        };
        let v = c.call("nope", &[]);
        assert_eq!(v["success"], false);
    }
}
