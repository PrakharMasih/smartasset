//! The quick hash: a cheap identity that survives moves and renames and notices edits.
//!
//! BLAKE3 over the file size plus three 16 KiB samples (start, middle, end). Small files are hashed whole.
//! The full-content BLAKE3 used for exact duplicates (plan A1) is a separate, lazy job: reading every byte of a
//! multi-terabyte library during the browse pass would defeat the point of a fast first scan.

use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;

pub const QUICK_HASH_LEN: usize = 16;
const SAMPLE: usize = 16 * 1024;

/// macOS `SF_DATALESS`: the file's content lives in iCloud and is not on this Mac. Reading it would download it.
const SF_DATALESS: u32 = 0x4000_0000;

/// Whether `st_flags` marks a file as an undownloaded cloud placeholder.
#[must_use]
pub const fn is_dataless_flags(st_flags: u32) -> bool {
    st_flags & SF_DATALESS != 0
}

/// Computes the quick hash of an open file of the given size.
///
/// # Errors
/// Fails if the file cannot be read, or shrinks while being read (it is being written; try again later).
pub fn quick_hash(file: &File, size: u64) -> io::Result<[u8; QUICK_HASH_LEN]> {
    let mut hasher = blake3::Hasher::new();
    hasher.update(&size.to_le_bytes());
    let mut buf = vec![0u8; SAMPLE];
    if size <= (SAMPLE as u64) * 3 {
        let len = usize::try_from(size).unwrap_or(0);
        buf.resize(len, 0);
        file.read_exact_at(&mut buf, 0)?;
        hasher.update(&buf);
    } else {
        let mid = size / 2 - (SAMPLE as u64) / 2;
        for offset in [0, mid, size - SAMPLE as u64] {
            file.read_exact_at(&mut buf, offset)?;
            hasher.update(&buf);
        }
    }
    let digest = hasher.finalize();
    let mut out = [0u8; QUICK_HASH_LEN];
    out.copy_from_slice(&digest.as_bytes()[..QUICK_HASH_LEN]);
    Ok(out)
}

pub const CONTENT_HASH_LEN: usize = 32;

/// Read size for the full-content hash. Small enough that a pause or cancel is noticed within milliseconds.
const CHUNK: usize = 1024 * 1024;

/// Why a full-content hash did not produce a value.
#[derive(Debug)]
pub enum HashStop {
    /// The caller asked to stop (paused, cancelled, shutting down). Nothing is wrong with the file.
    Interrupted,
    /// Reading failed, or the file ended early or grew while it was read (someone is writing to it).
    Io(io::Error),
}

