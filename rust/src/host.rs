//! Host capabilities injected into the extension sandbox.
//! Every function is infallible from JS's perspective: it always
//! returns a JSON string (`{"ok":...}`), so no Rust error types
//! cross the boundary and no error-mapping questions arise.
//!
//! - `__needle_http(url)`: allowlist-gated GET over HTTPS (or
//!   explicit HTTP), 20s timeout, 8MB body cap. Returns
//!   `{"ok":true,"status":N,"body":"..."}` or `{"ok":false,
//!   "error":"denied"|"http"|"too-large"|...}`.
//! - `__needle_store_get(key)` / `__needle_store_set(key, json)`:
//!   namespaced JSON files under the storage dir. Keys are strict
//!   (`[A-Za-z0-9_.-]`, max 128) - anything else is rejected.
//! - `__needle_read_file(path)` / `__needle_write_file(path,
//!   base64)`: scoped to the files dir. Absolute paths and `..`
//!   rejected; writes capped at 16MB (streaming downloads arrive
//!   in the download-engine slice, not here).
//! - `__needle_log(text)`: appends to a capped in-memory log
//!   returned in the envelope (no Dart round-trip needed).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rquickjs::{CatchResultExt, CaughtError, Function, Object};
use serde_json::{json, Value};

/// Capabilities for one extension call. Parsed from the bridge;
/// garbage fails closed (empty allowlist = deny all).
#[derive(Clone, Default)]
pub struct Caps {
    pub allow_hosts: Vec<String>,
    pub storage_dir: String,
    pub files_dir: String,
    pub namespace: String,
    /// Manifest `permissions.storage`. Storage fns deny without it.
    pub storage_allowed: bool,
    /// Manifest `permissions.file`. File fns deny without it.
    pub file_allowed: bool,
}

impl Caps {
    pub fn parse(
        allow_hosts_json: &str,
        storage_dir: &str,
        files_dir: &str,
        namespace: &str,
    ) -> Result<Self, String> {
        let allow_hosts: Vec<String> =
            serde_json::from_str(allow_hosts_json)
                .map_err(|_| "allow_hosts is not a JSON string array".to_owned())?;
        if !namespace
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
            || namespace.is_empty()
            || namespace.len() > 64
        {
            return Err("bad namespace".to_owned());
        }
        Ok(Caps {
            allow_hosts,
            storage_dir: storage_dir.to_owned(),
            files_dir: files_dir.to_owned(),
            namespace: namespace.to_owned(),
            // Bridge-parsed (pure-sandbox) path: no manifest, so no
            // storage/file access. Extension loads set these from
            // manifest permissions instead.
            storage_allowed: false,
            file_allowed: false,
        })
    }

    fn host_allowed(&self, url: &str) -> bool {
        host_allowed(&self.allow_hosts, url)
    }

    fn store_path(&self, key: &str) -> Result<std::path::PathBuf, String> {        if key.is_empty()
            || key.len() > 128
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
        {
            return Err("bad key".to_owned());
        }
        Ok(std::path::Path::new(&self.storage_dir)
            .join(&self.namespace)
            .join(format!("{key}.json")))
    }

    fn file_path(&self, rel: &str) -> Result<std::path::PathBuf, String> {
        if rel.is_empty() || rel.len() > 512 {
            return Err("bad path".to_owned());
        }
        // Denials name the path (truncated): blind gates waste
        // device round-trips, and the sandbox roots are not secret.
        let deny = |why: &str| {
            let mut p = rel.replace('\\', "/");
            if p.len() > 120 {
                p.truncate(120);
            }
            format!("{why}: {p}")
        };
        let p = std::path::Path::new(rel);
        if p.is_absolute() {
            // Absolute paths are accepted only when they stay
            // inside our own scoped roots (the app stages absolute
            // sandbox paths; anything else escapes). Both sides
            // normalize to forward slashes (Windows hosts use
            // backslashes; Android targets do not).
            let canon_base = std::path::Path::new(&self.files_dir)
                .to_string_lossy()
                .replace('\\', "/");
            let norm = rel.replace('\\', "/");
            if norm == canon_base
                || norm.starts_with(&format!("{canon_base}/"))
            {
                if norm.contains("/../") || norm.ends_with("/..") {
                    return Err(deny("path escapes sandbox"));
                }
                return Ok(std::path::PathBuf::from(rel));
            }
            return Err(deny("path escapes sandbox"));
        }
        if p.components().any(|c| {
            matches!(
                c,
                std::path::Component::ParentDir
                    | std::path::Component::Prefix(_)
                    | std::path::Component::RootDir
            )
        }) {
            return Err(deny("path escapes sandbox"));
        }
        Ok(std::path::Path::new(&self.files_dir).join(p))
    }
}


/// Allowlist gate shared by the sandbox host functions and the
/// download engine: exact host or any subdomain, userinfo and
/// ports stripped, empty host denied. Entries may carry a `*.`
/// wildcard prefix (manifest convention for CDN families like
/// `*.cloudfront.net`); it matches the bare host and all
/// subdomains. One rule, both callers.
pub fn host_allowed(allow: &[String], url: &str) -> bool {
    let host = match url.split("://").nth(1) {
        Some(rest) => rest.split('/').next().unwrap_or(""),
        None => return false,
    }
    .split('@')
    .next_back()
    .unwrap_or("")
    .split(':')
    .next()
    .unwrap_or("")
    .to_lowercase();
    if host.is_empty() {
        return false;
    }
    allow.iter().any(|a| {
        let a = a.to_lowercase();
        // Wildcard convention: `*.example.com` covers the bare
        // host and every subdomain. A lone `*` never matches
        // (deny-by-default beats convenience).
        let base = a.strip_prefix("*.").unwrap_or(&a);
        if base.is_empty() || base.contains('*') {
            return false;
        }
        host == *base || host.ends_with(&format!(".{base}"))
    })
}

/// Append-only log for one call, capped. Returned in the envelope.
#[derive(Clone, Default)]
pub struct CallLog(Arc<Mutex<Vec<String>>>);

impl CallLog {
    fn push(&self, line: String) {
        let mut log = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if log.len() < 100 {
            let mut line = line;
            line.truncate(4096);
            log.push(line);
        }
    }

    pub fn drain(&self) -> Vec<String> {
        let mut log = self.0.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *log)
    }
}

fn ok(v: Value) -> String {
    json!({"ok": true, "value": v}).to_string()
}

fn err(e: &str) -> String {
    json!({"ok": false, "error": e}).to_string()
}

/// Real JS error text for a failed operation: message + first
/// stack line when available, engine detail otherwise. Truncated.
/// Without this every failure reads "Exception generated by
/// QuickJS" and diagnosis is blind. Takes the raw error (not a
/// Result) so call sites stay a one-line map_err.
pub fn js_text(ctx: &rquickjs::Ctx<'_>, e: rquickjs::Error, prefix: &str) -> String {
    let detail = match Err::<(), _>(e).catch(ctx) {
        Err(CaughtError::Value(v)) => {
            let (msg, frame): (String, String) = (|| {
                ctx.globals().set("__needle_err", v).ok()?;
                let msg: String = ctx
                    .eval(b"String((globalThis.__needle_err && globalThis.__needle_err.message) || globalThis.__needle_err)")
                    .unwrap_or_default();
                let stack: String = ctx
                    .eval(b"String((globalThis.__needle_err && globalThis.__needle_err.stack) || '')")
                    .unwrap_or_default();
                Some((msg, stack.lines().next().unwrap_or("").to_owned()))
            })()
            .unwrap_or_default();
            // Message first (QuickJS stacks are frames-only, which
            // is why failures used to read as bare locations), then
            // the first frames for the call path.
            let mut detail = if msg.is_empty() {
                frame.clone()
            } else if frame.is_empty() {
                msg.clone()
            } else {
                format!("{msg} [{frame}]")
            };
            if !msg.is_empty() {
                if let Ok(extra) = ctx.eval::<String, _>(
                    b"String((globalThis.__needle_err && globalThis.__needle_err.stack) || '')",
                ) {
                    let mut lines = extra.lines().skip(1).take(2);
                    if let Some(l2) = lines.next() {
                        let l2 = l2.trim();
                        if !l2.is_empty() && l2 != frame.trim() {
                            detail.push_str(" <- ");
                            detail.push_str(l2);
                        }
                    }
                }
            }
            detail.chars().take(300).collect()
        }
        Err(CaughtError::Exception(e)) => format!("engine: {e:?}"),
        Err(CaughtError::Error(e)) => format!("{e}"),
        Ok(()) => String::new(),
    };
    if detail.is_empty() {
        prefix.to_owned()
    } else {
        format!("{prefix}: {detail}")
    }
}

