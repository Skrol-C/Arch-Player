//! Patterned block-cipher file transform (ported host API, MIT
//! attribution to SpotiFLAC-Mobile `file_transform.rs`: same
//! options contract, our own code). Deezer downloads need it:
//! the CDN bytes are Blowfish-CBC segments (every Nth chunk),
//! and only the selected segments decrypt - the rest pass
//! through untouched. Each selected segment restarts its IV.

use std::path::Path;

/// Stats returned to the extension (mirrors the reference shape).
pub struct TransformStats {
    pub path: String,
    pub bytes_processed: u64,
    pub segments_processed: u64,
    pub segments_transformed: u64,
}

fn decode_bytes(text: &str, encoding: &str) -> Result<Vec<u8>, String> {
    match encoding.to_lowercase().as_str() {
        "hex" => {
            let t = text.trim();
            if t.len() % 2 != 0 {
                return Err("odd hex length".to_owned());
            }
            (0..t.len())
                .step_by(2)
                .map(|i| {
                    u8::from_str_radix(&t[i..i + 2], 16)
                        .map_err(|_| "bad hex".to_owned())
                })
                .collect()
        }
        "base64" => {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD
                .decode(text.trim())
                .map_err(|_| "bad base64".to_owned())
        }
        _ => Ok(text.as_bytes().to_vec()),
    }
}

/// Cipher kind + raw key bytes. Key schedules rebuild per
/// selected segment (cheap at segment scale, borrow-clean).
enum Cipher {
    Blowfish(Vec<u8>),
    Aes128(Vec<u8>),
    Aes192(Vec<u8>),
    Aes256(Vec<u8>),
}

impl Cipher {
    fn block_size(&self) -> usize {
        match self {
            Cipher::Blowfish(_) => 8,
            Cipher::Aes128(_) | Cipher::Aes192(_) | Cipher::Aes256(_) => 16,
        }
    }
}

/// Transform `input` -> `output` per the options contract.
/// `progress(processed, total)` fires per buffer; errors abort.
pub fn transform(
    input: &Path,
    output: &Path,
    options_json: &str,
    progress: &dyn Fn(u64, u64),
) -> Result<TransformStats, String> {
    let opts: serde_json::Value =
        serde_json::from_str(options_json).map_err(|_| "bad transform options".to_owned())?;
    let g = |k: &str, fb: &str| {
        opts.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or(fb)
            .to_lowercase()
    };
    let gi = |k: &str, fb: i64| opts.get(k).and_then(|v| v.as_i64()).unwrap_or(fb);
    let gb = |k: &str, fb: bool| opts.get(k).and_then(|v| v.as_bool()).unwrap_or(fb);

    let algorithm = g("algorithm", "");
    if algorithm.is_empty() {
        return Err("algorithm is required".to_owned());
    }
    let mode = g("mode", "cbc");
    if mode != "cbc" {
        return Err(format!("unsupported block cipher mode: {mode}"));
    }
    if g("padding", "none") != "none" {
        return Err("patterned file transforms only support padding: none".to_owned());
    }
    let operation = g("operation", "decrypt");
    let decrypt = match operation.as_str() {
        "decrypt" => true,
        "encrypt" => false,
        _ => return Err("operation must be decrypt or encrypt".to_owned()),
    };
    let key = decode_bytes(
        opts.get("key").and_then(|v| v.as_str()).unwrap_or(""),
        &g("keyEncoding", "utf8"),
    )
    .map_err(|e| format!("invalid key: {e}"))?;
    if key.is_empty() {
        return Err("key is required".to_owned());
    }
    let iv = decode_bytes(
        opts.get("iv").and_then(|v| v.as_str()).unwrap_or(""),
        &g("ivEncoding", "utf8"),
    )
    .map_err(|e| format!("invalid iv: {e}"))?;

    let segment_size = gi("segmentSize", 0);
    let every = gi("transformEvery", 1);
    let offset = gi("transformOffset", 0);
    let buffer_size = gi("bufferSize", 1 << 20);
    let partial = gb("transformPartial", false);
    if !(1..=(16 * 1024 * 1024)).contains(&segment_size) {
        return Err("segmentSize out of range".to_owned());
    }
    if every <= 0 {
        return Err("transformEvery must be greater than zero".to_owned());
    }
    if offset < 0 || offset >= every {
        return Err("transformOffset out of range".to_owned());
    }
    let buffer_size = (buffer_size.clamp(segment_size, 16 * 1024 * 1024) as usize
        / segment_size as usize
        * segment_size as usize)
        .max(segment_size as usize);

    let cipher = build_cipher(&algorithm, &key)?;
    let block = cipher.block_size();
    if iv.len() != block {
        return Err(format!("iv must be {block} bytes for {algorithm}"));
    }
    if segment_size as usize % block != 0 {
        return Err(format!("segmentSize must be a multiple of {block} bytes"));
    }

    let mut src = std::fs::File::open(input)
        .map_err(|e| format!("failed to open input file: {e}"))?;
    let total = src
        .metadata()
        .map_err(|e| format!("failed to stat input file: {e}"))?
        .len();
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create output directory: {e}"))?;
    }
    let tmp = output.with_extension("transform.partial");
    let mut dst = std::fs::File::create(&tmp)
        .map_err(|e| format!("failed to create staged output: {e}"))?;

    use std::io::{Read, Write};
    let mut buffer = vec![0u8; buffer_size];
    let (mut processed, mut index, mut transformed) = (0u64, 0u64, 0u64);
    loop {
        let count = src
            .read(&mut buffer)
            .map_err(|e| format!("failed to read input file: {e}"))?;
        if count == 0 {
            break;
        }
        for segment in buffer[..count].chunks_mut(segment_size as usize) {
            if index % every as u64 == offset as u64
                && (segment.len() == segment_size as usize || partial)
            {
                if segment.len() % block != 0 {
                    let _ = std::fs::remove_file(&tmp);
                    return Err("selected segment is not a block multiple".to_owned());
                }
                cbc_crypt(&cipher, segment, &iv, decrypt)?;
                transformed += 1;
            }
            index += 1;
        }
        dst.write_all(&buffer[..count])
            .map_err(|e| format!("failed to write transformed file: {e}"))?;
        processed += count as u64;
        progress(processed, total);
    }
    drop(dst);
    std::fs::rename(&tmp, output)
        .map_err(|e| format!("failed to publish transformed file: {e}"))?;
    Ok(TransformStats {
        path: output.to_string_lossy().into_owned(),
        bytes_processed: processed,
        segments_processed: index,
        segments_transformed: transformed,
    })
}

