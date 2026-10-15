//! Extension loading and calls: manifest-gated, register-capture,
//! JSON across the boundary both ways. Every invocation gets a
//! fresh Runtime (total isolation); handles only hold static data
//! (manifest, source, dirs), never live JS values, so nothing
//! lifetime-fragile crosses calls. Errors are envelope data.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use rquickjs::{Context, Function, Object, Runtime};
use serde_json::Value;

use crate::host::{CallLog, Caps};

/// Manifest fields we honor: type roles, network allowlist,
/// storage/file permission gates, signed-session config (batch 2),
/// required runtime features (reported, enforced later), and
/// settings defaults merged under user values.
#[derive(serde::Deserialize)]
struct ManifestSetting {
    #[serde(default)]
    key: String,
    #[serde(default)]
    default: serde_json::Value,
}

struct LoadedExt {
    allow_hosts: Vec<String>,
    roles: Vec<String>,
    source: String,
    storage_dir: String,
    files_dir: String,
    namespace: String,
    storage_allowed: bool,
    file_allowed: bool,
    settings_defaults: serde_json::Value,
    required_features: Vec<String>,
    signed_session: Option<serde_json::Value>,
}

static HANDLES: std::sync::OnceLock<Mutex<HashMap<u64, LoadedExt>>> =
    std::sync::OnceLock::new();

fn handles() -> &'static Mutex<HashMap<u64, LoadedExt>> {
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

#[derive(serde::Deserialize)]
struct Manifest {
    #[serde(default)]
    name: String,
    #[serde(default)]
    r#type: Vec<String>,
    #[serde(default)]
    permissions: ManifestPerms,
    #[serde(default, rename = "signedSession")]
    signed_session: Option<serde_json::Value>,
    #[serde(default, rename = "requiredRuntimeFeatures")]
    required_runtime_features: Vec<String>,
    #[serde(default)]
    settings: Vec<ManifestSetting>,
}

#[derive(serde::Deserialize, Default)]
struct ManifestPerms {
    #[serde(default)]
    network: Vec<String>,
    #[serde(default)]
    storage: bool,
    #[serde(default)]
    file: bool,
}

fn err(e: &str) -> String {
    serde_json::json!({"ok": false, "error": e}).to_string()
}

/// Load an installed extension directory: validate manifest.json +
/// index.js, register a handle. Returns `{ok, handle, functions}`
/// on the next call (functions are listed then, not now - nothing
/// executes at load).
pub fn load(
    ext_dir: &str,
    namespace: &str,
    storage_dir: &str,
    files_dir: &str,
) -> String {
    if namespace.is_empty()
        || namespace.len() > 64
        || !namespace
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
    {
        return err("bad namespace");
    }
    let base = std::path::Path::new(ext_dir);
    let manifest_text = match std::fs::read_to_string(base.join("manifest.json")) {
        Err(_) => return err("no manifest"),
        Ok(t) => t,
    };
    if manifest_text.len() > 1024 * 1024 {
        return err("manifest too large");
    }
    let manifest: Manifest = match serde_json::from_str(&manifest_text) {
        Err(_) => return err("bad manifest"),
        Ok(m) => m,
    };
    if manifest.name.is_empty() {
        return err("bad manifest");
    }
    let source = match std::fs::read_to_string(base.join("index.js")) {
        Err(_) => return err("no entry script"),
        Ok(s) => s,
    };
    if source.len() > 1024 * 1024 {
        return err("script too large");
    }
    let mut roles = Vec::new();
    for t in &manifest.r#type {
        match t.as_str() {
            "metadata_provider" => roles.push("metadata".to_owned()),
            "download_provider" => roles.push("download".to_owned()),
            "lyrics_provider" => roles.push("lyrics".to_owned()),
            _ => {}
        }
    }
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    let mut defaults = serde_json::Map::new();
    for s in &manifest.settings {
        if !s.key.is_empty() {
            defaults.insert(s.key.clone(), s.default.clone());
        }
    }
    let ext = LoadedExt {
        allow_hosts: manifest.permissions.network,
        roles,
        source,
        storage_dir: storage_dir.to_owned(),
        files_dir: files_dir.to_owned(),
        namespace: namespace.to_owned(),
        storage_allowed: manifest.permissions.storage,
        file_allowed: manifest.permissions.file,
        settings_defaults: Value::Object(defaults),
        required_features: manifest.required_runtime_features,
        signed_session: manifest.signed_session,
    };
    match handles().lock() {
        Err(_) => return err("registry locked"),
        Ok(mut h) => {
            h.insert(handle, ext);
        }
    }
    serde_json::json!({"ok": true, "handle": handle}).to_string()
}