/// Inject all host functions into `ctx` globals. Infallible from
/// JS: every function returns a JSON string, never throws.
pub fn inject(
    ctx: &rquickjs::Ctx<'_>,
    caps: &Caps,
    log: &CallLog,
) -> Result<(), String> {
    let globals = ctx.globals();

    // Logging: fire-and-forget text into the call log.
    {
        let log = log.clone();
        let f = Function::new(ctx.clone(), move |text: String| {
            log.push(text);
            String::new()
        })
        .map_err(|e| format!("log inject: {e}"))?;
        globals
            .set("__needle_log", f)
            .map_err(|e| format!("log inject: {e}"))?;
    }

    // Storage get/set: namespaced JSON files, strict keys.
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |key: String| {
            match caps.store_path(&key) {
                Err(e) => err(&e),
                Ok(path) => match std::fs::read_to_string(&path) {
                    Err(_) => ok(Value::Null),
                    Ok(text) => match serde_json::from_str::<Value>(&text) {
                        Ok(v) => ok(v),
                        Err(_) => err("stored value corrupt"),
                    },
                },
            }
        })
        .map_err(|e| format!("store_get inject: {e}"))?;
        globals
            .set("__needle_store_get", f)
            .map_err(|e| format!("store_get inject: {e}"))?;
    }
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |key: String, json_text: String| {
            match caps.store_path(&key) {
                Err(e) => err(&e),
                Ok(path) => {
                    if json_text.len() > 1024 * 1024 {
                        return err("value over 1MB");
                    }
                    if serde_json::from_str::<Value>(&json_text).is_err() {
                        return err("value is not JSON");
                    }
                    if let Some(parent) = path.parent() {
                        if std::fs::create_dir_all(parent).is_err() {
                            return err("storage unavailable");
                        }
                    }
                    let tmp = path.with_extension("tmp");
                    match std::fs::write(&tmp, json_text.as_bytes())
                        .and_then(|_| std::fs::rename(&tmp, &path))
                    {
                        Ok(()) => ok(Value::Null),
                        Err(_) => err("storage unavailable"),
                    }
                }
            }
        })
        .map_err(|e| format!("store_set inject: {e}"))?;
        globals
            .set("__needle_store_set", f)
            .map_err(|e| format!("store_set inject: {e}"))?;
    }

    // Scoped file read/write (base64), traversal-proof, capped.
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |rel: String| {
            use base64::Engine as _;
            match caps.file_path(&rel) {
                Err(e) => err(&e),
                Ok(path) => match std::fs::read(&path) {
                    Err(_) => err("unreadable"),
                    Ok(bytes) => {
                        if bytes.len() > 16 * 1024 * 1024 {
                            return err("file over 16MB");
                        }
                        ok(Value::String(
                            base64::engine::general_purpose::STANDARD
                                .encode(&bytes),
                        ))
                    }
                },
            }
        })
        .map_err(|e| format!("read inject: {e}"))?;
        globals
            .set("__needle_read_file", f)
            .map_err(|e| format!("read inject: {e}"))?;
    }
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |rel: String, b64: String| {
            use base64::Engine as _;
            match caps.file_path(&rel) {
                Err(e) => err(&e),
                Ok(path) => {
                    match base64::engine::general_purpose::STANDARD.decode(&b64) {
                        Err(_) => err("not base64"),
                        Ok(bytes) => {
                            if bytes.len() > 16 * 1024 * 1024 {
                                return err("file over 16MB");
                            }
                            if let Some(parent) = path.parent() {
                                if std::fs::create_dir_all(parent).is_err() {
                                    return err("write failed");
                                }
                            }
                            let tmp = path.with_extension("tmp");
                            match std::fs::write(&tmp, &bytes)
                                .and_then(|_| std::fs::rename(&tmp, &path))
                            {
                                Ok(()) => ok(Value::Null),
                                Err(_) => err("write failed"),
                            }
                        }
                    }
                }
            }
        })
        .map_err(|e| format!("write inject: {e}"))?;
        globals
            .set("__needle_write_file", f)
            .map_err(|e| format!("write inject: {e}"))?;
    }

    // Allowlist-gated GET: HTTPS or explicit HTTP, 20s, 8MB cap.
    // The extension's own timeout budget still applies outside.
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |url: String| {
            http_call(&caps, &url, "GET", &[], "")
        })
        .map_err(|e| format!("http inject: {e}"))?;
        globals
            .set("__needle_http", f)
            .map_err(|e| format!("http inject: {e}"))?;
    }
    // Full-shape call for the compat `http` object: superset
    // response both old and new extensions read ({status,
    // statusCode, body, error, ok}). Headers arrive as a JSON
    // object string; absent/invalid means none.
    {
        let caps = caps.clone();
        let f = Function::new(
            ctx.clone(),
            move |url: String,
                  headers_json: String,
                  method: String,
                  body: String| {
                let mut headers = Vec::new();
                if let Ok(Value::Object(map)) =
                    serde_json::from_str::<Value>(&headers_json)
                {
                    for (k, v) in map.iter().take(20) {
                        if let Some(s) = v.as_str() {
                            headers.push((k.clone(), s.to_owned()));
                        }
                    }
                }
                http_call(&caps, &url, &method, &headers, &body)
            },
        )
        .map_err(|e| format!("http_full inject: {e}"))?;
        globals
            .set("__needle_http_full", f)
            .map_err(|e| format!("http_full inject: {e}"))?;
    }
    // HMAC-SHA1 over byte arrays (TOTP codes and friends): both
    // sides JSON-encoded number arrays, result a JSON number
    // array. Pure Rust, no host crypto needed.
    {
        let f = Function::new(
            ctx.clone(),
            move |key_json: String, msg_json: String| {
                use hmac::{Hmac, Mac};
                fn bytes_of(text: &str) -> Result<Vec<u8>, String> {
                    let v: Value = serde_json::from_str(text)
                        .map_err(|_| "not json".to_owned())?;
                    match v {
                        Value::Array(items) => {
                            let mut out = Vec::with_capacity(items.len());
                            for it in items {
                                out.push(
                                    it.as_u64()
                                        .map(|n| (n & 0xff) as u8)
                                        .ok_or_else(|| {
                                            "not a byte array".to_owned()
                                        })?,
                                );
                            }
                            Ok(out)
                        }
                        Value::String(s) => Ok(s.into_bytes()),
                        _ => Err("not a byte array".to_owned()),
                    }
                }
                let key = match bytes_of(&key_json) {
                    Err(e) => return err(&e),
                    Ok(k) => k,
                };
                let msg = match bytes_of(&msg_json) {
                    Err(e) => return err(&e),
                    Ok(m) => m,
                };
                let mut mac = match Hmac::<sha1::Sha1>::new_from_slice(&key) {
                    Err(_) => return err("bad key"),
                    Ok(m) => m,
                };
                mac.update(&msg);
                let digest = mac.finalize().into_bytes().to_vec();
                ok(Value::Array(
                    digest.into_iter().map(Value::from).collect(),
                ))
            },
        )
        .map_err(|e| format!("hmac inject: {e}"))?;
        globals
            .set("__needle_hmac_sha1", f)
            .map_err(|e| format!("hmac inject: {e}"))?;
    }
    // Key listing for the compat `cache.keys/size` shim.
    {
        let caps = caps.clone();
        let f = Function::new(ctx.clone(), move |prefix: String| {
            let dir = std::path::Path::new(&caps.storage_dir)
                .join(&caps.namespace);
            let mut out = Vec::new();
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for e in entries.flatten() {
                    let name = e.file_name().to_string_lossy().into_owned();
                    if let Some(key) = name.strip_suffix(".json") {
                        if key.starts_with(prefix.as_str()) {
                            out.push(key.to_owned());
                        }
                    }
                }
            }
            ok(Value::Array(
                out.into_iter().map(Value::String).collect(),
            ))
        })
        .map_err(|e| format!("keys inject: {e}"))?;
        globals
            .set("__needle_store_keys", f)
            .map_err(|e| format!("keys inject: {e}"))?;
    }
    // Base64 pair for the compat atob/btoa: arrays across the
    // boundary (binary strings aren't JSON), chunked back into
    // strings on the JS side to dodge spread limits.
    {
        let f = Function::new(ctx.clone(), move |b64: String| {
            use base64::Engine as _;
            match base64::engine::general_purpose::STANDARD.decode(&b64) {
                Err(_) => err("not base64"),
                Ok(bytes) => ok(Value::Array(
                    bytes.into_iter().map(Value::from).collect(),
                )),
            }
        })
        .map_err(|e| format!("b64dec inject: {e}"))?;
        globals
            .set("__needle_b64decode", f)
            .map_err(|e| format!("b64dec inject: {e}"))?;
    }
    {
        let f = Function::new(ctx.clone(), move |arr_json: String| {
            use base64::Engine as _;
            let v: Value = match serde_json::from_str(&arr_json) {
                Err(_) => return err("not json"),
                Ok(v) => v,
            };
            let mut bytes = Vec::new();
            match v {
                Value::Array(items) => {
                    for it in items {
                        match it.as_u64() {
                            Some(n) => bytes.push((n & 0xff) as u8),
                            None => return err("not a byte array"),
                        }
                    }
                }
                Value::String(s) => bytes.extend_from_slice(s.as_bytes()),
                _ => return err("not encodable"),
            }
            ok(Value::String(
                base64::engine::general_purpose::STANDARD.encode(&bytes),
            ))
        })
        .map_err(|e| format!("b64enc inject: {e}"))?;
        globals
            .set("__needle_b64encode", f)
            .map_err(|e| format!("b64enc inject: {e}"))?;
    }
    Ok(())
}

