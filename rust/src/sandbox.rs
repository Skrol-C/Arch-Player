//! Permission-scoped JS sandbox (QuickJS via rquickjs, same engine
//! and shape as the proven recipe): one fresh Runtime per call for
//! total isolation, JSON strings across the boundary both ways,
//! memory cap + stack cap + deadline interrupt. Host capabilities
//! (http, storage, file) arrive later as injected functions; until
//! then the script computes over its input and returns JSON.

use std::time::{Duration, Instant};

use rquickjs::{Context, Runtime};
use serde_json::Value;

/// Evaluate `source` with `input_json` visible as the global
/// `__needle_input` (a JSON string; the script parses it). The
/// completion value must be a JSON string, validated before return.
/// Always returns an envelope - success and JS errors alike are
/// data, never panics: `{"ok":true,"value":...}` or
/// `{"ok":false,"error":"..."}`.
pub fn eval(source: &str, input_json: &str, timeout: Duration) -> String {
    match eval_inner(source, input_json, timeout) {
        Ok(out) => out,
        Err(e) => serde_json::json!({"ok": false, "error": e}).to_string(),
    }
}

fn eval_inner(source: &str, input_json: &str, timeout: Duration) -> Result<String, String> {
    eval_inner_caps(source, input_json, timeout, None)
}

/// Extension entry: same envelope, plus host capabilities and a
/// call log. `logs` rides the success envelope; failures carry the
/// error as before.
pub fn eval_with(
    caps: &crate::host::Caps,
    log: &crate::host::CallLog,
    source: &str,
    input_json: &str,
    timeout: Duration,
) -> String {
    match eval_inner_caps(source, input_json, timeout, Some((caps, log))) {
        Ok(out) => out,
        Err(e) => serde_json::json!({"ok": false, "error": e}).to_string(),
    }
}

fn eval_inner_caps(
    source: &str,
    input_json: &str,
    timeout: Duration,
    caps: Option<(&crate::host::Caps, &crate::host::CallLog)>,
) -> Result<String, String> {
    if input_json.len() > 1024 * 1024 {
        return Err("input over 1MB".to_owned());
    }
    if source.len() > 1024 * 1024 {
        return Err("source over 1MB".to_owned());
    }
    // Validate the input is JSON before it crosses into the VM.
    serde_json::from_str::<Value>(input_json)
        .map_err(|e| format!("input is not JSON: {e}"))?;

    let rt = Runtime::new().map_err(|e| format!("runtime: {e}"))?;
    rt.set_memory_limit(64 * 1024 * 1024);
    rt.set_max_stack_size(512 * 1024);
    let start = Instant::now();
    rt.set_interrupt_handler(Some(Box::new(move || start.elapsed() > timeout)));

    let ctx = Context::full(&rt).map_err(|e| format!("context: {e}"))?;
    ctx.with(|ctx| {
        if let Some((caps, log)) = caps {
            crate::host::inject(&ctx, caps, log)?;
        }
        ctx.globals()
            .set("__needle_input", input_json.to_owned())
            .map_err(|e| format!("input inject: {e}"))?;
        let out: String = ctx
            .eval(source.as_bytes())
            .map_err(|e| format!("eval: {e}"))?;
        // The script must return JSON text - validate, then wrap.
        // With host capabilities, the call log rides the envelope.
        let value: Value = serde_json::from_str(&out)
            .map_err(|_| "result is not JSON text".to_owned())?;
        match caps {
            Some((_, log)) => {
                Ok(serde_json::json!({"ok": true, "value": value, "logs": log.drain()}).to_string())
            }
            None => Ok(serde_json::json!({"ok": true, "value": value}).to_string()),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn echo_roundtrip() {
        let src = r#"JSON.stringify({got: JSON.parse(__needle_input).n + 1})"#;
        let out = eval(src, r#"{"n":41}"#, Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["value"]["got"], 42);
    }

    #[test]
    fn js_error_is_data() {
        let out = eval("throw new Error('nope')", "{}", Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn infinite_loop_dies() {
        let out = eval("while(true){}", "{}", Duration::from_secs(5));
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
    }
}