/// List the entry points a loaded extension registered, without
/// calling anything. Proves the script parses and registers.
pub fn functions(handle: u64, timeout: Duration) -> String {
    let ext = match handles().lock() {
        Err(_) => return err("registry locked"),
        Ok(h) => match h.get(&handle) {
            None => return err("no such extension"),
            Some(e) => e.clone(),
        },
    };
    // Reuse the call path with a probe entry that lists names.
    call_inner(&ext, "__needle_list", "{}", timeout)
}

/// Call a registered entry with JSON args. Fresh runtime per call;
/// the script registers, we capture, we invoke, we stringify.
pub fn call(
    handle: u64,
    entry: &str,
    args_json: &str,
    timeout: Duration,
) -> String {
    let ext = match handles().lock() {
        Err(_) => return err("registry locked"),
        Ok(h) => match h.get(&handle) {
            None => return err("no such extension"),
            Some(e) => e.clone(),
        },
    };
    if entry.is_empty() || entry.len() > 64 {
        return err("bad entry");
    }
    call_inner(&ext, entry, args_json, timeout)
}

impl Clone for LoadedExt {
    fn clone(&self) -> Self {
        LoadedExt {
            allow_hosts: self.allow_hosts.clone(),
            roles: self.roles.clone(),
            source: self.source.clone(),
            storage_dir: self.storage_dir.clone(),
            files_dir: self.files_dir.clone(),
            namespace: self.namespace.clone(),
            storage_allowed: self.storage_allowed,
            file_allowed: self.file_allowed,
            settings_defaults: self.settings_defaults.clone(),
            required_features: self.required_features.clone(),
            signed_session: self.signed_session.clone(),
        }
    }
}

fn call_inner(
    ext: &LoadedExt,
    entry: &str,
    args_json: &str,
    timeout: Duration,
) -> String {
    let log = CallLog::default();
    match call_inner_result(ext, entry, args_json, timeout, &log) {
        Ok(out) => out,
        // Failures carry the call log too: the extension's own
        // trace is the diagnosis, not just the one-liner.
        Err(e) => serde_json::json!({"ok": false, "error": e, "logs": log.drain()}).to_string(),
    }
}

fn call_inner_result(
    ext: &LoadedExt,
    entry: &str,
    args_json: &str,
    timeout: Duration,
    log: &CallLog,
) -> Result<String, String> {
    serde_json::from_str::<Value>(args_json)
        .map_err(|_| "args is not JSON".to_owned())?;

    let caps = Caps {
        allow_hosts: ext.allow_hosts.clone(),
        storage_dir: ext.storage_dir.clone(),
        files_dir: ext.files_dir.clone(),
        namespace: ext.namespace.clone(),
        storage_allowed: ext.storage_allowed,
        file_allowed: ext.file_allowed,
    };

    let rt = Runtime::new().map_err(|e| format!("runtime: {e}"))?;
    rt.set_memory_limit(64 * 1024 * 1024);
    rt.set_max_stack_size(512 * 1024);
    let start = Instant::now();
    rt.set_interrupt_handler(Some(Box::new(move || start.elapsed() > timeout)));

    let ctx = Context::full(&rt).map_err(|e| format!("context: {e}"))?;
    let deadline = Instant::now() + timeout;
    crate::host::set_call_deadline(Some(deadline));
    let out = ctx.with(|ctx| {
        let r = call_with_pump(
            &ctx,
            ext,
            &caps,
            log,
            entry,
            args_json,
            deadline,
        );
        r
    });
    crate::host::set_call_deadline(None);
    out
}

/// Resident settings for one call: manifest defaults under the
/// user values Dart persists at `<storage>/<ns>/settings.json`.
/// Missing file = defaults only. Never fails the call.
fn load_settings(ext: &LoadedExt) -> String {
    let mut merged = ext.settings_defaults.clone();
    let path = std::path::Path::new(&ext.storage_dir)
        .join(&ext.namespace)
        .join("settings.json");
    if let Ok(text) = std::fs::read_to_string(&path) {
        if let Ok(Value::Object(user)) = serde_json::from_str::<Value>(&text) {
            let map = merged.as_object_mut().cloned().unwrap_or_default();
            let mut map = map;
            for (k, v) in user {
                map.insert(k, v);
            }
            merged = Value::Object(map);
        }
    }
    if merged.is_null() {
        merged = Value::Object(serde_json::Map::new());
    }
    merged.to_string()
}