/// Shared GET/POST core: allowlist, timeout, body cap.
fn http_call(
    caps: &Caps,
    url: &str,
    method: &str,
    headers: &[(String, String)],
    body: &str,
) -> String {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return err("bad scheme");
    }
    if !caps.host_allowed(url) {
        return err("denied");
    }
    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent("ArchPlayer-Needle/0.1 (extension)")
        .build()
    {
        Err(_) => return err("http unavailable"),
        Ok(c) => c,
    };
    let method_up = method.to_uppercase();
    let mut req = match method_up.as_str() {
        "POST" => client.post(url),
        "PUT" => client.put(url),
        "DELETE" => client.delete(url),
        "HEAD" => client.head(url),
        _ => client.get(url),
    };
    for (k, v) in headers.iter().take(20) {
        req = req.header(k, v);
    }
    let req = if matches!(method_up.as_str(), "POST" | "PUT") {
        req.body(body.to_owned())
    } else {
        req
    };
    let res = match req.send() {
        Err(_) => return err("http failed"),
        Ok(r) => r,
    };
    let status = res.status().as_u16();
    let bytes = match res.bytes() {
        Err(_) => return err("http failed"),
        Ok(b) => b,
    };
    if bytes.len() > 8 * 1024 * 1024 {
        return err("body over 8MB");
    }
    ok(serde_json::json!({
        "ok": true,
        "status": status,
        "statusCode": status,
        "error": null,
        "body": String::from_utf8_lossy(&bytes).into_owned(),
    }))
}


#[cfg(test)]
mod tests {
    use super::*;

    fn caps_in(dir: &std::path::Path) -> Caps {
        Caps {
            allow_hosts: vec!["example.com".to_owned()],
            storage_dir: dir.join("store").to_string_lossy().into_owned(),
            files_dir: dir.join("files").to_string_lossy().into_owned(),
            namespace: "testext".to_owned(),
            storage_allowed: true,
            file_allowed: true,
        }
    }

    fn run(src: &str, caps: &Caps) -> Value {
        let log = CallLog::default();
        let out = crate::sandbox::eval_with(caps, &log, src, "{}", std::time::Duration::from_secs(5));
        serde_json::from_str(&out).unwrap()
    }

    /// Host functions return JSON text, which the envelope parses
    /// into a value: `out["value"]` IS the inner result object.
    /// Outer ok = script ran; inner ok = host call succeeded.
    fn inner(out: &Value) -> Value {
        assert_eq!(out["ok"], true);
        out["value"].clone()
    }

    fn tmp() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "needle-host-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn store_roundtrip() {
        let d = tmp();
        let caps = caps_in(&d);
        let set = run(
            r#"__needle_store_set("k", JSON.stringify({a:1}))"#,
            &caps,
        );
        assert_eq!(inner(&set)["ok"], true);
        let get = run(r#"__needle_store_get("k")"#, &caps);
        assert_eq!(inner(&get)["value"]["a"], 1);
    }

