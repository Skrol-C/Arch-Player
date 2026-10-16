//! Acoustic fingerprint for blank-slate files (Song Doctor
//! songfinder): decode (symphonia) -> mono -> resample 11025
//! (rubato) -> Chromaprint-compatible print (rusty-chromaprint,
//! MIT) -> base64 for AcoustID. File reads only; the AcoustID
//! lookup itself stays Dart `http`. Errors are data, never throws.
//!
//! Decode is capped at 150s per file (fpcalc-class lookups only
//! need the head): Doctor jobs stay fast on the Honor.

use std::path::Path;

use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use rubato::Resampler;
use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

const TARGET_RATE: u32 = 11025;
/// Head cap: fingerprint the first 150s, like fpcalc-class flows.
const MAX_SECS: u64 = 150;

/// Fingerprint `path`: `{ok:true, fingerprint, duration}` or
/// `{ok:false, error}` as a JSON string. Never panics across.
pub fn fingerprint_file(path: &str) -> String {
    match fingerprint_inner(path) {
        Ok((print, duration)) => serde_json::json!({
            "ok": true,
            "fingerprint": print,
            "duration": duration,
        })
        .to_string(),
        Err(e) => serde_json::json!({"ok": false, "error": e}).to_string(),
    }
}

fn fingerprint_inner(path: &str) -> Result<(String, u64), String> {
    if path.is_empty() || path.len() > 1024 {
        return Err("bad path".to_owned());
    }
    let file = std::fs::File::open(Path::new(path)).map_err(|_| "unreadable".to_owned())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|_| "unprobed".to_owned())?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| "no audio track".to_owned())?;
    let track_id = track.id;
    let params = &track.codec_params;
    let src_rate = params.sample_rate.unwrap_or(44100);
    let src_channels = params
        .channels
        .map(|c| c.count())
        .unwrap_or(2)
        .max(1) as usize;
    let duration = params.n_frames.map(|n| n / u64::from(src_rate)).unwrap_or(0);

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|_| "no decoder".to_owned())?;

    // Mono f32 at source rate, capped at the head window.
    let cap_samples = (u64::from(src_rate) * MAX_SECS) as usize;
    let mut mono: Vec<f32> = Vec::new();
    loop {
        if mono.len() >= cap_samples {
            break;
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(_) => continue,
        };
        append_mono(&decoded, src_channels, &mut mono, cap_samples);
        if mono.len() >= cap_samples {
            break;
        }
    }
    if mono.is_empty() {
        return Err("no audio".to_owned());
    }
    // Resample to the fingerprint rate (mono in, mono out).
    let input = resample_mono(&mono, src_rate, TARGET_RATE);
    let s16: Vec<i16> = input
        .iter()
        .map(|s| (s.clamp(-1.0, 1.0) * 32767.0).round() as i16)
        .collect();
    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    printer.start(TARGET_RATE, 1).map_err(|_| "printer init".to_owned())?;
    for chunk in s16.chunks(4096) {
        printer.consume(chunk);
    }
    printer.finish();
    let config = Configuration::preset_test2();
    let raw = FingerprintCompressor::from(&config).compress(printer.fingerprint());
    use base64::Engine;
    let print =
        base64::engine::general_purpose::STANDARD.encode(raw);
    Ok((print, duration))
}

fn append_mono(
    decoded: &AudioBufferRef,
    channels: usize,
    out: &mut Vec<f32>,
    cap: usize,
) {
    // Planar and interleaved both read through the Signal view;
    // average channels down to mono.
    let frames = decoded.frames();
    for f in 0..frames {
        if out.len() >= cap {
            break;
        }
        let mut sum = 0.0f32;
        let mut n = 0usize;
        for c in 0..channels {
            if c >= decoded.spec().channels.count() {
                break;
            }
            // Signal is implemented per sample type; read f32 via
            // the generic channel view with a type-dispatched copy.
            sum += sample_at(decoded, c, f);
            n += 1;
        }
        out.push(if n > 0 { sum / n as f32 } else { 0.0 });
    }
}

fn sample_at(buf: &AudioBufferRef, channel: usize, frame: usize) -> f32 {
    use AudioBufferRef::*;
    match buf {
        U8(b) => (b.chan(channel)[frame] as f32 / 128.0) - 1.0,
        U16(b) => (b.chan(channel)[frame] as f32 / 32768.0) - 1.0,
        U24(b) => (b.chan(channel)[frame].0 as f32 / 8388608.0) - 1.0,
        U32(b) => (b.chan(channel)[frame] as f32 / 2147483648.0) - 1.0,
        S8(b) => b.chan(channel)[frame] as f32 / 128.0,
        S16(b) => b.chan(channel)[frame] as f32 / 32768.0,
        S24(b) => b.chan(channel)[frame].0 as f32 / 8388608.0,
        S32(b) => b.chan(channel)[frame] as f32 / 2147483648.0,
        F32(b) => b.chan(channel)[frame],
        F64(b) => b.chan(channel)[frame] as f32,
    }
}

