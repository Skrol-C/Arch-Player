//! Download engine, phase one: fetch bytes with streamed progress
//! and cooperative cancel, then atomic land. No conversion, no
//! tagging yet (separate slice with its own crates) - raw bytes,
//! honestly reported. Every failure is envelope data, including
//! cancel: callers never guess what happened.
//!
//! Fully synchronous (blocking HTTP, no async runtime): progress
//! flows through a plain callback, so unit tests drive the whole
//! engine with a Vec collector and no executor. The bridge adapts
//! the callback onto its stream.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;

use crate::api::DownloadProgress;

fn cancels() -> &'static Mutex<HashMap<u64, Arc<AtomicBool>>> {
    static CANCELS: std::sync::OnceLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> =
        std::sync::OnceLock::new();
    CANCELS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Fetch `url` (allowlist-gated) into `dest_path` (tmp + rename),
/// reporting progress through `report`. Returns the final envelope;
/// the terminal state also reports, so slow consumers still see
/// the end. Cancel via [cancel].
pub fn fetch(
    job_id: u64,
    url: &str,
    dest_path: &str,
    allow_hosts_json: &str,
    report: &dyn Fn(DownloadProgress),
) -> String {
    match fetch_inner(job_id, url, dest_path, allow_hosts_json, report) {
        Ok(out) => out,
        Err(e) => {
            report(DownloadProgress {
                downloaded: 0,
                total: None,
                done: true,
                error: Some(e.clone()),
                path: None,
            });
            serde_json::json!({"ok": false, "error": e}).to_string()
        }
    }
}

fn fetch_inner(
    job_id: u64,
    url: &str,
    dest_path: &str,
    allow_hosts_json: &str,
    report: &dyn Fn(DownloadProgress),
) -> Result<String, String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("bad scheme".to_owned());
    }
    let allow: Vec<String> =
        serde_json::from_str(allow_hosts_json).unwrap_or_default();
    if !crate::host::host_allowed(&allow, url) {
        return Err("denied".to_owned());
    }
    if dest_path.is_empty() || dest_path.len() > 1024 {
        return Err("bad destination".to_owned());
    }
    let dest = std::path::Path::new(dest_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "dest unavailable".to_owned())?;
    }
    let flag = Arc::new(AtomicBool::new(false));
    if let Ok(mut m) = cancels().lock() {
        m.insert(job_id, flag.clone());
    }

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent("ArchPlayer-Needle/0.1 (download)")
        .build()
        .map_err(|_| "http unavailable".to_owned())?;
    let mut res = client
        .get(url)
        .send()
        .map_err(|_| "http failed".to_owned())?;
    if !res.status().is_success() {
        return Err(format!("http {}", res.status().as_u16()));
    }
    let total = res.content_length();
    let tmp = dest.with_extension("part");
    let mut file =
        std::fs::File::create(&tmp).map_err(|_| "dest unavailable".to_owned())?;
    let mut downloaded: u64 = 0;
    let mut since_report: u64 = 0;
    {
        use std::io::Read;
        // blocking::Response implements Read: pull 64KB at a time
        // for progress + cancel granularity without an async runtime.
        let mut buf = [0u8; 64 * 1024];
        loop {
            if flag.load(Ordering::Relaxed) {
                drop(file);
                let _ = std::fs::remove_file(&tmp);
                return Err("cancelled".to_owned());
            }
            let n = res
                .read(&mut buf)
                .map_err(|_| "http failed".to_owned())?;
            if n == 0 {
                break;
            }
            {
                use std::io::Write;
                file.write_all(&buf[..n])
                    .map_err(|_| "write failed".to_owned())?;
            }
            downloaded += n as u64;
            since_report += n as u64;
            if downloaded > 500 * 1024 * 1024 {
                drop(file);
                let _ = std::fs::remove_file(&tmp);
                return Err("file over 500MB".to_owned());
            }
            // Report per ~256KB: alive progress without spam.
            if since_report >= 256 * 1024 {
                since_report = 0;
                report(DownloadProgress {
                    downloaded,
                    total,
                    done: false,
                    error: None,
                    path: None,
                });
            }
        }
    }
    drop(file);
    std::fs::rename(&tmp, dest).map_err(|_| "landing failed".to_owned())?;
    if let Ok(mut m) = cancels().lock() {
        m.remove(&job_id);
    }
    report(DownloadProgress {
        downloaded,
        total: Some(downloaded),
        done: true,
        error: None,
        path: Some(dest_path.to_owned()),
    });
    Ok(json!({"ok": true, "bytes": downloaded, "path": dest_path}).to_string())
}