    #[test]
    fn store_bad_key_rejected() {
        let d = tmp();
        let caps = caps_in(&d);
        let out = run(r#"__needle_store_set("../x", "{}")"#, &caps);
        assert_eq!(inner(&out)["ok"], false);
    }

    #[test]
    fn http_denied_offlist() {
        let d = tmp();
        let mut caps = caps_in(&d);
        caps.allow_hosts = vec![];
        let out = run(r#"__needle_http("https://example.com/")"#, &caps);
        let v = inner(&out);
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "denied");
    }

    #[test]
    fn http_denied_subdomain_ok() {
        let d = tmp();
        let caps = caps_in(&d);
        // example.com allowlist: subdomains pass the gate (network
        // itself untested here - gate logic is the unit).
        let gate_only = caps.host_allowed("https://sub.example.com/x");
        assert!(gate_only);
        assert!(!caps.host_allowed("https://evil.com/"));
        assert!(!caps.host_allowed("not a url"));
    }

    #[test]
    fn wildcard_entries_cover_bare_and_subdomains() {
        // Manifest CDN convention (`*.cloudfront.net`): bare host
        // plus every subdomain pass; neighbours do not.
        let allow = vec!["*.cloudfront.net".to_owned()];
        assert!(super::host_allowed(
            &allow,
            "https://cloudfront.net/x"
        ));
        assert!(super::host_allowed(
            &allow,
            "https://d1.audio.cloudfront.net/x"
        ));
        assert!(!super::host_allowed(&allow, "https://cloudfront.net.evil.com/"));
        assert!(!super::host_allowed(&allow, "https://evil.net/"));
        // A lone star never matches (deny beats convenience).
        assert!(!super::host_allowed(&["*".to_owned()], "https://anything.example/"));
        // Bare entries keep exact-or-subdomain behavior.
        assert!(super::host_allowed(
            &["example.com".to_owned()],
            "https://example.com/x"
        ));
        assert!(!super::host_allowed(
            &["example.com".to_owned()],
            "https://notexample.com/"
        ));
    }

    #[test]
    fn file_absolute_inside_sandbox_allowed() {
        let d = tmp();
        let caps = caps_in(&d);
        // Absolute path inside our own files dir (what the app
        // stages for extension downloads) must pass the gate.
        // Backslashes double for the JS string literal.
        let abs = d
            .join("files")
            .join("pull")
            .join("x.bin")
            .to_string_lossy()
            .replace('\\', "\\\\");
        let out = run(
            &format!(r#"__needle_write_file("{abs}", "aGk=")"#),
            &caps,
        );
        assert_eq!(inner(&out)["ok"], true);
    }

    #[test]
    fn file_absolute_outside_sandbox_denied() {
        let d = tmp();
        let caps = caps_in(&d);
        let out = run(r#"__needle_read_file("/etc/hostname")"#, &caps);
        assert_eq!(inner(&out)["ok"], false);
    }

    #[test]
    fn file_traversal_rejected() {
        let d = tmp();
        let caps = caps_in(&d);
        let out = run(r#"__needle_read_file("../../etc/passwd")"#, &caps);
        assert_eq!(inner(&out)["ok"], false);
        let abs = run(r#"__needle_read_file("/tmp/x")"#, &caps);
        assert_eq!(inner(&abs)["ok"], false);
    }

    #[test]
    fn file_roundtrip_and_logs() {
        use base64::Engine as _;
        let d = tmp();
        let caps = caps_in(&d);
        let log = CallLog::default();
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"hello");
        let src = format!(
            r#"__needle_log("hi"); __needle_write_file("a/b.bin", "{b64}")"#
        );
        let out = crate::sandbox::eval_with(&caps, &log, &src, "{}", std::time::Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["logs"], serde_json::json!(["hi"]));
        let back = std::fs::read(d.join("files").join("a").join("b.bin")).unwrap();
        assert_eq!(back, b"hello");
    }
}

// ----------------------------------------------------------------
// Port-API `host` object: thin JSON-string primitives backing the
// prelude globals (crate::prelude::PRELUDE). Same contract as the
// public SpotiFLAC host: every function returns a JSON string and
// never throws; network failures are `{error}` data. Permission
// gating (storage/file) reads the manifest flags on Caps.
// ----------------------------------------------------------------

use std::cell::Cell;

thread_local! {
    static CALL_DEADLINE: Cell<Option<std::time::Instant>> =
        const { Cell::new(None) };
}

/// Set by the driver around each call so `resolutionRemaining`
/// reports honestly. Cleared after.
pub(crate) fn set_call_deadline(d: Option<std::time::Instant>) {
    CALL_DEADLINE.with(|c| c.set(d));
}

/// Denial reason, or None when the URL passes scheme + allowlist.
fn url_denial(caps: &Caps, url: &str) -> Option<String> {
    if url.starts_with("https://") {
        // ok
    } else if url.starts_with("http://") {
        let plain_ok = caps
            .allow_hosts
            .iter()
            .any(|a| a.to_lowercase().starts_with("http://"));
        if !plain_ok {
            return Some("only https is allowed".to_owned());
        }
    } else {
        return Some("bad scheme".to_owned());
    }
    if !caps.host_allowed(url) {
        return Some("denied".to_owned());
    }
    None
}

pub(crate) struct HttpOutcome {
    pub(crate) status: u16,
    pub(crate) headers: Vec<(String, Vec<String>)>,
    pub(crate) body: Vec<u8>,
}

/// Shared fetch core: allowlist, 30s timeout, 8MB body cap.
//cookiejar-free by design: extensions manage cookies themselves
// via response `headers` (set-cookie arrays) and request headers,
// which is why headers ride every response.
pub(crate) fn http_fetch(
    caps: &Caps,
    url: &str,
    method: &str,
    headers: &[(String, String)],
    body: &str,
) -> Result<HttpOutcome, String> {
    if let Some(d) = url_denial(caps, url) {
        return Err(d);
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .user_agent("ArchPlayer-Needle/0.1 (extension)")
        .build()
        .map_err(|_| "http unavailable".to_owned())?;
    let method_up = method.to_uppercase();
    let mut req = match method_up.as_str() {
        "POST" => client.post(url),
        "PUT" => client.put(url),
        "PATCH" => client.patch(url),
        "DELETE" => client.delete(url),
        "HEAD" => client.head(url),
        _ => client.get(url),
    };
    for (k, v) in headers.iter().take(32) {
        req = req.header(k, v);
    }
    if matches!(method_up.as_str(), "POST" | "PUT" | "PATCH") {
        req = req.body(body.to_owned());
    }
    let res = req.send().map_err(|_| "http failed".to_owned())?;
    let status = res.status().as_u16();
    let mut headers: Vec<(String, Vec<String>)> = Vec::new();
    for (k, v) in res.headers().iter() {
        let name = k.as_str().to_owned();
        let val = v.to_str().unwrap_or("").to_owned();
        match headers.iter_mut().find(|(n, _)| *n == name) {
            Some((_, vals)) => vals.push(val),
            None => headers.push((name, vec![val])),
        }
    }
    let bytes = res.bytes().map_err(|_| "http failed".to_owned())?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("body over 8MB".to_owned());
    }
    Ok(HttpOutcome {
        status,
        headers,
        body: bytes.to_vec(),
    })
}

fn headers_json(h: &[(String, Vec<String>)]) -> Value {
    let mut map = serde_json::Map::new();
    for (k, vals) in h {
        if vals.len() == 1 {
            map.insert(k.clone(), Value::String(vals[0].clone()));
        } else {
            map.insert(
                k.clone(),
                Value::Array(vals.iter().cloned().map(Value::String).collect()),
            );
        }
    }
    Value::Object(map)
}

/// Envelope for `host.request`: success carries the full response
/// (single headers as strings, multi as arrays), failure is
/// `{error}` - never a throw.
fn request_json(
    caps: &Caps,
    url: &str,
    method: &str,
    body: &str,
    headers_json_text: &str,
    want_bytes: bool,
) -> String {
    let mut headers = Vec::new();
    if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(headers_json_text) {
        for (k, v) in map.iter().take(32) {
            match v {
                Value::String(s) => headers.push((k.clone(), s.clone())),
                Value::Number(n) => headers.push((k.clone(), n.to_string())),
                Value::Bool(b) => headers.push((k.clone(), b.to_string())),
                _ => {}
            }
        }
    }
    match http_fetch(caps, url, method, &headers, body) {
        Err(e) => serde_json::json!({"error": e}).to_string(),
        Ok(out) => {
            let mut v = serde_json::json!({
                "statusCode": out.status,
                "status": out.status,
                "ok": (200..300).contains(&out.status),
                "body": String::from_utf8_lossy(&out.body).into_owned(),
                "headers": headers_json(&out.headers),
            });
            if want_bytes {
                // Binary bodies ride as a number array for
                // arrayBuffer(); capped (a 2MB page as 2M JSON
                // numbers OOMs the 64MB sandbox). text()/json()
                // always work off the string body above; bulk
                // bytes travel via file.download, never fetch.
                if out.body.len() <= 512 * 1024 {
                    v["bytes"] =
                        Value::Array(out.body.iter().map(|b| Value::from(*b)).collect());
                }
            }
            v.to_string()
        }
    }
}

fn store_base(caps: &Caps, cred: bool) -> Result<std::path::PathBuf, String> {
    if !caps.storage_allowed {
        return Err("storage permission denied".to_owned());
    }
    let mut dir =
        std::path::Path::new(&caps.storage_dir).join(&caps.namespace);
    if cred {
        dir = dir.join("cred");
    }
    Ok(dir)
}

fn store_key_path(caps: &Caps, cred: bool, key: &str) -> Result<std::path::PathBuf, String> {
    if key.is_empty()
        || key.len() > 128
        || !key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
    {
        return Err("bad key".to_owned());
    }
    Ok(store_base(caps, cred)?.join(format!("{key}.json")))
}

fn store_read_json(caps: &Caps, cred: bool, key: &str) -> String {
    let path = match store_key_path(caps, cred, key) {
        Err(e) => return serde_json::json!({"error": e}).to_string(),
        Ok(p) => p,
    };
    match std::fs::read_to_string(&path) {
        Err(_) => serde_json::json!({"found": false}).to_string(),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Err(_) => serde_json::json!({"error": "stored value corrupt"}).to_string(),
            Ok(v) => serde_json::json!({"found": true, "value": v}).to_string(),
        },
    }
}

fn store_write_json(caps: &Caps, cred: bool, key: &str, text: &str) -> String {
    let path = match store_key_path(caps, cred, key) {
        Err(e) => return serde_json::json!({"success": false, "error": e}).to_string(),
        Ok(p) => p,
    };
    if text.len() > 1024 * 1024 {
        return serde_json::json!({"success": false, "error": "value over 1MB"}).to_string();
    }
    if serde_json::from_str::<Value>(text).is_err() {
        return serde_json::json!({"success": false, "error": "value is not JSON"}).to_string();
    }
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return serde_json::json!({"success": false, "error": "storage unavailable"}).to_string();
        }
    }
    let tmp = path.with_extension("tmp");
    match std::fs::write(&tmp, text.as_bytes()).and_then(|_| std::fs::rename(&tmp, &path)) {
        Ok(()) => serde_json::json!({"success": true}).to_string(),
        Err(_) => serde_json::json!({"success": false, "error": "storage unavailable"}).to_string(),
    }
}

fn store_remove_json(caps: &Caps, cred: bool, key: &str) -> String {
    let path = match store_key_path(caps, cred, key) {
        Err(e) => return serde_json::json!({"success": false, "error": e}).to_string(),
        Ok(p) => p,
    };
    // Missing counts as removed.
    let _ = std::fs::remove_file(&path);
    serde_json::json!({"success": true}).to_string()
}

fn file_env(success: bool, extra: serde_json::Map<String, Value>, error: &str) -> String {
    let mut map = extra;
    map.insert("success".to_owned(), Value::Bool(success));
    if !success {
        map.insert("error".to_owned(), Value::String(error.to_owned()));
    }
    Value::Object(map).to_string()
}

/// Look up a prelude-registered progress callback (`__needle_cbs`
/// by numeric id). Missing/dead callbacks are silent no-ops.
fn js_progress<'js>(
    ctx: rquickjs::Ctx<'js>,
    cb_id: i64,
) -> impl Fn(u64, u64) + 'js {
    move |done: u64, total: u64| {
        let key = cb_id.to_string();
        let cbs: Result<Object, rquickjs::Error> = ctx.globals().get("__needle_cbs");
        if let Ok(cbs) = cbs {
            if let Ok(f) = cbs.get::<_, Function>(key.as_str()) {
                let _ = f.call::<_, ()>((done, total));
            }
        }
    }
}

fn cb_id_of(options: &str) -> i64 {
    serde_json::from_str::<Value>(options)
        .ok()
        .map(|v| v.get("__cb").and_then(|c| c.as_i64()).unwrap_or(0))
        .unwrap_or(0)
}