fn resample_mono(input: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if src_rate == dst_rate || input.is_empty() {
        return input.to_vec();
    }
    // Chunked FFT resample; tail flush keeps the end of the head.
    let chunk = 4096usize;
    let mut resampler = match rubato::FftFixedIn::<f32>::new(
        src_rate as usize,
        dst_rate as usize,
        chunk,
        2,
        1,
    ) {
        Ok(r) => r,
        Err(_) => return naive_resample(input, src_rate, dst_rate),
    };
    let mut out = Vec::new();
    let mut waves = vec![vec![0.0f32; chunk]];
    let mut pos = 0;
    while pos < input.len() {
        let take = (input.len() - pos).min(chunk);
        waves[0][..take].copy_from_slice(&input[pos..pos + take]);
        if take < chunk {
            for s in waves[0][take..chunk].iter_mut() {
                *s = 0.0;
            }
        }
        match resampler.process(&waves, None) {
            Ok(frames) => out.extend_from_slice(&frames[0]),
            Err(_) => break,
        }
        pos += take;
    }
    if out.is_empty() {
        return naive_resample(input, src_rate, dst_rate);
    }
    out
}

fn naive_resample(input: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    let ratio = src_rate as f64 / dst_rate as f64;
    let len = (input.len() as f64 / ratio).floor() as usize;
    (0..len)
        .map(|i| {
            let p = i as f64 * ratio;
            let i0 = p.floor() as usize;
            let i1 = (i0 + 1).min(input.len() - 1);
            let f = (p - p.floor()) as f32;
            input[i0] * (1.0 - f) + input[i1] * f
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine_wav(path: &std::path::Path, freq: f32, secs: u64, rate: u32) {
        let n = (rate as u64 * secs) as usize;
        let mut data = Vec::with_capacity(44 + n * 2);
        data.extend_from_slice(b"RIFF");
        data.extend_from_slice(&((36 + n * 2) as u32).to_le_bytes());
        data.extend_from_slice(b"WAVEfmt ");
        data.extend_from_slice(&16u32.to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes());
        data.extend_from_slice(&rate.to_le_bytes());
        data.extend_from_slice(&(rate * 2).to_le_bytes());
        data.extend_from_slice(&2u16.to_le_bytes());
        data.extend_from_slice(&16u16.to_le_bytes());
        data.extend_from_slice(b"data");
        data.extend_from_slice(&((n * 2) as u32).to_le_bytes());
        for i in 0..n {
            let t = i as f32 / rate as f32;
            // Harmonically rich + slow vibrato: pure sines are
            // degenerate inputs (near-zero prints for ANY pitch),
            // real music is never a bare tone.
            let vib = 1.0 + 0.01 * (2.0 * std::f32::consts::PI * 5.0 * t).sin();
            let s = (2.0 * std::f32::consts::PI * freq * vib * t).sin()
                + 0.5 * (2.0 * std::f32::consts::PI * freq * 2.0 * t).sin()
                + 0.25 * (2.0 * std::f32::consts::PI * freq * 3.0 * t).sin();
            data.extend_from_slice(&((s * 12000.0) as i16).to_le_bytes());
        }
        std::fs::write(path, data).unwrap();
    }

    #[test]
    fn fingerprint_deterministic_and_sized() {
        let dir = std::env::temp_dir().join(format!(
            "needle-fp-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a.wav");
        sine_wav(&f, 440.0, 8, 44100);
        let a = fingerprint_file(f.to_str().unwrap());
        let b = fingerprint_file(f.to_str().unwrap());
        let va: serde_json::Value = serde_json::from_str(&a).unwrap();
        assert_eq!(va["ok"], true, "envelope: {a}");
        assert_eq!(a, b, "same file, same print");
        assert!(va["fingerprint"].as_str().unwrap_or("").len() > 16);
    }

    #[test]
    fn fingerprint_distinguishes_tones() {
        let dir = std::env::temp_dir().join(format!(
            "needle-fp-test2-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let f1 = dir.join("a.wav");
        let f2 = dir.join("b.wav");
        sine_wav(&f1, 440.0, 8, 44100);
        sine_wav(&f2, 880.0, 8, 44100);
        let a = fingerprint_file(f1.to_str().unwrap());
        let b = fingerprint_file(f2.to_str().unwrap());
        assert_ne!(a, b, "different tones, different prints");
    }

    #[test]
    fn fingerprint_rejects_garbage() {
        let dir = std::env::temp_dir().join(format!(
            "needle-fp-test3-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("x.bin");
        std::fs::write(&f, b"not audio at all..........").unwrap();
        let out = fingerprint_file(f.to_str().unwrap());
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
    }
}