/// Cooperative cancel: the next chunk boundary aborts and cleans
/// the partial file. Idempotent - unknown ids report false.
/// NOTE: cancel keeps resume partials (see [fetch_resume]): only
/// the legacy [fetch_inner] path deletes on cancel.
pub fn cancel(job_id: u64) -> bool {
    if let Ok(m) = cancels().lock() {
        if let Some(flag) = m.get(&job_id) {
            flag.store(true, Ordering::Relaxed);
            return true;
        }
    }
    false
}

// ----------------------------------------------------------------
// Resumable fetch: Range requests against a sidecar-validated
// partial. Cancel KEEPS the partial + sidecar (retry continues);
// only [discard] deletes them explicitly. Servers without Range
// or validator headers restart fresh, honestly logged. Progress
// `total` is always the FULL length so bars never jump backwards.
// ----------------------------------------------------------------

fn sidecar_path(tmp: &std::path::Path) -> std::path::PathBuf {
    let mut s = tmp.as_os_str().to_owned();
    s.push(".json");
    std::path::PathBuf::from(s)
}

fn read_sidecar(
    tmp: &std::path::Path,
) -> Option<(String, Option<String>, Option<String>, Option<u64>)> {
    let raw = std::fs::read_to_string(sidecar_path(tmp)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let url = v.get("url")?.as_str()?.to_owned();
    let etag = v.get("etag").and_then(|e| e.as_str()).map(|s| s.to_owned());
    let last = v
        .get("last_modified")
        .and_then(|e| e.as_str())
        .map(|s| s.to_owned());
    let total = v.get("total").and_then(|e| e.as_u64());
    Some((url, etag, last, total))
}

fn write_sidecar(
    tmp: &std::path::Path,
    url: &str,
    etag: Option<&str>,
    last: Option<&str>,
    total: Option<u64>,
) {
    let doc = json!({
        "url": url,
        "etag": etag,
        "last_modified": last,
        "total": total,
    });
    let _ = std::fs::write(sidecar_path(tmp), doc.to_string());
}

fn header_str(headers: &reqwest::header::HeaderMap, name: &str) -> Option<String> {
    headers.get(name)?.to_str().ok().map(|s| s.to_owned())
}

fn range_total(content_range: Option<String>) -> Option<u64> {
    let cr = content_range?;
    let i = cr.rfind('/')?;
    let total = cr[i + 1..].trim();
    if total == "*" {
        return None;
    }
    total.parse::<u64>().ok()
}

/// Resumable twin of [fetch]: same envelope contract, but a
/// previous partial (plus matching sidecar validators) continues
/// via Range instead of restarting. Returns the final envelope;
/// the terminal state also reports.
pub fn fetch_resume(
    job_id: u64,
    url: &str,
    dest_path: &str,
    allow_hosts_json: &str,
    report: &dyn Fn(DownloadProgress),
) -> String {
    match fetch_resume_inner(job_id, url, dest_path, allow_hosts_json, report) {
        Ok(out) => out,
        Err(e) => {
            report(DownloadProgress {
                downloaded: 0,
                total: None,
                done: true,
                error: Some(e.clone()),
                path: None,
            });
            serde_json::json!({"ok": false, "error": e}).to_string()
        }
    }
}

fn fetch_resume_inner(
    job_id: u64,
    url: &str,
    dest_path: &str,
    allow_hosts_json: &str,
    report: &dyn Fn(DownloadProgress),
) -> Result<String, String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("bad scheme".to_owned());
    }
    let allow: Vec<String> =
        serde_json::from_str(allow_hosts_json).unwrap_or_default();
    if !crate::host::host_allowed(&allow, url) {
        return Err("denied".to_owned());
    }
    if dest_path.is_empty() || dest_path.len() > 1024 {
        return Err("bad destination".to_owned());
    }
    let dest = std::path::Path::new(dest_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "dest unavailable".to_owned())?;
    }
    let flag = Arc::new(AtomicBool::new(false));
    if let Ok(mut m) = cancels().lock() {
        m.insert(job_id, flag.clone());
    }
    let cancelled = || flag.load(Ordering::Relaxed);

    let tmp = dest.with_extension("part");
    let have: u64 = std::fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
    // Resume only with a sidecar that names this URL plus at
    // least one validator. Anything else restarts fresh.
    let side = read_sidecar(&tmp);
    let (resume_from, want_etag, want_last) = match (&side, have) {
        (Some((u, e, l, _)), h) if u == url && h > 0 && (e.is_some() || l.is_some()) => {
            (h, e.clone(), l.clone())
        }
        _ => (0, None, None),
    };

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent("ArchPlayer-Needle/0.1 (download)")
        .build()
        .map_err(|_| "http unavailable".to_owned())?;

    // Attempt loop runs at most twice: ranged attempt, then one
    // fresh restart when the server refuses or validators move.
    let mut attempt = 0;
    let mut from = resume_from;
    let mut w_etag = want_etag;
    let mut w_last = want_last;
    loop {
        attempt += 1;
        let mut req = client.get(url);
        if from > 0 {
            req = req.header("Range", format!("bytes={from}-"));
        }
        let res = req.send().map_err(|_| "http failed".to_owned())?;
        let status = res.status().as_u16();
        if status == 416 {
            // Range unsatisfiable: stale partial. Restart once.
            let _ = std::fs::remove_file(&tmp);
            let _ = std::fs::remove_file(sidecar_path(&tmp));
            if attempt > 1 {
                return Err("http 416".to_owned());
            }
            from = 0;
            w_etag = None;
            w_last = None;
            continue;
        }
        if !(status == 200 || status == 206) {
            return Err(format!("http {status}"));
        }
        let r_etag = header_str(res.headers(), "etag");
        let r_last = header_str(res.headers(), "last-modified");
        if status == 206 && from > 0 {
            // Validator moved mid-flight: restart fresh, once.
            let stale = match (&w_etag, &r_etag, &w_last, &r_last) {
                (Some(w), Some(r), _, _) if w != r => true,
                (_, _, Some(w), Some(r)) if w != r => true,
                _ => false,
            };
            if stale {
                let _ = std::fs::remove_file(&tmp);
                let _ = std::fs::remove_file(sidecar_path(&tmp));
                if attempt > 1 {
                    return Err("validator moved".to_owned());
                }
                from = 0;
                w_etag = None;
                w_last = None;
                continue;
            }
        }
        let total = if status == 206 {
            range_total(header_str(res.headers(), "content-range"))
                .or_else(|| side.as_ref().and_then(|(_, _, _, t)| *t))
                .or_else(|| res.content_length().map(|n| n + from))
        } else {
            // 200 to a ranged request: server ignored Range.
            // Truncate and take the full body honestly.
            if from > 0 {
                from = 0;
                let _ = std::fs::remove_file(&tmp);
            }
            res.content_length()
        };
        write_sidecar(
            &tmp,
            url,
            r_etag.as_deref(),
            r_last.as_deref(),
            total,
        );
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(from > 0)
            .write(true)
            .truncate(from == 0)
            .open(&tmp)
            .map_err(|_| "dest unavailable".to_owned())?;
        let base = if from > 0 {
            file.metadata().map(|m| m.len()).unwrap_or(0)
        } else {
            0
        };
        // Report full-length totals from here: bars never jump.
        let full_total = total.or(Some(base));
        {
            use std::io::{Read, Write};
            let mut res = res;
            let mut buf = [0u8; 64 * 1024];
            let mut written = base;
            let mut since: u64 = 0;
            loop {
                if cancelled() {
                    // Resume path KEEPS the partial + sidecar:
                    // the retry continues from here.
                    report(DownloadProgress {
                        downloaded: written,
                        total: full_total,
                        done: true,
                        error: Some("cancelled".to_owned()),
                        path: None,
                    });
                    if let Ok(mut m) = cancels().lock() {
                        m.remove(&job_id);
                    }
                    return Err("cancelled".to_owned());
                }
                let n = res.read(&mut buf).map_err(|_| "http failed".to_owned())?;
                if n == 0 {
                    break;
                }
                file.write_all(&buf[..n])
                    .map_err(|_| "write failed".to_owned())?;
                written += n as u64;
                since += n as u64;
                if written > 500 * 1024 * 1024 {
                    return Err("file over 500MB".to_owned());
                }
                if since >= 256 * 1024 {
                    since = 0;
                    report(DownloadProgress {
                        downloaded: written,
                        total: full_total,
                        done: false,
                        error: None,
                        path: None,
                    });
                }
            }
            // Already-complete partial: land it without traffic.
            if let (Some(t), w) = (total, written) {
                if w < t {
                    return Err("short body".to_owned());
                }
            }
            drop(file);
            std::fs::rename(&tmp, dest).map_err(|_| "landing failed".to_owned())?;
            let _ = std::fs::remove_file(sidecar_path(&tmp));
            if let Ok(mut m) = cancels().lock() {
                m.remove(&job_id);
            }
            report(DownloadProgress {
                downloaded: written,
                total: Some(written),
                done: true,
                error: None,
                path: Some(dest_path.to_owned()),
            });
            return Ok(
                json!({"ok": true, "bytes": written, "path": dest_path, "resumed": base > 0})
                    .to_string(),
            );
        }
    }
}