/// `host.fileCall`: every method returns a JSON envelope string
/// EXCEPT `exists`, which returns bare `"true"`/`"false"`.
fn file_call_json(
    caps: &Caps,
    ctx: &rquickjs::Ctx<'_>,
    method: &str,
    path: &str,
    value: &str,
    options: &str,
) -> String {
    if !caps.file_allowed {
        if method == "exists" {
            return "false".to_owned();
        }
        return file_env(false, serde_json::Map::new(), "file permission denied");
    }
    let rel = match caps.file_path(path) {
        Err(e) => {
            if method == "exists" {
                return "false".to_owned();
            }
            return file_env(false, serde_json::Map::new(), &e);
        }
        Ok(p) => p,
    };
    match method {
        "exists" => {
            if std::fs::metadata(&rel).is_ok() {
                "true".to_owned()
            } else {
                "false".to_owned()
            }
        }
        "delete" => match std::fs::remove_file(&rel) {
            Ok(()) => file_env(true, serde_json::Map::new(), ""),
            Err(e) => file_env(false, serde_json::Map::new(), &e.to_string()),
        },
        "read" => match std::fs::read(&rel) {
            Err(e) => file_env(false, serde_json::Map::new(), &e.to_string()),
            Ok(bytes) => {
                if bytes.len() > 16 * 1024 * 1024 {
                    return file_env(false, serde_json::Map::new(), "file over 16MB");
                }
                let mut m = serde_json::Map::new();
                m.insert(
                    "data".to_owned(),
                    Value::String(String::from_utf8_lossy(&bytes).into_owned()),
                );
                file_env(true, m, "")
            }
        },
        "readBytes" => {
            let opts: Value = serde_json::from_str(options).unwrap_or(Value::Null);
            let offset = opts.get("offset").and_then(|v| v.as_i64()).unwrap_or(0).max(0) as u64;
            let length = opts.get("length").and_then(|v| v.as_i64()).unwrap_or(-1);
            let encoding = opts
                .get("encoding")
                .and_then(|v| v.as_str())
                .unwrap_or("base64");
            let data = match std::fs::read(&rel) {
                Err(e) => return file_env(false, serde_json::Map::new(), &e.to_string()),
                Ok(d) => d,
            };
            let size = data.len() as u64;
            let start = offset.min(size) as usize;
            let end = if length < 0 {
                data.len()
            } else {
                (start as u64 + length.max(0) as u64).min(size) as usize
            };
            let slice = &data[start..end];
            let encoded = if encoding == "hex" {
                slice.iter().map(|b| format!("{b:02x}")).collect::<String>()
            } else {
                use base64::Engine as _;
                base64::engine::general_purpose::STANDARD.encode(slice)
            };
            let mut m = serde_json::Map::new();
            m.insert("data".to_owned(), Value::String(encoded));
            m.insert("bytes_read".to_owned(), Value::from(slice.len() as u64));
            m.insert("offset".to_owned(), Value::from(offset));
            m.insert("size".to_owned(), Value::from(size));
            m.insert("eof".to_owned(), Value::Bool(end as u64 >= size));
            file_env(true, m, "")
        }
        "write" => {
            if let Some(parent) = rel.parent() {
                if std::fs::create_dir_all(parent).is_err() {
                    return file_env(false, serde_json::Map::new(), "write failed");
                }
            }
            let tmp = rel.with_extension("tmp");
            match std::fs::write(&tmp, value.as_bytes()).and_then(|_| std::fs::rename(&tmp, &rel)) {
                Ok(()) => {
                    let mut m = serde_json::Map::new();
                    m.insert(
                        "path".to_owned(),
                        Value::String(rel.to_string_lossy().into_owned()),
                    );
                    file_env(true, m, "")
                }
                Err(e) => file_env(false, serde_json::Map::new(), &e.to_string()),
            }
        }
        "writeBytes" => {
            use base64::Engine as _;
            let bytes = match base64::engine::general_purpose::STANDARD.decode(value) {
                Err(_) => return file_env(false, serde_json::Map::new(), "not base64"),
                Ok(b) => b,
            };
            if let Some(parent) = rel.parent() {
                if std::fs::create_dir_all(parent).is_err() {
                    return file_env(false, serde_json::Map::new(), "write failed");
                }
            }
            let tmp = rel.with_extension("tmp");
            match std::fs::write(&tmp, &bytes).and_then(|_| std::fs::rename(&tmp, &rel)) {
                Ok(()) => {
                    let mut m = serde_json::Map::new();
                    m.insert(
                        "path".to_owned(),
                        Value::String(rel.to_string_lossy().into_owned()),
                    );
                    m.insert("bytes_written".to_owned(), Value::from(bytes.len() as u64));
                    file_env(true, m, "")
                }
                Err(e) => file_env(false, serde_json::Map::new(), &e.to_string()),
            }
        }
        "copy" | "move" => {
            let dst = match caps.file_path(value) {
                Err(e) => return file_env(false, serde_json::Map::new(), &e),
                Ok(p) => p,
            };
            if let Some(parent) = dst.parent() {
                if std::fs::create_dir_all(parent).is_err() {
                    return file_env(false, serde_json::Map::new(), "copy failed");
                }
            }
            let r = if method == "copy" {
                std::fs::copy(&rel, &dst).map(|_| ()).map_err(|e| e.to_string())
            } else {
                std::fs::rename(&rel, &dst).map_err(|e| e.to_string())
            };
            match r {
                Ok(()) => {
                    let mut m = serde_json::Map::new();
                    m.insert(
                        "path".to_owned(),
                        Value::String(dst.to_string_lossy().into_owned()),
                    );
                    file_env(true, m, "")
                }
                Err(e) => file_env(false, serde_json::Map::new(), &e),
            }
        }
        "getSize" => match std::fs::metadata(&rel) {
            Err(e) => file_env(false, serde_json::Map::new(), &e.to_string()),
            Ok(md) => {
                let mut m = serde_json::Map::new();
                m.insert("size".to_owned(), Value::from(md.len()));
                file_env(true, m, "")
            }
        },
        // Batch 3 (patterned transform + downloads) lands with the
        // download engine slice; until then honest unavailability.
        "transformPatternedBlocks" => {
            let dst = match caps.file_path(value) {
                Err(e) => return file_env(false, serde_json::Map::new(), &e),
                Ok(p) => p,
            };
            let cb = cb_id_of(options);
            let progress = js_progress(ctx.clone(), cb);
            match crate::transform::transform(&rel, &dst, options, &progress) {
                Err(e) => file_env(false, serde_json::Map::new(), &e),
                Ok(st) => {
                    let mut m = serde_json::Map::new();
                    m.insert("path".to_owned(), Value::String(st.path));
                    m.insert(
                        "bytes_processed".to_owned(),
                        Value::from(st.bytes_processed),
                    );
                    m.insert(
                        "segments_processed".to_owned(),
                        Value::from(st.segments_processed),
                    );
                    m.insert(
                        "segments_transformed".to_owned(),
                        Value::from(st.segments_transformed),
                    );
                    file_env(true, m, "")
                }
            }
        }
        _ => file_env(false, serde_json::Map::new(), "unsupported file method"),
    }
}

/// `host.downloadCall`: single URL into the sandbox files dir
/// (tmp + rename), headers + chunked mode + JS progress.
fn download_call_json(
    caps: &Caps,
    ctx: &rquickjs::Ctx<'_>,
    url: &str,
    path: &str,
    opts_json: &str,
) -> String {
    let opts: Value = serde_json::from_str(opts_json).unwrap_or(Value::Null);
    let mut headers = Vec::new();
    if let Some(Value::Object(m)) = opts.get("headers") {
        for (k, v) in m.iter().take(32) {
            if let Some(s) = v.as_str() {
                headers.push((k.clone(), s.to_owned()));
            }
        }
    }
    let chunked = opts
        .get("chunked")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let cb = opts
        .get("cb")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    if !caps.file_allowed {
        return serde_json::json!({"success": false, "error": "file permission denied"}).to_string();
    }
    let dest = match caps.file_path(path) {
        Err(e) => return serde_json::json!({"success": false, "error": e}).to_string(),
        Ok(p) => p,
    };
    if let Some(parent) = dest.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return serde_json::json!({"success": false, "error": "dest unavailable"}).to_string();
        }
    }
    let tmp = dest.with_extension("part");
    let progress = js_progress(ctx.clone(), cb);
    let report = |done: u64, total: Option<u64>| {
        progress(done, total.unwrap_or(0));
    };
    match crate::download::download_to_file(
        url,
        &headers,
        chunked,
        &caps.allow_hosts,
        &tmp,
        false,
        &|| false,
        &report,
    ) {
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            serde_json::json!({"success": false, "error": e}).to_string()
        }
        Ok(n) => match std::fs::rename(&tmp, &dest) {
            Err(_) => {
                let _ = std::fs::remove_file(&tmp);
                serde_json::json!({"success": false, "error": "landing failed"}).to_string()
            }
            Ok(()) => serde_json::json!({
                "success": true,
                "path": dest.to_string_lossy(),
                "size": n,
            })
            .to_string(),
        },
    }
}

/// `host.downloadSegmentsCall`: sequential spec fetch, appended
/// into one file (tmp + rename). Failures carry the reference
/// `error_type`/`attempts` fields.
fn download_segments_json(
    caps: &Caps,
    specs_json: &str,
    path: &str,
) -> String {
    let fail = |e: &str| {
        serde_json::json!({
            "success": false, "error": e,
            "error_type": "download_error", "attempts": 0,
        })
        .to_string()
    };
    if !caps.file_allowed {
        return fail("file permission denied");
    }
    let specs: Value = serde_json::from_str(specs_json).unwrap_or(Value::Null);
    let arr = match specs.as_array() {
        Some(a) if !a.is_empty() => a,
        _ => return fail("segments must be a non-empty array"),
    };
    let dest = match caps.file_path(path) {
        Err(e) => return fail(&e),
        Ok(p) => p,
    };
    if let Some(parent) = dest.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return fail("dest unavailable");
        }
    }
    let tmp = dest.with_extension("parts");
    let _ = std::fs::remove_file(&tmp);
    let mut total_written: u64 = 0;
    for spec in arr {
        let url = spec.get("url").and_then(|v| v.as_str()).unwrap_or("");
        let mut headers = Vec::new();
        if let Some(Value::Object(m)) = spec.get("headers") {
            for (k, v) in m.iter().take(32) {
                if let Some(s) = v.as_str() {
                    headers.push((k.clone(), s.to_owned()));
                }
            }
        }
        match crate::download::download_to_file(
            url,
            &headers,
            false,
            &caps.allow_hosts,
            &tmp,
            true,
            &|| false,
            &|_, _| {},
        ) {
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                return fail(&e);
            }
            Ok(n) => total_written += n,
        }
    }
    match std::fs::rename(&tmp, &dest) {
        Err(_) => {
            let _ = std::fs::remove_file(&tmp);
            fail("landing failed")
        }
        Ok(()) => serde_json::json!({
            "success": true,
            "path": dest.to_string_lossy(),
            "size": total_written,
        })
        .to_string(),
    }
}