fn call_with_pump(
    ctx: &rquickjs::Ctx<'_>,
    ext: &LoadedExt,
    caps: &Caps,
    log: &CallLog,
    entry: &str,
    args_json: &str,
    deadline: Instant,
) -> Result<String, String> {
    crate::host::inject(ctx, caps, log)?;
    // Signed sessions switch on the manifest block; the config
    // rides per call (fresh runtime), records persist on disk.
    let session = ext.signed_session.as_ref().and_then(|v| {
        crate::session::SessionConfig::parse(v).map(|config| {
            crate::session::SessionCtx {
                config,
                storage_dir: ext.storage_dir.clone(),
                namespace: ext.namespace.clone(),
                allow_hosts: ext.allow_hosts.clone(),
            }
        })
    });
    // Pending deep-link grants auto-exchange before the entry
    // runs: Dart only writes the stash file, never needs to
    // invoke anything. Best-effort; failures surface from the
    // entry's own signed calls.
    if let Some(sctx) = session.as_ref() {
        let _ = sctx.consume_stashed_grant();
    }
    crate::host::inject_host(ctx, caps, log, session)?;
    ctx.eval::<(), _>(crate::prelude::PRELUDE.as_bytes())
        .map_err(|e| format!("prelude: {e}"))?;
    // Resident settings, then the extension script, then a
    // guarded initialize (its errors surface from entries, not
    // from boot: fresh runtime per call keeps this idempotent).
    let settings = load_settings(ext);
    ctx.eval::<(), _>(format!("globalThis.settings = {settings};").as_bytes())
        .map_err(|e| format!("settings: {e}"))?;
    ctx.eval::<(), _>(ext.source.as_bytes())
        .map_err(|e| crate::host::js_text(ctx, e, "eval"))?;
    let _ = ctx.eval::<(), _>(
        b"try { var __ni = globalThis.__needle_registry && globalThis.__needle_registry.initialize; if (typeof __ni === 'function') __ni(globalThis.settings || {}); } catch (e) {}",
    );

    // Probe entry lists captured function names without invoking.
    if entry == "__needle_list" {
        let out: String = ctx
            .eval(
                b"JSON.stringify({ok:true, value: (function(){ var r = globalThis.__needle_registry || {}; var n = []; for (var k in r) { try { if (typeof r[k] === 'function') n.push(k); } catch (e) {} } return n; })()})"
                    .as_slice(),
            )
            .map_err(|e| crate::host::js_text(ctx, e, "list"))?;
        let names: Value =
            serde_json::from_str(&out).map_err(|_| "result is not JSON".to_owned())?;
        let names = names.get("value").cloned().unwrap_or(Value::Null);
        return Ok(serde_json::json!({"ok": true, "value": names, "logs": log.drain()}).to_string());
    }
    let has_entry: bool = {
        let reg: Object = ctx
            .globals()
            .get("__needle_registry")
            .map_err(|_| "extension did not register".to_owned())?;
        let f: Result<Function, _> = reg.get(entry);
        f.is_ok()
    };
    if !has_entry {
        return Err(format!("no such function: {entry}"));
    }
    // Invoke through a driver snippet: the entry receives
    // positional args (arrays spread, anything else arrives as
    // the single argument), matching the calling convention
    // real extensions are written against. A Promise result
    // parks in `__needle_outcome` and the pump below settles
    // it (microtasks + due timers); sync results return now.
    let entry_lit =
        serde_json::to_string(entry).map_err(|_| "bad entry".to_owned())?;
    let driver = format!(
        r#"(function(){{
          try {{
            var fn = globalThis.__needle_registry[{entry}];
            if (typeof fn !== "function") return JSON.stringify({{ok:false, error:"no such function"}});
            var args = ({args});
            if (!Array.isArray(args)) args = [args];
            var r = fn.apply(null, args);
            if (r && typeof r.then === "function") {{
              globalThis.__needle_outcome = {{done:false}};
              r.then(function(v){{
                var val = v;
                if (typeof val === "string") {{ try {{ val = JSON.parse(val); }} catch (e) {{}} }}
                globalThis.__needle_outcome = {{done:true, ok:true, value:val}};
              }}, function(e){{
                globalThis.__needle_outcome = {{done:true, ok:false, error:__needle_err_text(e)}};
              }});
              return "NEEDLE_PENDING";
            }}
            var v = (typeof r === "string") ? (function(){{ try {{ return JSON.parse(r); }} catch(e) {{ return r; }} }})() : r;
            return JSON.stringify({{ok:true, value:v}});
          }} catch (e) {{
            return JSON.stringify({{ok:false, error:__needle_err_text(e)}});
          }}
        }})()"#,
        entry = entry_lit,
        args = args_json,
    );
    let out: String = ctx
        .eval(driver.as_bytes())
        .map_err(|e| crate::host::js_text(ctx, e, "invoke"))?;
    if out != "NEEDLE_PENDING" {
        return finish_value(&out, log);
    }
    // Pump: microtasks, then due timers (with real short waits so
    // backoff sleeps behave), until the promise settles or the
    // deadline hits. Bounded iterations; the interrupt handler
    // covers runaway sync code inside jobs.
    for _ in 0..100_000 {
        let mut progressed = false;
        for _ in 0..100 {
            // execute_pending_job reports whether a job ran.
            if ctx.execute_pending_job() {
                progressed = true;
            } else {
                break;
            }
        }
        if outcome_done(ctx)? {
            break;
        }
        let due_in: i64 = ctx
            .eval::<f64, _>(b"globalThis.__needle_nextDueIn()")
            .map(|f| f as i64)
            .unwrap_or(-1);
        if due_in >= 0 && Instant::now() + Duration::from_millis(due_in as u64) < deadline {
            if due_in > 0 {
                std::thread::sleep(Duration::from_millis(due_in.min(50) as u64));
            }
            let fired: i64 = ctx
                .eval::<f64, _>(b"globalThis.__needle_fireDue()")
                .map(|f| f as i64)
                .unwrap_or(0);
            if fired > 0 {
                progressed = true;
            }
        }
        if outcome_done(ctx)? {
            break;
        }
        if Instant::now() >= deadline {
            return Err("timeout".to_owned());
        }
        if !progressed {
            // Nothing left to run and the promise never settled.
            if due_in < 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    let final_json: String = ctx
        .eval(b"JSON.stringify(globalThis.__needle_outcome || {done:false})".as_slice())
        .map_err(|e| crate::host::js_text(ctx, e, "outcome"))?;
    let outcome: Value =
        serde_json::from_str(&final_json).map_err(|_| "result is not JSON".to_owned())?;
    if outcome.get("done") != Some(&Value::Bool(true)) {
        return Err("async entry never settled".to_owned());
    }
    if outcome.get("ok") != Some(&Value::Bool(true)) {
        let detail = outcome
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("extension failed")
            .to_owned();
        return Err(detail);
    }
    let value = outcome.get("value").cloned().unwrap_or(Value::Null);
    Ok(serde_json::json!({"ok": true, "value": unwrap_doubled(value)?, "logs": log.drain()}).to_string())
}

fn outcome_done(ctx: &rquickjs::Ctx<'_>) -> Result<bool, String> {
    let done: bool = ctx
        .eval(b"!!(globalThis.__needle_outcome && globalThis.__needle_outcome.done)".as_slice())
        .map_err(|e| crate::host::js_text(ctx, e, "outcome"))?;
    Ok(done)
}

/// Unwrap convention: a doubly-encoded JSON string unwraps one
/// more layer to the real value; a plain string that is not JSON
/// stays a string (extension entries may return raw text).
fn unwrap_doubled(mut value: Value) -> Result<Value, String> {
    for _ in 0..2 {
        match value {
            Value::String(ref s) => match serde_json::from_str(s) {
                Ok(v) => value = v,
                Err(_) => break,
            },
            _ => break,
        }
    }
    Ok(value)
}

fn finish_value(out: &str, log: &CallLog) -> Result<String, String> {
    let mut outer: Value =
        serde_json::from_str(out).map_err(|_| "result is not JSON".to_owned())?;
    if outer.get("ok") != Some(&Value::Bool(true)) {
        let detail = outer
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("extension failed")
            .to_owned();
        return Err(detail);
    }
    let value = outer.get_mut("value").map(Value::take).unwrap_or(Value::Null);
    let value = unwrap_doubled(value)?;
    Ok(serde_json::json!({"ok": true, "value": value, "logs": log.drain()}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ext(source: &str) -> LoadedExt {
        LoadedExt {
            allow_hosts: vec![],
            roles: vec!["metadata".to_owned()],
            source: source.to_owned(),
            storage_dir: std::env::temp_dir()
                .to_string_lossy()
                .into_owned(),
            files_dir: std::env::temp_dir().to_string_lossy().into_owned(),
            namespace: "t".to_owned(),
            storage_allowed: true,
            file_allowed: true,
            settings_defaults: Value::Object(serde_json::Map::new()),
            required_features: Vec::new(),
            signed_session: None,
        }
    }

    #[test]
    fn register_and_call() {
        let e = ext(
            r#"registerExtension({ searchTracks: (q) => JSON.stringify({got: q.q}) }); "ok""#,
        );
        let out = call_inner(&e, "searchTracks", r#"{"q":"ye"}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"]["got"], "ye");
    }
    #[test]
    fn positional_args_spread() {
        let e = ext(
            r#"registerExtension({ searchTracks: (q, lim) => JSON.stringify({got: q, n: lim}) }); "ok""#,
        );
        let out = call_inner(&e, "searchTracks", r#"["ye", 5]"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"]["got"], "ye");
        assert_eq!(v["value"]["n"], 5);
    }

    #[test]
    fn async_result_settles_via_pump() {
        let e = ext(
            r#"registerExtension({ go: () => Promise.resolve({n: 7}) }); "ok""#,
        );
        let out = call_inner(&e, "go", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"]["n"], 7);
    }

    #[test]
    fn async_rejection_is_data() {
        let e = ext(
            r#"registerExtension({ go: () => Promise.reject(new Error("bad")) }); "ok""#,
        );
        let out = call_inner(&e, "go", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn timers_fire_in_pump() {
        let e = ext(
            r#"registerExtension({ go: () => new Promise((res) => setTimeout(() => res("late"), 20)) }); "ok""#,
        );
        let out = call_inner(&e, "go", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"], "late");
    }

    #[test]
    fn prelude_surface() {
        let e = ext(
            r#"registerExtension({ go: () => {
              var u = new URL("https://x.test/p?a=1&b=2");
              var enc = new TextEncoder().encode("hi");
              var dec = new TextDecoder().decode([104, 105]);
              return {
                host: u.hostname, qa: u.searchParams.get("a"),
                md5: utils.md5("abc"), sha: utils.sha256("abc"),
                b64: btoa("hi"), back: atob("aGk="),
                enc: enc.length, dec: dec,
                norm: matching.normalizeString("  Hello, World! "),
                dur: matching.compareDuration(1000, 2500, 2000),
                sim: matching.compareStrings("abc", "abc")
              };
            } }); "ok""#,
        );
        let out = call_inner(&e, "go", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        let val = &v["value"];
        assert_eq!(val["host"], "x.test");
        assert_eq!(val["qa"], "1");
        assert_eq!(val["md5"], "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            val["sha"],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(val["b64"], "aGk=");
        assert_eq!(val["back"], "hi");
        assert_eq!(val["enc"], 2);
        assert_eq!(val["dec"], "hi");
        assert_eq!(val["norm"], "hello world");
        assert_eq!(val["dur"], true);
        assert_eq!(val["sim"], 1.0);
    }

    #[test]
    fn missing_entry_is_data() {
        let e = ext(r#"registerExtension({}); "ok""#);
        let out = call_inner(&e, "nope", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn list_probe() {
        let e = ext(
            r#"registerExtension({ getTrack: (x) => "{}", fetchLyrics: (x) => "{}" }); "ok""#,
        );
        let out = call_inner(&e, "__needle_list", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        let names = v["value"].as_array().unwrap();
        assert!(names.iter().any(|n| n == "getTrack"));
        assert!(names.iter().any(|n| n == "fetchLyrics"));
    }

    #[test]
    fn host_fns_visible_to_extensions() {
        let d = std::env::temp_dir().join(format!(
            "needle-ext-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        let mut e = ext(r#"registerExtension({ ping: () => __needle_store_set("k", "1") }); "ok""#);
        e.storage_dir = d.to_string_lossy().into_owned();
        let out = call_inner(&e, "ping", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
    }

    #[test]
    fn compat_surface_behaves() {
        let d = std::env::temp_dir().join(format!(
            "needle-compat-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        let mut e = ext(
            r#"registerExtension({ go: () => {
              log.info("hi");
              storage.set("k", {a: 1});
              cache.set("c", "v");
              var denied = http.get("https://example.com/");
              return JSON.stringify({
                got: storage.get("k").a,
                cached: cache.get("c"),
                denied: denied.error,
                nkeys: cache.keys().length
              });
            } }); "ok""#,
        );
        e.storage_dir = d.to_string_lossy().into_owned();
        let out = call_inner(&e, "go", r#"{}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"]["got"], 1);
        assert_eq!(v["value"]["cached"], "v");
        assert_eq!(v["value"]["denied"], "denied");
        assert_eq!(v["value"]["nkeys"], 1);
        assert!(v["logs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l.as_str().unwrap_or("").contains("hi")));
    }
}
