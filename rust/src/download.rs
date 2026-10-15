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