fn hex_bytes(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Minimal URL parse for the prelude `URL`: absolute http(s) plus
/// base-relative resolution. Returns fields JSON or `{error}`.
fn parse_url_json(input: &str, base: &str) -> String {
    fn split_off(s: &str, c: char) -> (&str, Option<&str>) {
        match s.find(c) {
            Some(i) => (&s[..i], Some(&s[i + 1..])),
            None => (s, None),
        }
    }
    let input = input.trim();
    if input.is_empty() {
        return serde_json::json!({"error": "empty url"}).to_string();
    }
    let scheme_rest = if let Some(i) = input.find("://") {
        let (s, r) = input.split_at(i);
        if !s.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)) {
            return serde_json::json!({"error": "bad scheme"}).to_string();
        }
        Some((s.to_lowercase(), &r[3..]))
    } else {
        None
    };
    // Absolute URL.
    if let Some((scheme, rest)) = scheme_rest {
        if scheme != "http" && scheme != "https" {
            return serde_json::json!({"error": "unsupported scheme"}).to_string();
        }
        let (authority, path_query) = split_off(rest, '/');
        let path = format!("/{}", path_query.unwrap_or(""));
        return build_url(&scheme, authority, &path, base, true);
    }
    // Protocol-relative.
    if input.starts_with("//") {
        let scheme = base_scheme(base).unwrap_or_else(|| "https".to_owned());
        let (authority, path_query) = split_off(&input[2..], '/');
        return build_url(&scheme, authority, &format!("/{}", path_query.unwrap_or("")), base, true);
    }
    // Resolve against base.
    let b = match parse_absolute(base) {
        Some(b) => b,
        None => {
            // No usable base: treat a bare path as https path.
            if input.starts_with('/') {
                return build_url("https", "", input, "", true);
            }
            return serde_json::json!({"error": "relative url without base"}).to_string();
        }
    };
    if input.starts_with('/') {
        return build_url(&b.0, &b.1, input, "", true);
    }
    // Merge with base directory.
    let dir = match b.2.rfind('/') {
        Some(i) => &b.2[..i + 1],
        None => "/",
    };
    let merged = format!("{dir}{input}");
    build_url(&b.0, &b.1, &merged, "", true)
}

fn base_scheme(base: &str) -> Option<String> {
    parse_absolute(base).map(|b| b.0)
}

fn parse_absolute(url: &str) -> Option<(String, String, String)> {
    let i = url.find("://")?;
    let (s, r) = url.split_at(i);
    if s != "http" && s != "https" && s != "HTTP" && s != "HTTPS" {
        return None;
    }
    let rest = &r[3..];
    let end = rest.find('/').unwrap_or(rest.len());
    let (authority, path) = rest.split_at(end);
    if authority.is_empty() {
        return None;
    }
    let path = if path.is_empty() { "/" } else { path };
    Some((s.to_lowercase(), authority.to_owned(), path.to_owned()))
}

fn build_url(scheme: &str, authority: &str, path_query: &str, _base: &str, _a: bool) -> String {
    let (host_port, _) = match authority.find('@') {
        Some(i) => (&authority[i + 1..], &authority[..i]),
        None => (authority, ""),
    };
    let (host, port) = match host_port.rfind(':') {
        Some(i) if host_port[i + 1..].chars().all(|c| c.is_ascii_digit()) => {
            (&host_port[..i], &host_port[i + 1..])
        }
        _ => (host_port, ""),
    };
    let (path, query_frag) = match path_query.find('?') {
        Some(i) => (&path_query[..i], Some(&path_query[i..])),
        None => (path_query, None),
    };
    let (query, frag) = match query_frag {
        Some(qf) => match qf.find('#') {
            Some(i) => (&qf[..i], &qf[i..]),
            None => (qf, ""),
        },
        None => match path.find('#') {
            Some(i) => ("", &path[i..]),
            None => ("", ""),
        },
    };
    let path = match path.find('#') {
        Some(i) => &path[..i],
        None => path,
    };
    let path = if path.is_empty() { "/" } else { path };
    let mut href = format!("{scheme}://{host}");
    if !port.is_empty() {
        href.push(':');
        href.push_str(port);
    }
    href.push_str(path);
    href.push_str(query);
    href.push_str(frag);
    serde_json::json!({
        "href": href,
        "protocol": format!("{scheme}:"),
        "hostname": host,
        "port": port,
        "pathname": path,
        "search": query,
        "hash": frag,
    })
    .to_string()
}

/// Parse `a=1&b=2` into `[[k,v]]` with percent-decoding.
fn parse_query_json(qs: &str) -> String {
    fn decode(s: &str) -> String {
        let mut out = Vec::new();
        let b = s.as_bytes();
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'+' {
                out.push(b' ');
                i += 1;
            } else if b[i] == b'%' && i + 2 < b.len() {
                let h = |c: u8| {
                    (c as char).to_digit(16).map(|d| d as u8)
                };
                match (h(b[i + 1]), h(b[i + 2])) {
                    (Some(a), Some(c)) => {
                        out.push(a * 16 + c);
                        i += 3;
                    }
                    _ => {
                        out.push(b[i]);
                        i += 1;
                    }
                }
            } else {
                out.push(b[i]);
                i += 1;
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    let pairs: Vec<Value> = qs
        .split('&')
        .filter(|p| !p.is_empty())
        .map(|p| match p.find('=') {
            Some(i) => Value::Array(vec![
                Value::String(decode(&p[..i])),
                Value::String(decode(&p[i + 1..])),
            ]),
            None => Value::Array(vec![Value::String(decode(p)), Value::String(String::new())]),
        })
        .collect();
    Value::Array(pairs).to_string()
}

fn normalize_matching(s: &str) -> String {
    let lower = s.to_lowercase();
    let mut out = String::with_capacity(lower.len());
    let mut prev_space = true;
    for c in lower.chars() {
        if c.is_alphanumeric() {
            out.push(c);
            prev_space = false;
        } else if !prev_space {
            out.push(' ');
            prev_space = true;
        }
    }
    out.trim().to_owned()
}

fn compare_strings(a: &str, b: &str) -> f64 {
    let na = normalize_matching(a);
    let nb = normalize_matching(b);
    if na == nb {
        return 1.0;
    }
    if na.is_empty() || nb.is_empty() {
        return 0.0;
    }
    if na.contains(&nb) || nb.contains(&na) {
        return 0.8;
    }
    let ta: Vec<&str> = na.split(' ').collect();
    let tb: Vec<&str> = nb.split(' ').collect();
    let mut inter = 0;
    for t in &ta {
        if tb.contains(t) {
            inter += 1;
        }
    }
    let union = ta.len() + tb.len() - inter;
    if union == 0 {
        0.0
    } else {
        inter as f64 / union as f64
    }
}

/// Sanitize a filename (legacy surface): strip illegal + control
/// chars, cap length. Pure string work, no FS touch.
fn legacy_sanitize(s: &str) -> String {
    let mut out: String = s
        .chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
                || c.is_control()
            {
                '_'
            } else {
                c
            }
        })
        .collect();
    while out.len() > 128 {
        out.pop();
    }
    out.trim().trim_matches('.').to_owned()
}

/// `{key}` substitution over a JSON field map. Unknown keys empty.
fn legacy_filename(pattern: &str, fields_json: &str) -> String {
    let fields: Value = serde_json::from_str(fields_json).unwrap_or(Value::Null);
    let mut out = String::new();
    let mut rest = pattern;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        rest = &rest[start + 1..];
        match rest.find('}') {
            Some(end) => {
                let key = &rest[..end];
                let v = fields.get(key).map(|v| match v {
                    Value::String(s) => s.clone(),
                    Value::Null => String::new(),
                    _ => v.to_string(),
                });
                out.push_str(&v.unwrap_or_default());
                rest = &rest[end + 1..];
            }
            None => {
                out.push('{');
            }
        }
    }
    out.push_str(rest);
    legacy_sanitize(&out)
}

/// UTC-based local-time shape (offset 0): greetings and timezone
/// params keep working; true device tz arrives with the app clock.
fn legacy_local_time() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (y, mo, d, h, mi, s, wd) = civil_from_unix(now);
    serde_json::json!({
        "year": y, "month": mo, "day": d, "hour": h, "minute": mi,
        "second": s, "weekday": wd, "offsetMinutes": 0,
        "timezone": "UTC", "timestamp": now,
    })
    .to_string()
}