impl From<io::Error> for HashStop {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// The BLAKE3 hash of the whole file, which must be exactly `size` bytes long (plan A1).
///
/// Reads in 1 MiB chunks and asks `keep_going` between chunks so a pause or cancel takes effect quickly.
/// A file whose length differs from `size` before or after the read is an error, never a wrong hash.
pub fn content_hash(
    file: &File,
    size: u64,
    keep_going: &dyn Fn() -> bool,
) -> Result<[u8; CONTENT_HASH_LEN], HashStop> {
    if file.metadata()?.len() != size {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "file size changed").into());
    }
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; CHUNK];
    let mut offset = 0u64;
    while offset < size {
        if !keep_going() {
            return Err(HashStop::Interrupted);
        }
        let want = usize::try_from((size - offset).min(CHUNK as u64)).unwrap_or(CHUNK);
        file.read_exact_at(&mut buf[..want], offset)?;
        hasher.update(&buf[..want]);
        offset += want as u64;
    }
    if file.metadata()?.len() != size {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "file size changed while reading").into());
    }
    Ok(*hasher.finalize().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn file_with(bytes: &[u8]) -> (tempfile::NamedTempFile, File) {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(bytes).unwrap();
        f.flush().unwrap();
        let reopened = File::open(f.path()).unwrap();
        (f, reopened)
    }

    fn pattern(len: usize, seed: u8) -> Vec<u8> {
        (0..len).map(|i| u8::try_from((i * 31 + usize::from(seed)) % 251).unwrap()).collect()
    }

    #[test]
    fn same_content_same_hash_regardless_of_name() {
        let data = pattern(200_000, 1);
        let (_a, fa) = file_with(&data);
        let (_b, fb) = file_with(&data);
        assert_eq!(quick_hash(&fa, 200_000).unwrap(), quick_hash(&fb, 200_000).unwrap());
    }

    #[test]
    fn edits_in_the_samples_change_the_hash() {
        let data = pattern(200_000, 1);
        let base = {
            let (_f, f) = file_with(&data);
            quick_hash(&f, 200_000).unwrap()
        };
        for pos in [0, 100_000, 199_999] {
            let mut edited = data.clone();
            edited[pos] ^= 0xFF;
            let (_f, f) = file_with(&edited);
            assert_ne!(quick_hash(&f, 200_000).unwrap(), base, "edit at {pos}");
        }
    }

    #[test]
    fn size_is_part_of_the_identity() {
        let (_a, fa) = file_with(&[7u8; 1000]);
        let (_b, fb) = file_with(&[7u8; 1001]);
        assert_ne!(quick_hash(&fa, 1000).unwrap(), quick_hash(&fb, 1001).unwrap());
    }

    #[test]
    fn tiny_and_empty_files_work() {
        let (_a, fa) = file_with(b"");
        let (_b, fb) = file_with(b"x");
        assert!(quick_hash(&fa, 0).is_ok());
        assert_ne!(quick_hash(&fa, 0).unwrap(), quick_hash(&fb, 1).unwrap());
    }

    #[test]
    fn boundary_sizes() {
        for size in [SAMPLE * 3 - 1, SAMPLE * 3, SAMPLE * 3 + 1] {
            let (_f, f) = file_with(&pattern(size, 3));
            assert!(quick_hash(&f, size as u64).is_ok(), "{size}");
        }
    }

    #[test]
    fn a_file_that_shrank_is_an_error_not_a_wrong_hash() {
        let (_f, f) = file_with(&pattern(1000, 1));
        assert!(quick_hash(&f, 5_000_000).is_err());
    }

    fn full(f: &File, size: u64) -> [u8; CONTENT_HASH_LEN] {
        content_hash(f, size, &|| true).unwrap()
    }

    #[test]
    fn full_hash_matches_blake3_and_ignores_the_name() {
        for size in [0usize, 1, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK + 17] {
            let data = pattern(size, 9);
            let (_a, fa) = file_with(&data);
            let (_b, fb) = file_with(&data);
            let want = *blake3::hash(&data).as_bytes();
            assert_eq!(full(&fa, size as u64), want, "size {size}");
            assert_eq!(full(&fb, size as u64), want);
        }
    }

    #[test]
    fn full_hash_sees_an_edit_the_quick_hash_cannot() {
        // One byte changed between the 16 KiB samples: identical quick hash, different content.
        let size = 400_000usize;
        let data = pattern(size, 4);
        let mut edited = data.clone();
        edited[60_000] ^= 0x55;
        let (_a, fa) = file_with(&data);
        let (_b, fb) = file_with(&edited);
        assert_eq!(quick_hash(&fa, size as u64).unwrap(), quick_hash(&fb, size as u64).unwrap());
        assert_ne!(full(&fa, size as u64), full(&fb, size as u64));
    }

    #[test]
    fn full_hash_can_be_interrupted_and_refuses_a_wrong_length() {
        let (_f, f) = file_with(&pattern(3 * CHUNK, 1));
        let calls = std::cell::Cell::new(0);
        let stop_after_one = || {
            calls.set(calls.get() + 1);
            calls.get() <= 1
        };
        assert!(matches!(content_hash(&f, 3 * CHUNK as u64, &stop_after_one), Err(HashStop::Interrupted)));
        assert!(matches!(content_hash(&f, 5, &|| true), Err(HashStop::Io(_))));
        assert!(matches!(content_hash(&f, 4 * CHUNK as u64, &|| true), Err(HashStop::Io(_))));
    }

    /// `cargo test -p sa-index --release -- --ignored --nocapture`. Warm file cache: the ceiling is the hash, not the disk.
    #[test]
    #[ignore = "benchmark: hashes a 1 GiB file"]
    fn bench_full_hash_throughput() {
        let (_f, file) = file_with(&pattern(1 << 30, 5));
        let t = std::time::Instant::now();
        let h = content_hash(&file, 1 << 30, &|| true).unwrap();
        let secs = t.elapsed().as_secs_f64();
        println!("full hash of 1 GiB: {secs:.2} s = {:.0} MB/s ({h:02x?})", 1024.0 / secs);
    }

    #[test]
    fn dataless_flag() {
        assert!(is_dataless_flags(0x4000_0000));
        assert!(is_dataless_flags(0x4000_0001));
        assert!(!is_dataless_flags(0));
        assert!(!is_dataless_flags(0x0000_0020));
    }
}
