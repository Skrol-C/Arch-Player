//! Needle core API surface. Every entry point is sync-or-async
//! through the bridge with errors as values: a Rust panic must
//! never cross into Dart (house rule 6 extends across the bridge,
//! enforced by the crate-wide catch-unwind policy in callers).

use std::time::Duration;

/// Bridge proof: round-trips a nonce. Used by startup diagnostics
/// and the engine handshake. Never removed.
pub fn needle_ping(nonce: String) -> String {
    format!("needle-ok:{nonce}")
}

/// Crate version for the diagnostics row and compat checks.
pub fn needle_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

/// Extension call: sandboxed JS with host capabilities (http
/// allowlist, namespaced storage, scoped files, call log).
/// `allow_hosts_json` is a JSON string array - unparseable fails
/// closed (deny all). Returns the envelope verbatim.
pub fn needle_extension_call(
    source: String,
    input_json: String,
    timeout_ms: u32,
    allow_hosts_json: String,
    storage_dir: String,
    files_dir: String,
    namespace: String,
) -> String {
    let timeout = Duration::from_millis(u64::from(timeout_ms.clamp(100, 30000)));
    let caps = match crate::host::Caps::parse(
        &allow_hosts_json,
        &storage_dir,
        &files_dir,
        &namespace,
    ) {
        Err(e) => {
            return serde_json::json!({"ok": false, "error": e}).to_string()
        }
        Ok(c) => c,
    };
    let log = crate::host::CallLog::default();
    crate::sandbox::eval_with(&caps, &log, &source, &input_json, timeout)
}

/// Self-test: proves the sandbox round-trips, reports JS errors as
/// data, and enforces timeouts. Called once at startup in debug;
/// the envelope is logged, never trusted blindly.
pub fn needle_selftest() -> String {
    let cases = [
        (
            "roundtrip",
            r#"JSON.stringify({got: JSON.parse(__needle_input).n + 1})"#,
            r#"{"n":41}"#,
        ),
        ("jserror", r#"throw new Error('nope')"#, "{}"),
    ];
    let mut results = Vec::new();
    for (name, src, input) in cases {
        let out = crate::sandbox::eval(src, input, Duration::from_secs(5));
        let ok = serde_json::from_str::<serde_json::Value>(&out)
            .map(|v| v.get("ok").and_then(|o| o.as_bool()).unwrap_or(false))
            .unwrap_or(false);
        results.push(format!("{name}={}", if ok == (name == "roundtrip") { "pass" } else { "FAIL" }));
    }
    let timeout_out = crate::sandbox::eval(
        "while(true){}",
        "{}",
        Duration::from_millis(200),
    );
    let timeout_ok = serde_json::from_str::<serde_json::Value>(&timeout_out)
        .map(|v| v.get("ok").and_then(|o| o.as_bool()) == Some(false))
        .unwrap_or(false);
    results.push(format!("timeout={}", if timeout_ok { "pass" } else { "FAIL" }));
    serde_json::json!({"selftest": results}).to_string()
}