/// Howard Hinnant's civil-from-days, UTC. Returns
/// (year, month, day, hour, min, sec, weekday Sun=0).
fn civil_from_unix(ts: i64) -> (i32, u32, u32, u32, u32, u32, u32) {
    let secs = ts.rem_euclid(86400);
    let days = ts.div_euclid(86400) + 719468;
    let era = days.div_euclid(146097);
    let doe = days.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = (if m <= 2 { y + 1 } else { y }) as i32;
    let wd = ((days + 6) % 7) as u32; // 0000-03-01 was Wednesday
    (
        y,
        m,
        d,
        (secs / 3600) as u32,
        ((secs % 3600) / 60) as u32,
        (secs % 60) as u32,
        wd,
    )
}

fn hmac_sha1_json(key_json: &str, msg_json: &str) -> String {
    use hmac::{Hmac, Mac};
    fn bytes_of(text: &str) -> Result<Vec<u8>, String> {
        let v: Value =
            serde_json::from_str(text).map_err(|_| "not json".to_owned())?;
        match v {
            Value::Array(items) => {
                let mut out = Vec::with_capacity(items.len());
                for it in items {
                    out.push(
                        it.as_u64()
                            .map(|n| (n & 0xff) as u8)
                            .ok_or_else(|| "not a byte array".to_owned())?,
                    );
                }
                Ok(out)
            }
            Value::String(s) => Ok(s.into_bytes()),
            _ => Err("not a byte array".to_owned()),
        }
    }
    let key = match bytes_of(key_json) {
        Err(e) => return err(&e),
        Ok(k) => k,
    };
    let msg = match bytes_of(msg_json) {
        Err(e) => return err(&e),
        Ok(m) => m,
    };
    let mut mac = match Hmac::<sha1::Sha1>::new_from_slice(&key) {
        Err(_) => return err("bad key"),
        Ok(m) => m,
    };
    mac.update(&msg);
    ok(Value::Array(mac.finalize().into_bytes().to_vec().into_iter().map(Value::from).collect()))
}

/// Set one `host` primitive. Top-level fn (not a closure) so the
/// QuickJS object/function lifetimes unify at each call site.
fn put<'js>(host: &Object<'js>, name: &str, f: Function<'js>) -> Result<(), String> {
    host.set(name, f).map_err(|e| format!("host fn {name}: {e}"))
}