/// Explicit discard for resume partials: deletes the `.part` file
/// plus its sidecar. Returns true when anything was removed.
pub fn discard(dest_path: &str) -> bool {
    if dest_path.is_empty() {
        return false;
    }
    let tmp = std::path::Path::new(dest_path).with_extension("part");
    let mut gone = false;
    if std::fs::remove_file(&tmp).is_ok() {
        gone = true;
    }
    if std::fs::remove_file(sidecar_path(&tmp)).is_ok() {
        gone = true;
    }
    gone
}

// ----------------------------------------------------------------
// Extension-side download core: the reference `file.download`
// semantics. Plain GET streams; chunked mode walks 1MB Range
// requests (YouTube's googlevideo CDN 403s large/non-ranged
// requests, hence the probe + sequential chunks + retries).
// Headers ride every request; progress reports (received, total);
// cancel is polled per chunk. Writes to `dest_tmp` (caller
// renames); 500MB cap; failures are data.
// ----------------------------------------------------------------

/// Fetch `url` into an already-created `dest_tmp` file (append
/// mode for segments, truncate for fresh). Returns bytes written.
pub fn download_to_file(
    url: &str,
    headers: &[(String, String)],
    chunked: bool,
    allow: &[String],
    dest_tmp: &std::path::Path,
    append: bool,
    cancelled: &dyn Fn() -> bool,
    report: &dyn Fn(u64, Option<u64>),
) -> Result<u64, String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("bad scheme".to_owned());
    }
    if !crate::host::host_allowed(allow, url) {
        return Err("denied".to_owned());
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent("ArchPlayer-Needle/0.1 (download)")
        .build()
        .map_err(|_| "http unavailable".to_owned())?;
    if chunked || url.contains("googlevideo") {
        download_chunked(&client, url, headers, dest_tmp, append, cancelled, report)
    } else {
        download_plain(&client, url, headers, dest_tmp, append, cancelled, report)
    }
}

