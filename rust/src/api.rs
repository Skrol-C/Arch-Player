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

/// Download a URL into a file with streamed progress (see
/// DownloadProgress) and cooperative cancel. Allowlist-gated,
/// tmp-then-rename landing, 500MB cap. Conversion and tagging
/// arrive in their own slice - this lands raw bytes, honestly
/// reported. Returns the final envelope; the terminal outcome also
/// streams (error/path fields), so slow consumers still see the end.
pub fn needle_download(
    job_id: u64,
    url: String,
    dest_path: String,
    allow_hosts_json: String,
    sink: crate::frb_generated::StreamSink<DownloadProgress>,
) -> String {
    crate::download::fetch(job_id, &url, &dest_path, &allow_hosts_json, &|p| {
        let _ = sink.add(p);
    })
}

/// Progress event streamed per chunk. `total` is None when the
/// server hides its length - the UI renders indeterminate then.
/// Terminal events carry the outcome (`done` always true at the
/// end; `error` set on failure, `path` on success). Defined here
/// (not in download.rs) so codegen emits its codec.
pub struct DownloadProgress {
    pub downloaded: u64,
    pub total: Option<u64>,
    pub done: bool,
    pub error: Option<String>,
    pub path: Option<String>,
}

/// Cooperative cancel for [needle_download]: the next chunk
/// boundary aborts and cleans the partial file. Idempotent.
pub fn needle_download_cancel(job_id: u64) -> bool {
    crate::download::cancel(job_id)
}

/// One-shot sandboxed eval with host capabilities (the pure path
/// used by runSandbox and the startup smoke). Extension loading
/// above is the stateful sibling; this stays for ad-hoc scripts.
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

/// Load an installed extension directory: validate manifest +
pub fn needle_ext_load(
    ext_dir: String,
    namespace: String,
    storage_dir: String,
    files_dir: String,
) -> String {
    crate::ext::load(&ext_dir, &namespace, &storage_dir, &files_dir)
}

/// List a loaded extension's registered entry points without
/// calling anything. Proves the script parses and registers.
pub fn needle_ext_functions(handle: u64, timeout_ms: u32) -> String {
    let timeout = Duration::from_millis(u64::from(timeout_ms.clamp(100, 30000)));
    crate::ext::functions(handle, timeout)
}

/// Call a registered entry with JSON args. Fresh runtime per call;
/// args cross as real JS values, results leave via JSON.stringify.
pub fn needle_ext_call(
    handle: u64,
    entry: String,
    args_json: String,
    timeout_ms: u32,
) -> String {
    let timeout = Duration::from_millis(u64::from(timeout_ms.clamp(100, 30000)));
    crate::ext::call(handle, &entry, &args_json, timeout)
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