/// Build the `host` object and set it as `__needle_host`.
/// `session` flips on once a manifest carries a signed-session
/// block; without it `session` stays undefined and extensions
/// fail honestly (same as the reference runtime with sessions
/// off).
pub fn inject_host(
    ctx: &rquickjs::Ctx<'_>,
    caps: &Caps,
    log: &CallLog,
    session: Option<crate::session::SessionCtx>,
) -> Result<(), String> {
    let host = Object::new(ctx.clone()).map_err(|e| format!("host object: {e}"))?;
    let flag = |name: &str, v: bool| -> Result<(), String> {
        host.set(name, v).map_err(|e| format!("host flag {name}: {e}"))
    };
    flag("storageEnabled", true)?;
    flag("networkEnabled", true)?;
    flag("filesEnabled", true)?;
    flag("sessionEnabled", session.is_some())?;
    flag("authEnabled", true)?;
    flag("legacyBackend", true)?;
    flag("managedConsole", true)?;

    // sortKeys / quoteJSON
    put(&host, 
        "sortKeys",
        Function::new(ctx.clone(), move |arr_json: String| {
            let mut v: Vec<String> = serde_json::from_str(&arr_json).unwrap_or_default();
            v.sort();
            Value::Array(v.into_iter().map(Value::String).collect()).to_string()
        })
        .map_err(|e| format!("sortKeys: {e}"))?,
    )?;
    put(&host, 
        "quoteJSON",
        Function::new(ctx.clone(), move |s: String| {
            serde_json::to_string(&s).unwrap_or_default()
        })
        .map_err(|e| format!("quoteJSON: {e}"))?,
    )?;
    // parseURL / parseQuery
    put(&host, 
        "parseURL",
        Function::new(ctx.clone(), move |input: String, base: String| {
            parse_url_json(&input, &base)
        })
        .map_err(|e| format!("parseURL: {e}"))?,
    )?;
    put(&host, 
        "parseQuery",
        Function::new(ctx.clone(), move |qs: String| parse_query_json(&qs))
            .map_err(|e| format!("parseQuery: {e}"))?,
    )?;
    // encode / decode / decodeBytes
    put(&host, 
        "encode",
        Function::new(ctx.clone(), move |s: String| {
            Value::Array(s.as_bytes().iter().map(|b| Value::from(*b)).collect()).to_string()
        })
        .map_err(|e| format!("encode: {e}"))?,
    )?;
    {
        let f = Function::new(ctx.clone(), move |arr_json: String| {
            let v: Value = serde_json::from_str(&arr_json).unwrap_or(Value::Null);
            let mut bytes = Vec::new();
            if let Value::Array(items) = v {
                for it in items {
                    if let Some(n) = it.as_u64() {
                        bytes.push((n & 0xff) as u8);
                    }
                }
            }
            String::from_utf8_lossy(&bytes).into_owned()
        })
        .map_err(|e| format!("decode: {e}"))?;
        host.set("decode", f.clone()).map_err(|e| format!("decode: {e}"))?;
        host.set("decodeBytes", f).map_err(|e| format!("decodeBytes: {e}"))?;
    }
    // storageRead / storageWrite / storageRemove / storageKeys
    {
        let caps = caps.clone();
        put(&host, 
            "storageRead",
            Function::new(ctx.clone(), move |cred: bool, key: String| {
                store_read_json(&caps, cred, &key)
            })
            .map_err(|e| format!("storageRead: {e}"))?,
        )?;
    }
    {
        let caps = caps.clone();
        put(&host, 
            "storageWrite",
            Function::new(ctx.clone(), move |cred: bool, key: String, text: String| {
                store_write_json(&caps, cred, &key, &text)
            })
            .map_err(|e| format!("storageWrite: {e}"))?,
        )?;
    }
    {
        let caps = caps.clone();
        put(&host, 
            "storageRemove",
            Function::new(ctx.clone(), move |cred: bool, key: String| {
                store_remove_json(&caps, cred, &key)
            })
            .map_err(|e| format!("storageRemove: {e}"))?,
        )?;
    }
    {
        let caps = caps.clone();
        put(&host, 
            "storageKeys",
            Function::new(ctx.clone(), move |prefix: String| {
                let dir = std::path::Path::new(&caps.storage_dir).join(&caps.namespace);
                let mut out = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&dir) {
                    for e in entries.flatten() {
                        let name = e.file_name().to_string_lossy().into_owned();
                        if let Some(key) = name.strip_suffix(".json") {
                            if key.starts_with(prefix.as_str()) {
                                out.push(key.to_owned());
                            }
                        }
                    }
                }
                ok(Value::Array(out.into_iter().map(Value::String).collect()))
            })
            .map_err(|e| format!("storageKeys: {e}"))?,
        )?;
    }
    // validateURL
    {
        let caps = caps.clone();
        put(&host, 
            "validateURL",
            Function::new(ctx.clone(), move |url: String| -> Option<String> {
                url_denial(&caps, &url)
            })
            .map_err(|e| format!("validateURL: {e}"))?,
        )?;
    }
    // request
    {
        let caps = caps.clone();
        put(&host, 
            "request",
            Function::new(
                ctx.clone(),
                move |url: String,
                      method: String,
                      body: String,
                      headers_json: String,
                      want_bytes: bool| {
                    request_json(&caps, &url, &method, &body, &headers_json, want_bytes)
                },
            )
            .map_err(|e| format!("request: {e}"))?,
        )?;
    }
    // appUserAgent / clearCookies
    put(&host, 
        "appUserAgent",
        Function::new(ctx.clone(), move || "ArchPlayer-Needle/0.1 (extension)".to_owned())
            .map_err(|e| format!("appUserAgent: {e}"))?,
    )?;
    put(&host, 
        "clearCookies",
        Function::new(ctx.clone(), move || true).map_err(|e| format!("clearCookies: {e}"))?,
    )?;
    // extensionLog
    {
        let log = log.clone();
        put(&host, 
            "extensionLog",
            Function::new(ctx.clone(), move |level: String, args: Vec<String>| {
                let mut line = String::new();
                if !level.is_empty() && level != "LOG" {
                    line.push_str(&level);
                    line.push(' ');
                }
                line.push_str(&args.join(" "));
                log.push(line);
            })
            .map_err(|e| format!("extensionLog: {e}"))?,
        )?;
    }
    // matching
    put(&host, 
        "compareStrings",
        Function::new(ctx.clone(), move |a: String, b: String| compare_strings(&a, &b))
            .map_err(|e| format!("compareStrings: {e}"))?,
    )?;
    put(&host, 
        "compareDuration",
        Function::new(ctx.clone(), move |a: f64, b: f64, tol: f64| (a - b).abs() <= tol)
            .map_err(|e| format!("compareDuration: {e}"))?,
    )?;
    put(&host,
        "normalizeMatching",
        Function::new(ctx.clone(), move |s: String| normalize_matching(&s))
            .map_err(|e| format!("normalizeMatching: {e}"))?,
    )?;

    put(&host, 
        "downloadCancelled",
        Function::new(ctx.clone(), move || false).map_err(|e| format!("dc: {e}"))?,
    )?;
    put(&host, 
        "requestCancelled",
        Function::new(ctx.clone(), move || false).map_err(|e| format!("rc: {e}"))?,
    )?;
    put(&host, 
        "downloadItemActive",
        Function::new(ctx.clone(), move || false).map_err(|e| format!("dia: {e}"))?,
    )?;
    put(&host, 
        "downloadStatus",
        Function::new(ctx.clone(), move |_s: String| {}).map_err(|e| format!("ds: {e}"))?,
    )?;
    put(&host, 
        "resolutionRemaining",
        Function::new(ctx.clone(), move || -> f64 {
            CALL_DEADLINE.with(|c| match c.get() {
                Some(d) => {
                    let now = std::time::Instant::now();
                    if d > now {
                        (d - now).as_millis() as f64
                    } else {
                        0.0
                    }
                }
                None => 300000.0,
            })
        })
        .map_err(|e| format!("resolutionRemaining: {e}"))?,
    )?;
    // agents/version
    put(&host, 
        "randomUserAgent",
        Function::new(ctx.clone(), move || {
            "Mozilla/5.0 (Linux; Android 14; DNY-NX9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36".to_owned()
        })
        .map_err(|e| format!("randomUserAgent: {e}"))?,
    )?;
    put(&host, 
        "appVersion",
        Function::new(ctx.clone(), move || "0.1.0".to_owned())
            .map_err(|e| format!("appVersion: {e}"))?,
    )?;
    // hashes
    put(&host, 
        "base64Encode",
        Function::new(ctx.clone(), move |s: String| {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD.encode(s.as_bytes())
        })
        .map_err(|e| format!("base64Encode: {e}"))?,
    )?;
    put(&host, 
        "base64Decode",
        Function::new(ctx.clone(), move |s: String, binary: bool| {
            use base64::Engine as _;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(s.trim())
                .unwrap_or_default();
            if binary {
                bytes.iter().map(|b| *b as char).collect::<String>()
            } else {
                String::from_utf8_lossy(&bytes).into_owned()
            }
        })
        .map_err(|e| format!("base64Decode: {e}"))?,
    )?;
    put(&host, 
        "md5",
        Function::new(ctx.clone(), move |s: String| {
            use md5::Digest as _;
            hex_bytes(&md5::Md5::digest(s.as_bytes()))
        })
        .map_err(|e| format!("md5: {e}"))?,
    )?;
    put(&host, 
        "sha256",
        Function::new(ctx.clone(), move |s: String| {
            use sha2::Digest as _;
            hex_bytes(&sha2::Sha256::digest(s.as_bytes()))
        })
        .map_err(|e| format!("sha256: {e}"))?,
    )?;
    put(&host, 
        "hmacSHA256",
        Function::new(ctx.clone(), move |msg: String, key: String| {
            use hmac::Mac as _;
            let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(key.as_bytes())
                .map_err(|_| "bad key".to_owned())
                .unwrap_or_else(|_| {
                    hmac::Hmac::<sha2::Sha256>::new_from_slice(b"").unwrap()
                });
            mac.update(msg.as_bytes());
            hex_bytes(&mac.finalize().into_bytes())
        })
        .map_err(|e| format!("hmacSHA256: {e}"))?,
    )?;
    put(&host, 
        "hmacSHA256Base64",
        Function::new(ctx.clone(), move |msg: String, key: String| {
            use base64::Engine as _;
            use hmac::Mac as _;
            let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(key.as_bytes())
                .unwrap_or_else(|_| hmac::Hmac::<sha2::Sha256>::new_from_slice(b"").unwrap());
            mac.update(msg.as_bytes());
            base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes())
        })
        .map_err(|e| format!("hmacSHA256Base64: {e}"))?,
    )?;
    put(&host,
        "hmacSHA1",
        Function::new(ctx.clone(), move |key_json: String, msg_json: String| {
            hmac_sha1_json(&key_json, &msg_json)
        })
        .map_err(|e| format!("hmacSHA1: {e}"))?,
    )?;

    put(&host,
        "sleep",
        Function::new(ctx.clone(), move |ms: i64| {
            let capped = ms.max(0).min(10_000) as u64;
            std::thread::sleep(std::time::Duration::from_millis(capped));
            true
        })
        .map_err(|e| format!("sleep: {e}"))?,
    )?;

    // arrives as a parameter (rquickjs passes it): capturing a
    // Ctx by value would cycle JS->Rust->Ctx and trip the GC
    // assertion at teardown.
    {
        let caps = caps.clone();
        put(&host,
            "fileCall",
            Function::new(
                ctx.clone(),
                move |ctx: rquickjs::Ctx<'_>, method: String, path: String, value: String, options: String| {
                    file_call_json(&caps, &ctx, &method, &path, &value, &options)
                },
            )
            .map_err(|e| format!("fileCall: {e}"))?,
        )?;
    }
    {
        let caps = caps.clone();
        put(&host,
            "downloadCall",
            Function::new(
                ctx.clone(),
                move |ctx: rquickjs::Ctx<'_>, url: String, path: String, opts: String| {
                    download_call_json(&caps, &ctx, &url, &path, &opts)
                },
            )
            .map_err(|e| format!("downloadCall: {e}"))?,
        )?;
    }
    {
        let caps = caps.clone();
        put(&host,
            "downloadSegmentsCall",
            Function::new(ctx.clone(), move |specs: String, path: String, _opts: String| {
                download_segments_json(&caps, &specs, &path)
            })
            .map_err(|e| format!("downloadSegmentsCall: {e}"))?,
        )?;
    }

    put(&host, 
        "mediaInfo",
        Function::new(ctx.clone(), move |_path: String| {
            serde_json::json!({"error": "quality unavailable"}).to_string()
        })
        .map_err(|e| format!("mediaInfo: {e}"))?,
    )?;
    put(&host, 
        "legacySanitize",
        Function::new(ctx.clone(), move |s: String| legacy_sanitize(&s))
            .map_err(|e| format!("legacySanitize: {e}"))?,
    )?;
    put(&host, 
        "legacyFilename",
        Function::new(ctx.clone(), move |pattern: String, fields: String| {
            legacy_filename(&pattern, &fields)
        })
        .map_err(|e| format!("legacyFilename: {e}"))?,
    )?;
    put(&host, 
        "legacyLocalTime",
        Function::new(ctx.clone(), move || legacy_local_time())
            .map_err(|e| format!("legacyLocalTime: {e}"))?,
    )?;
    put(&host, 
        "legacyQuality",
        Function::new(ctx.clone(), move |_path: String| {
            serde_json::json!({"error": "quality unavailable"}).to_string()
        })
        .map_err(|e| format!("legacyQuality: {e}"))?,
    )?;
    put(&host, 
        "legacyLyrics",
        Function::new(ctx.clone(), move |_a: String, _b: String, _c: String, _d: String, _e: String, _f: String| {
            serde_json::json!({"error": "lyrics unavailable"}).to_string()
        })
        .map_err(|e| format!("legacyLyrics: {e}"))?,
    )?;
    put(&host, 
        "legacyIsrc",
        Function::new(ctx.clone(), move |_add: bool, _d: String, _i: String, _p: String| {
            serde_json::json!({"error": "isrc index unavailable"}).to_string()
        })
        .map_err(|e| format!("legacyIsrc: {e}"))?,
    )?;
    // session (signed proxy sessions) / auth stubs
    if let Some(sctx) = session {
        put(&host,
            "sessionCall",
            Function::new(ctx.clone(), move |method: String, args: String| {
                let a: Value = serde_json::from_str(&args).unwrap_or(Value::Null);
                let arr = a.as_array().cloned().unwrap_or_default();
                sctx.call(&method, &arr).to_string()
            })
            .map_err(|e| format!("sessionCall: {e}"))?,
        )?;
    } else {
        put(&host,
            "sessionCall",
            Function::new(ctx.clone(), move |_method: String, _args: String| {
                serde_json::json!({"success": false, "error": "sessions unavailable"}).to_string()
            })
            .map_err(|e| format!("sessionCall: {e}"))?,
        )?;
    }
    put(&host, 
        "authCall",
        Function::new(ctx.clone(), move |method: String, _args: String| {
            match method.as_str() {
                "clearAuth" => serde_json::json!({"success": true}).to_string(),
                "getAuthCode" => "null".to_owned(),
                "isAuthenticated" => "false".to_owned(),
                "getTokens" => serde_json::json!({
                    "access_token": "", "refresh_token": "",
                    "is_authenticated": false, "expires_at": 0, "is_expired": true,
                })
                .to_string(),
                _ => serde_json::json!({"success": false, "error": "oauth unavailable"}).to_string(),
            }
        })
        .map_err(|e| format!("authCall: {e}"))?,
    )?;

    ctx.globals()
        .set("__needle_host", host)
        .map_err(|e| format!("host object: {e}"))?;
    Ok(())
}