fn apply_headers(
    b: reqwest::blocking::RequestBuilder,
    headers: &[(String, String)],
) -> reqwest::blocking::RequestBuilder {
    let mut b = b;
    for (k, v) in headers {
        if k.eq_ignore_ascii_case("range") {
            continue;
        }
        b = b.header(k, v);
    }
    if headers
        .iter()
        .all(|(k, _)| !k.eq_ignore_ascii_case("user-agent"))
    {
        b = b.header("User-Agent", "ArchPlayer-Needle/0.1 (download)");
    }
    b
}

fn stream_body(
    res: reqwest::blocking::Response,
    file: &mut std::fs::File,
    total: Option<u64>,
    base: u64,
    cancelled: &dyn Fn() -> bool,
    report: &dyn Fn(u64, Option<u64>),
) -> Result<u64, String> {
    use std::io::{Read, Write};
    let mut res = res;
    let mut buf = [0u8; 64 * 1024];
    let mut written = base;
    let mut since: u64 = 0;
    loop {
        if cancelled() {
            return Err("cancelled".to_owned());
        }
        let n = res.read(&mut buf).map_err(|_| "http failed".to_owned())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|_| "write failed".to_owned())?;
        written += n as u64;
        since += n as u64;
        if written > 500 * 1024 * 1024 {
            return Err("file over 500MB".to_owned());
        }
        if since >= 256 * 1024 {
            since = 0;
            report(written, total);
        }
    }
    report(written, total);
    Ok(written)
}