fn build_cipher(algorithm: &str, key: &[u8]) -> Result<Cipher, String> {
    match algorithm {
        "blowfish" => {
            if !(4..=56).contains(&key.len()) {
                return Err("blowfish key must be 4-56 bytes".to_owned());
            }
            Ok(Cipher::Blowfish(key.to_vec()))
        }
        "aes" | "aes128" => {
            if key.len() != 16 {
                return Err("aes128 key must be 16 bytes".to_owned());
            }
            Ok(Cipher::Aes128(key.to_vec()))
        }
        "aes192" => {
            if key.len() != 24 {
                return Err("aes192 key must be 24 bytes".to_owned());
            }
            Ok(Cipher::Aes192(key.to_vec()))
        }
        "aes256" => {
            if key.len() != 32 {
                return Err("aes256 key must be 32 bytes".to_owned());
            }
            Ok(Cipher::Aes256(key.to_vec()))
        }
        _ => Err(format!("unsupported algorithm: {algorithm}")),
    }
}

/// CBC over one segment with a per-segment IV restart.
/// Hand-rolled chaining over raw block fns: no mode-crate
/// version archaeology, and the XOR order (decrypt-then-xor
/// with ciphertext chaining) stays visible for audit.
fn cbc_crypt(cipher: &Cipher, segment: &mut [u8], iv: &[u8], decrypt: bool) -> Result<(), String> {
    use cipher::{BlockDecrypt, BlockEncrypt};
    use generic_array::GenericArray;
    match cipher {
        Cipher::Blowfish(k) => {
            // Default byte order (big-endian): matches the
            // reference transform and Deezer's CDN bytes.
            fn bf(key: &[u8]) -> Result<blowfish::Blowfish, String> {
                // Import needed for KeyInit::new_from_slice even
                // though the lint cannot see the use through the
                // default type parameter.
                #[allow(unused_imports)]
                use cipher::KeyInit as _;
                blowfish::Blowfish::new_from_slice(key)
                    .map_err(|_| "bad blowfish key".to_owned())
            }
            let c = bf(k)?;
            let mut prev = iv.to_vec();
            for chunk in segment.chunks_mut(8) {
                if chunk.len() != 8 {
                    return Err("short trailing block".to_owned());
                }
                if decrypt {
                    let ct = chunk.to_vec();
                    let mut b = GenericArray::clone_from_slice(chunk);
                    c.decrypt_block(&mut b);
                    for (x, p) in b.iter_mut().zip(prev.iter()) {
                        *x ^= *p;
                    }
                    chunk.copy_from_slice(&b);
                    prev = ct;
                } else {
                    for (x, p) in chunk.iter_mut().zip(prev.iter()) {
                        *x ^= *p;
                    }
                    let mut b = GenericArray::clone_from_slice(chunk);
                    c.encrypt_block(&mut b);
                    chunk.copy_from_slice(&b);
                    prev = chunk.to_vec();
                }
            }
            Ok(())
        }
        Cipher::Aes128(k) => cbc_aes::<aes::Aes128>(k, segment, iv, decrypt),
        Cipher::Aes192(k) => cbc_aes::<aes::Aes192>(k, segment, iv, decrypt),
        Cipher::Aes256(k) => cbc_aes::<aes::Aes256>(k, segment, iv, decrypt),
    }
}

fn cbc_aes<C>(key: &[u8], segment: &mut [u8], iv: &[u8], decrypt: bool) -> Result<(), String>
where
    C: cipher::KeyInit + cipher::BlockEncrypt + cipher::BlockDecrypt,
{
    use generic_array::GenericArray;
    let c = C::new(GenericArray::from_slice(key));
    let mut prev = iv.to_vec();
    for chunk in segment.chunks_mut(16) {
        if chunk.len() != 16 {
            return Err("short trailing block".to_owned());
        }
        if decrypt {
            let ct = chunk.to_vec();
            let mut b = GenericArray::clone_from_slice(chunk);
            c.decrypt_block(&mut b);
            for (x, p) in b.iter_mut().zip(prev.iter()) {
                *x ^= *p;
            }
            chunk.copy_from_slice(&b);
            prev = ct;
        } else {
            for (x, p) in chunk.iter_mut().zip(prev.iter()) {
                *x ^= *p;
            }
            let mut b = GenericArray::clone_from_slice(chunk);
            c.encrypt_block(&mut b);
            chunk.copy_from_slice(&b);
            prev = chunk.to_vec();
        }
    }
    Ok(())
}
