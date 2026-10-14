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

use rquickjs::{Context, Function};
use serde_json::{json, Value};

/// Capabilities for one extension call. Parsed from the bridge;
/// garbage fails closed (empty allowlist = deny all).
#[derive(Clone, Default)]
pub struct Caps {
    pub allow_hosts: Vec<String>,
    pub storage_dir: String,
    pub files_dir: String,
    pub namespace: String,
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
        })
    }

    fn host_allowed(&self, url: &str) -> bool {
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
        self.allow_hosts.iter().any(|a| {
            let a = a.to_lowercase();
            host == a || host.ends_with(&format!(".{a}"))
        })
    }

    fn store_path(&self, key: &str) -> Result<std::path::PathBuf, String> {
        if key.is_empty()
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
        let p = std::path::Path::new(rel);
        if p.is_absolute()
            || p.components().any(|c| {
                matches!(
                    c,
                    std::path::Component::ParentDir
                        | std::path::Component::Prefix(_)
                        | std::path::Component::RootDir
                )
            })
        {
            return Err("path escapes sandbox".to_owned());
        }
        Ok(std::path::Path::new(&self.files_dir).join(p))
    }
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
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                return err("bad scheme");
            }
            if !caps.host_allowed(&url) {
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
            let res = match client.get(&url).send() {
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
                "status": status,
                "body": String::from_utf8_lossy(&bytes).into_owned(),
            }))
        })
        .map_err(|e| format!("http inject: {e}"))?;
        globals
            .set("__needle_http", f)
            .map_err(|e| format!("http inject: {e}"))?;
    }
    Ok(())
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