fn download_plain(
    client: &reqwest::blocking::Client,
    url: &str,
    headers: &[(String, String)],
    dest_tmp: &std::path::Path,
    append: bool,
    cancelled: &dyn Fn() -> bool,
    report: &dyn Fn(u64, Option<u64>),
) -> Result<u64, String> {
    let res = apply_headers(client.get(url), headers)
        .send()
        .map_err(|_| "http failed".to_owned())?;
    if !res.status().is_success() {
        return Err(format!("http {}", res.status().as_u16()));
    }
    let total = res.content_length();
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(append)
        .write(true)
        .truncate(!append)
        .open(dest_tmp)
        .map_err(|_| "dest unavailable".to_owned())?;
    let base = if append {
        file.metadata().map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };
    stream_body(res, &mut file, total, base, cancelled, report)
}

fn download_chunked(
    client: &reqwest::blocking::Client,
    url: &str,
    headers: &[(String, String)],
    dest_tmp: &std::path::Path,
    append: bool,
    cancelled: &dyn Fn() -> bool,
    report: &dyn Fn(u64, Option<u64>),
) -> Result<u64, String> {
    // Probe: 2 bytes reveal support + total via Content-Range.
    let probe = apply_headers(client.get(url), headers)
        .header("Range", "bytes=0-1")
        .send()
        .map_err(|_| "http failed".to_owned())?;
    if probe.status().as_u16() != 206 && probe.status().as_u16() != 200 {
        return Err(format!("chunked probe http {}", probe.status().as_u16()));
    }
    let mut total: Option<u64> = None;
    if let Some(cr) = probe.headers().get("Content-Range").and_then(|v| v.to_str().ok()) {
        if let Some(i) = cr.rfind('/') {
            total = cr[i + 1..].trim().parse::<u64>().ok();
        }
    }
    if total.is_none() {
        total = probe.content_length().filter(|n| *n > 2);
    }
    let full_body = probe.status().as_u16() == 200;
    drop(probe);

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .write(true)
        .open(dest_tmp)
        .map_err(|_| "dest unavailable".to_owned())?;
    let mut written = if append {
        file.metadata().map(|m| m.len()).unwrap_or(0)
    } else {
        // Fresh chunked download: truncate, then append chunks.
        drop(file);
        file = std::fs::File::create(dest_tmp).map_err(|_| "dest unavailable".to_owned())?;
        0
    };
    // A 200 probe already served the whole body: stream it plainly.
    if full_body && !append {
        drop(file);
        return download_plain(client, url, headers, dest_tmp, false, cancelled, report);
    }
    let chunk: u64 = 1024 * 1024;
    let mut offset = written;
    loop {
        if cancelled() {
            return Err("cancelled".to_owned());
        }
        if let Some(t) = total {
            if offset >= t {
                break;
            }
        }
        let end = match total {
            Some(t) => (offset + chunk - 1).min(t.saturating_sub(1)),
            None => offset + chunk - 1,
        };
        let mut res = None;
        for retry in 0..3 {
            let r = apply_headers(client.get(url), headers)
                .header("Range", format!("bytes={offset}-{end}"))
                .send();
            match r {
                Ok(r) if r.status().as_u16() == 206 || r.status().as_u16() == 200 => {
                    res = Some(r);
                    break;
                }
                Ok(r) if (r.status().as_u16() == 403 || r.status().as_u16() == 429) && retry < 2 => {
                    std::thread::sleep(Duration::from_secs((retry + 1) * 2));
                    continue;
                }
                Ok(r) => {
                    return Err(format!("chunked http {} at {offset}", r.status().as_u16()));
                }
                Err(_) if retry < 2 => {
                    std::thread::sleep(Duration::from_secs(retry + 1));
                    continue;
                }
                Err(_) => return Err(format!("chunked error at {offset}")),
            }
        }
        let r = res.ok_or_else(|| format!("chunked error at {offset}"))?;
        let got_full = r.status().as_u16() == 200;
        let before = written;
        written = stream_body(r, &mut file, total, written, cancelled, report)?;
        offset = written;
        if got_full {
            break;
        }
        if let Some(t) = total {
            if offset >= t {
                break;
            }
        } else if written - before < chunk {
            break;
        }
    }
    report(written, total.or(Some(written)));
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn denied_without_allowlist() {
        let dir = std::env::temp_dir();
        let dest = dir.join("needle-dl-test.bin");
        let dest = dest.to_string_lossy().into_owned();
        let out = fetch(
            999001,
            "https://example.com/",
            &dest,
            "[]",
            &|_| {},
        );
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "denied");
    }

    #[test]
    fn cancel_unknown_id_is_false() {
        assert!(!cancel(999002));
    }

    // Local Range-capable stub: canned body, ETag, honors Range,
    // answers 200 when `ignore_range` is set. One connection per
    // request is enough for these tests.
    struct Stub {
        body: Vec<u8>,
        etag: String,
        ignore_range: bool,
    }

    fn serve_once(listener: std::net::TcpListener, stub: Stub, n: usize) {
        for _ in 0..n {
            let (mut s, _) = listener.accept().unwrap();
            use std::io::{Read, Write};
            let mut req = [0u8; 4096];
            let rn = s.read(&mut req).unwrap_or(0);
            let head = String::from_utf8_lossy(&req[..rn]).into_owned();
            let range = if stub.ignore_range {
                None
            } else {
                head.lines().find_map(|l| {
                    let t = l.trim();
                    if t.to_ascii_lowercase().starts_with("range:") {
                        t.split_once(':').map(|(_, v)| v.trim().to_owned())
                    } else {
                        None
                    }
                })
            };
            let total = stub.body.len();
            let (status, start, end) = match range.as_deref() {
                Some(r) if r.starts_with("bytes=") => {
                    let n = r["bytes=".len()..].split('-').next().unwrap_or("0");
                    let from: usize = n.parse().unwrap_or(0);
                    if from >= total {
                        let h = format!(
                            "HTTP/1.1 416 Range Unsatisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        );
                        let _ = s.write_all(h.as_bytes());
                        continue;
                    }
                    ("206 Partial Content", from, total)
                }
                _ => ("200 OK", 0, total),
            };
            let extra = if status.starts_with("206") {
                format!("Content-Range: bytes {start}-{total}/{total}\r\n")
            } else {
                String::new()
            };
            let head = format!(
                "HTTP/1.1 {status}\r\n{extra}ETag: \"{}\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                stub.etag,
                end - start
            );
            let _ = s.write_all(head.as_bytes());
            let _ = s.write_all(&stub.body[start..end]);
        }
    }

    fn stub_server(body: &[u8], etag: &str, ignore_range: bool, n: usize) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let stub = Stub {
            body: body.to_vec(),
            etag: etag.to_owned(),
            ignore_range,
        };
        std::thread::spawn(move || serve_once(listener, stub, n));
        format!("http://127.0.0.1:{}/f.bin", addr.port())
    }

    fn unique_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "needle-rs-test-{tag}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn resume_appends_on_206() {
        // 1MB body; seed the first 256KB as a valid partial.
        let body: Vec<u8> = (0..1024 * 1024).map(|i| (i % 251) as u8).collect();
        let url = stub_server(&body, "v1", false, 4);
        let dir = unique_dir("resume206");
        let dest = dir.join("f.bin").to_string_lossy().into_owned();
        let tmp = dir.join("f.part");
        std::fs::write(&tmp, &body[..256 * 1024]).unwrap();
        std::fs::write(
            format!("{}.json", tmp.to_string_lossy()),
            r#"{"url":"__URL__","etag":"\"v1\"","last_modified":null,"total":1048576}"#
                .replace("__URL__", &url),
        )
        .unwrap();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen2 = seen.clone();
        let out = fetch_resume(
            999101,
            &url,
            &dest,
            r#"["127.0.0.1"]"#,
            &move |p: DownloadProgress| {
                seen2.lock().unwrap().push((p.downloaded, p.total, p.done));
            },
        );
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "envelope: {out}");
        assert_eq!(v["resumed"], true);
        let landed = std::fs::read(&dest).unwrap();
        assert_eq!(landed, body);
        let log = seen.lock().unwrap();
        let last = log.last().expect("progress reported");
        assert!(last.2);
        assert_eq!(last.0 as u64, 1024 * 1024);
        // Progress totals never ran backwards from the full length.
        for (d, t, _) in log.iter() {
            if let Some(total) = t {
                assert!(*total >= 1024 * 1024, "total {total} < full");
                assert!(*d <= *total);
            }
        }
    }

    #[test]
    fn resume_restarts_on_200() {
        // Server ignores Range: fresh full body lands intact.
        let body: Vec<u8> = (0..512 * 1024).map(|i| (i % 251) as u8).collect();
        let url = stub_server(&body, "v1", true, 4);
        let dir = unique_dir("resume200");
        let dest = dir.join("f.bin").to_string_lossy().into_owned();
        let tmp = dir.join("f.part");
        std::fs::write(&tmp, &body[..64 * 1024]).unwrap();
        std::fs::write(
            format!("{}.json", tmp.to_string_lossy()),
            r#"{"url":"__URL__","etag":"\"v1\"","last_modified":null,"total":524288}"#
                .replace("__URL__", &url),
        )
        .unwrap();
        let out =
            fetch_resume(999102, &url, &dest, r#"["127.0.0.1"]"#, &|_| {});
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "envelope: {out}");
        assert_eq!(std::fs::read(&dest).unwrap(), body);
    }

    #[test]
    fn resume_restarts_on_etag_move() {
        // Partial claims v1, server now serves v2: restart, new bytes.
        let v2: Vec<u8> = (0..256 * 1024).map(|i| (255 - (i % 251)) as u8).collect();
        let url = stub_server(&v2, "v2", false, 4);
        let dir = unique_dir("resumeetag");
        let dest = dir.join("f.bin").to_string_lossy().into_owned();
        let tmp = dir.join("f.part");
        std::fs::write(&tmp, vec![0u8; 64 * 1024]).unwrap();
        std::fs::write(
            format!("{}.json", tmp.to_string_lossy()),
            r#"{"url":"__URL__","etag":"\"v1\"","last_modified":null,"total":262144}"#
                .replace("__URL__", &url),
        )
        .unwrap();
        let out =
            fetch_resume(999103, &url, &dest, r#"["127.0.0.1"]"#, &|_| {});
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "envelope: {out}");
        assert_eq!(std::fs::read(&dest).unwrap(), v2);
    }

    #[test]
    fn discard_removes_partials() {
        let dir = unique_dir("discard");
        let dest = dir.join("f.bin").to_string_lossy().into_owned();
        let tmp = dir.join("f.part");
        std::fs::write(&tmp, b"half").unwrap();
        std::fs::write(format!("{}.json", tmp.to_string_lossy()), "{}").unwrap();
        assert!(discard(&dest));
        assert!(!tmp.exists());
        assert!(!discard(&dest));
    }

    #[test]
    fn small_download_lands() {
        let dir = std::env::temp_dir().join(format!(
            "needle-dl-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("page.html").to_string_lossy().into_owned();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen2 = seen.clone();
        let out = fetch(
            999003,
            "https://example.com/",
            &dest,
            r#"["example.com"]"#,
            &move |p: DownloadProgress| {
                seen2.lock().unwrap().push((p.downloaded, p.done));
            },
        );
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["bytes"].as_u64().unwrap_or(0) > 0);
        let log = seen.lock().unwrap();
        let last = log.last().expect("progress reported");
        assert!(last.0 > 0 && last.1);
        let bytes =
            std::fs::read(&dest).expect("landed file readable");
        assert_eq!(bytes.len() as u64, v["bytes"].as_u64().unwrap());
    }
}
