#![allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    clippy::many_single_char_names,
    clippy::assert_is_empty,
    clippy::cast_possible_truncation
)]

use sa_core::{AssetId, FolderId};
use sa_index::{ScanOutcome, ScanReport, ScanTarget, ScannerPool, scan};
use sa_store::folders::{self, AddFolderOutcome};
use sa_store::{Db, assets, jobs, organize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

const NOW: i64 = 1_700_000_000_000;

struct Env {
    _dir: tempfile::TempDir,
    db: Db,
    pool: ScannerPool,
    volume: sa_core::VolumeId,
    media: PathBuf,
}

fn env() -> Env {
    let dir = tempfile::tempdir().unwrap();
    let (db, _) = Db::open(&dir.path().join("library.sqlite")).unwrap();
    let volume = db.write(|tx| folders::upsert_volume(tx, "V", "Disk", "/", true, NOW)).unwrap();
    let media = dir.path().join("media");
    fs::create_dir_all(&media).unwrap();
    Env { _dir: dir, db, pool: ScannerPool::new(3).unwrap(), volume, media }
}

impl Env {
    fn folder(&self, root: &Path, excludes: &[&str]) -> (FolderId, ScanTarget) {
        let v = self.volume;
        let rel = root.to_str().unwrap().trim_start_matches('/').to_string();
        let out = self.db.write(move |tx| folders::add_folder(tx, v, &rel, "f", None, NOW)).unwrap();
        let AddFolderOutcome::Added { id, .. } = out else { panic!("{out:?}") };
        (
            id,
            ScanTarget {
                folder: id,
                root: root.to_path_buf(),
                dir: String::new(),
                excludes: excludes.iter().map(|s| (*s).to_string()).collect(),
                lane: 4,
            },
        )
    }

    fn scan(&self, t: &ScanTarget) -> ScanReport {
        scan(&self.db, &self.pool, t, &AtomicBool::new(false), &|_| {}).unwrap()
    }

    fn rows(&self) -> Vec<(i64, String, i64)> {
        self.db
            .read(|c| {
                let mut s = c.prepare("SELECT id, rel_path, status FROM assets ORDER BY rel_path").unwrap();
                Ok(s.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(Result::unwrap).collect())
            })
            .unwrap()
    }

    fn count(&self, sql: &'static str) -> i64 {
        self.db.read(|c| Ok(c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap())).unwrap()
    }

    fn id_of(&self, rel: &str) -> AssetId {
        let rel = rel.to_string();
        let id = self
            .db
            .read(move |c| Ok(c.query_row("SELECT id FROM assets WHERE rel_path = ?1", [&rel], |r| r.get::<_, i64>(0)).unwrap()))
            .unwrap();
        AssetId(id)
    }
}

fn put(root: &Path, rel: &str, content: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, content.repeat(40)).unwrap();
    set_mtime(&p, 1_600_000_000);
}

fn set_mtime(p: &Path, secs: u64) {
    let f = fs::OpenOptions::new().write(true).open(p).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs)).unwrap();
}

#[test]
fn first_scan_indexes_media_and_skips_everything_else() {
    let e = env();
    put(&e.media, "a.jpg", "a");
    put(&e.media, "clip/b.MOV", "b");
    put(&e.media, "clip/deep/c.wav", "c");
    put(&e.media, "notes.txt", "text");
    put(&e.media, "doc.pdf", "pdf");
    put(&e.media, ".hidden.jpg", "h");
    put(&e.media, "._a.jpg", "apple double");
    put(&e.media, ".secret/d.jpg", "d");
    put(&e.media, "Library.photoslibrary/originals/e.jpg", "e");
    put(&e.media, "skipme/f.jpg", "f");
    put(&e.media, "empty.jpg", "");
    std::os::unix::fs::symlink(e.media.join("a.jpg"), e.media.join("link.jpg")).unwrap();
    std::os::unix::fs::symlink(e.media.join("clip"), e.media.join("clip-link")).unwrap();

    let (_, target) = e.folder(&e.media, &["skipme"]);
    let r = e.scan(&target);
    assert_eq!(r.outcome, ScanOutcome::Completed);
    let paths: Vec<String> = e.rows().into_iter().map(|r| r.1).collect();
    assert_eq!(paths, vec!["a.jpg", "clip/b.MOV", "clip/deep/c.wav", "empty.jpg"]);
    assert_eq!(r.new_files, 4);
    assert_eq!(e.count("SELECT COUNT(*) FROM jobs WHERE kind = 'media' AND state = 0"), 4);
    assert_eq!(e.count("SELECT COUNT(*) FROM asset_fts"), 4);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE kind = 1"), 1, "MOV is a video, case-insensitively");
}

#[test]
fn rescanning_an_unchanged_folder_changes_nothing() {
    let e = env();
    for i in 0..30 {
        put(&e.media, &format!("d{}/f{i}.jpg", i % 3), &format!("content {i}"));
    }
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    let before = e.rows();
    let jobs_before = e.count("SELECT SUM(updated_at) FROM jobs");
    let r = e.scan(&target);
    assert_eq!((r.new_files, r.changed, r.relinked, r.marked_missing, r.restored), (0, 0, 0, 0, 0));
    assert_eq!(e.rows(), before);
    assert_eq!(e.count("SELECT SUM(updated_at) FROM jobs"), jobs_before, "no job was touched");
    assert_eq!(e.count("SELECT COUNT(*) FROM assets"), 30);
}

#[test]
fn new_changed_deleted_and_restored_files() {
    let e = env();
    put(&e.media, "keep.jpg", "keep");
    put(&e.media, "edit.jpg", "edit v1");
    put(&e.media, "touch.jpg", "touch");
    put(&e.media, "gone.jpg", "gone");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    // Pretend the media worker finished everything.
    e.db.write(|tx| {
        tx.execute("UPDATE assets SET probe_state = 1", []).unwrap();
        tx.execute("UPDATE jobs SET state = 2", []).unwrap();
        Ok(())
    })
    .unwrap();
    let gone_id = e.id_of("gone.jpg");
    e.db.write(move |tx| organize::set_rating(tx, &[gone_id], 3)).unwrap();

    put(&e.media, "new.jpg", "brand new");
    put(&e.media, "edit.jpg", "edit v2 is longer");
    set_mtime(&e.media.join("touch.jpg"), 1_700_000_123);
    fs::remove_file(e.media.join("gone.jpg")).unwrap();

    let r = e.scan(&target);
    assert_eq!((r.new_files, r.changed, r.marked_missing), (1, 2, 1), "{r:?}");
    // Changed files are queued again and their probe result is invalidated.
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE probe_state = 0"), 3);
    assert_eq!(e.count("SELECT COUNT(*) FROM jobs WHERE state = 0"), 3);
    let rows = e.rows();
    assert_eq!(rows.iter().find(|r| r.1 == "gone.jpg").unwrap().2, 1, "missing, not deleted");
    assert_eq!(e.count("SELECT rating FROM assets WHERE rel_path = 'gone.jpg'"), 3, "its rating is kept");
    assert_eq!(e.count("SELECT COUNT(*) FROM jobs WHERE asset_id = (SELECT id FROM assets WHERE rel_path='gone.jpg') AND state = 0"), 0);

    // The file comes back: same record, present again.
    put(&e.media, "gone.jpg", "gone");
    let r = e.scan(&target);
    assert_eq!((r.restored, r.new_files, r.changed), (1, 0, 0), "{r:?}");
    assert_eq!(e.id_of("gone.jpg"), gone_id);
    assert_eq!(e.count("SELECT status FROM assets WHERE rel_path = 'gone.jpg'"), 0);
}

#[test]
fn rename_and_move_keep_the_asset_and_everything_attached_to_it() {
    let e = env();
    put(&e.media, "shoot/IMG_0001.jpg", "photo one");
    put(&e.media, "shoot/IMG_0002.jpg", "photo two");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    let id1 = e.id_of("shoot/IMG_0001.jpg");
    let id2 = e.id_of("shoot/IMG_0002.jpg");
    e.db.write(move |tx| {
        organize::set_rating(tx, &[id1], 5)?;
        organize::add_tags(tx, &[id1], &["hero".into()])?;
        organize::set_rating(tx, &[id2], 2)
    })
    .unwrap();

    fs::rename(e.media.join("shoot/IMG_0001.jpg"), e.media.join("shoot/Sunset.jpg")).unwrap();
    fs::create_dir_all(e.media.join("final")).unwrap();
    fs::rename(e.media.join("shoot/IMG_0002.jpg"), e.media.join("final/IMG_0002.jpg")).unwrap();

    let r = e.scan(&target);
    assert_eq!((r.relinked, r.new_files, r.marked_missing), (2, 0, 0), "{r:?}");
    assert_eq!(e.id_of("shoot/Sunset.jpg"), id1);
    assert_eq!(e.id_of("final/IMG_0002.jpg"), id2);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets"), 2, "no duplicate records");
    assert_eq!(e.count("SELECT rating FROM assets WHERE id = (SELECT id FROM assets WHERE name = 'Sunset.jpg')"), 5);
    assert_eq!(e.count("SELECT COUNT(*) FROM asset_tags"), 1);
    assert_eq!(e.count("SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'sunset'"), 1);
    assert_eq!(e.count("SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'img_0001'"), 0);
}

#[test]
fn moving_between_two_added_folders_works_in_either_scan_order() {
    for source_first in [true, false] {
        let e = env();
        let (a, b) = (e.media.join("A"), e.media.join("B"));
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        put(&a, "clip.mov", "the clip");
        put(&a, "other.mov", "other clip");
        let (fa, ta) = e.folder(&a, &[]);
        let (fb, tb) = e.folder(&b, &[]);
        e.scan(&ta);
        e.scan(&tb);
        let id = e.id_of("clip.mov");
        e.db.write(move |tx| {
            organize::set_rating(tx, &[id], 4)?;
            organize::add_tags(tx, &[id], &["b-roll".into()])
        })
        .unwrap();

        fs::rename(a.join("clip.mov"), b.join("clip.mov")).unwrap();
        if source_first {
            e.scan(&ta);
            e.scan(&tb);
        } else {
            e.scan(&tb);
            e.scan(&ta);
        }
        let (folder, status): (i64, i64) = e
            .db
            .read(|c| Ok(c.query_row("SELECT folder_id, status FROM assets WHERE id = ?1", [id.0], |r| Ok((r.get(0)?, r.get(1)?))).unwrap()))
            .unwrap();
        assert_eq!((folder, status), (fb.0, 0), "source_first={source_first}: the asset moved folders");
        assert_eq!(e.count("SELECT COUNT(*) FROM assets"), 2, "source_first={source_first}: no duplicate");
        assert_eq!(e.count("SELECT rating FROM assets WHERE name = 'clip.mov'"), 4);
        assert_eq!(e.count("SELECT COUNT(*) FROM asset_tags"), 1);
        assert_ne!(fa, fb);
    }
}

#[test]
fn a_new_twin_with_its_own_user_data_is_never_merged_away() {
    let e = env();
    let (a, b) = (e.media.join("A"), e.media.join("B"));
    fs::create_dir_all(&a).unwrap();
    fs::create_dir_all(&b).unwrap();
    put(&a, "x.jpg", "same bytes");
    let (_, ta) = e.folder(&a, &[]);
    let (_, tb) = e.folder(&b, &[]);
    e.scan(&ta);
    e.scan(&tb);
    // The user copies the file to B, rates the copy, then deletes the original.
    put(&b, "x copy.jpg", "same bytes");
    e.scan(&tb);
    let copy = e.id_of("x copy.jpg");
    e.db.write(move |tx| organize::set_rating(tx, &[copy], 5)).unwrap();
    fs::remove_file(a.join("x.jpg")).unwrap();
    let r = e.scan(&ta);
    assert_eq!(r.merged_twins, 0, "the rated copy keeps its own record");
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE status = 1"), 1);
    assert_eq!(e.count("SELECT rating FROM assets WHERE name = 'x copy.jpg'"), 5);
}

#[test]
fn identical_duplicates_are_told_apart_by_name() {
    let e = env();
    put(&e.media, "one/dup.jpg", "identical content");
    put(&e.media, "two/dup.jpg", "identical content");
    put(&e.media, "three/other-name.jpg", "identical content");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    let ids: Vec<i64> = ["one/dup.jpg", "two/dup.jpg", "three/other-name.jpg"].iter().map(|p| e.id_of(p).0).collect();
    let i0 = AssetId(ids[0]);
    e.db.write(move |tx| organize::set_rating(tx, &[i0], 5)).unwrap();
    // `one/dup.jpg` is moved to `moved/dup.jpg`; the other two stay put.
    fs::create_dir_all(e.media.join("moved")).unwrap();
    fs::rename(e.media.join("one/dup.jpg"), e.media.join("moved/dup.jpg")).unwrap();
    let r = e.scan(&target);
    assert_eq!((r.relinked, r.marked_missing, r.new_files), (1, 0, 0), "{r:?}");
    assert_eq!(e.count("SELECT rating FROM assets WHERE rel_path = 'moved/dup.jpg'"), 5);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets"), 3);
}

#[test]
fn cancelling_never_marks_anything_missing() {
    let e = env();
    for i in 0..20 {
        put(&e.media, &format!("f{i}.jpg"), &format!("c{i}"));
    }
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    fs::remove_file(e.media.join("f1.jpg")).unwrap();
    let cancel = AtomicBool::new(true);
    let r = scan(&e.db, &e.pool, &target, &cancel, &|_| {}).unwrap();
    assert_eq!(r.outcome, ScanOutcome::Cancelled);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE status = 1"), 0);
    // A normal scan afterwards does find it.
    let r = e.scan(&target);
    assert_eq!(r.marked_missing, 1);
}

#[test]
fn an_unreadable_subfolder_is_left_alone() {
    use std::os::unix::fs::PermissionsExt;
    let e = env();
    put(&e.media, "ok/a.jpg", "a");
    put(&e.media, "locked/b.jpg", "b");
    put(&e.media, "locked/deeper/c.jpg", "c");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    let locked = e.media.join("locked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let r = e.scan(&target);
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(r.marked_missing, 0, "files we could not look at are not missing: {r:?}");
    assert_eq!(r.unreadable_dirs, vec!["locked".to_string()]);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE status = 1"), 0);
}

#[test]
fn an_unreachable_root_is_an_error_and_changes_nothing() {
    let e = env();
    put(&e.media, "a.jpg", "a");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    fs::remove_dir_all(&e.media).unwrap();
    let err = scan(&e.db, &e.pool, &target, &AtomicBool::new(false), &|_| {}).unwrap_err();
    assert!(matches!(err, sa_core::Error::Io { .. }), "{err:?}");
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE status = 1"), 0);
}

#[test]
fn a_folder_that_suddenly_looks_empty_is_held_back_not_wiped() {
    let e = env();
    for i in 0..25 {
        put(&e.media, &format!("f{i}.jpg"), &format!("c{i}"));
    }
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    for entry in fs::read_dir(&e.media).unwrap() {
        fs::remove_file(entry.unwrap().path()).unwrap();
    }
    let r = e.scan(&target);
    assert!(r.held_back_missing, "{r:?}");
    assert_eq!(r.marked_missing, 0);
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE status = 1"), 0);
}

#[test]
fn scanning_a_subdirectory_only_touches_that_subtree() {
    let e = env();
    put(&e.media, "a/1.jpg", "1");
    put(&e.media, "b/2.jpg", "2");
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    fs::remove_file(e.media.join("a/1.jpg")).unwrap();
    fs::remove_file(e.media.join("b/2.jpg")).unwrap();
    put(&e.media, "a/3.jpg", "3");
    put(&e.media, "b/4.jpg", "4");

    let sub = ScanTarget { dir: "a".into(), ..target.clone() };
    let r = e.scan(&sub);
    assert_eq!((r.new_files, r.marked_missing), (1, 1));
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE rel_path LIKE 'b/%' AND status = 0"), 1, "b is untouched");
    assert_eq!(e.count("SELECT COUNT(*) FROM assets WHERE rel_path = 'b/4.jpg'"), 0, "b/4.jpg is not discovered yet");

    // A directory that was deleted outright marks everything below it missing.
    fs::remove_dir_all(e.media.join("b")).unwrap();
    let r = e.scan(&ScanTarget { dir: "b".into(), ..target });
    assert_eq!(r.marked_missing, 1);
}

#[test]
fn scanning_never_changes_a_single_original_file() {
    // Plan §3.2 / §11 file-safety test: names, contents, sizes and modification times before and after.
    fn snapshot(root: &Path) -> BTreeMap<String, (u64, u64, Vec<u8>)> {
        let mut out = BTreeMap::new();
        let mut stack = vec![root.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).unwrap() {
                let p = entry.unwrap().path();
                let meta = fs::symlink_metadata(&p).unwrap();
                if meta.is_dir() {
                    stack.push(p);
                } else {
                    let rel = p.strip_prefix(root).unwrap().display().to_string();
                    let mtime = meta.modified().unwrap().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_millis() as u64;
                    let bytes = if meta.is_file() { fs::read(&p).unwrap() } else { Vec::new() };
                    out.insert(rel, (meta.len(), mtime, bytes));
                }
            }
        }
        out
    }
    let e = env();
    for i in 0..40 {
        put(&e.media, &format!("d{}/f{i}.jpg", i % 4), &format!("content number {i}"));
    }
    put(&e.media, "notes.txt", "keep me");
    put(&e.media, ".hidden/x.jpg", "x");
    let before = snapshot(&e.media);
    let (_, target) = e.folder(&e.media, &["d3"]);
    e.scan(&target);
    fs::rename(e.media.join("d0/f0.jpg"), e.media.join("d0/renamed.jpg")).unwrap();
    let mid = snapshot(&e.media); // after the user's own rename
    e.scan(&target);
    e.scan(&ScanTarget { dir: "d1".into(), ..target });
    assert_eq!(snapshot(&e.media), mid, "scans must leave every original untouched");
    assert_ne!(before, mid);
}

#[test]
fn progress_and_idempotent_concurrent_inserts() {
    let e = env();
    for i in 0..3000 {
        put(&e.media, &format!("d{}/f{i}.jpg", i % 10), &format!("n{i}"));
    }
    let (_, target) = e.folder(&e.media, &[]);
    let ticks = std::sync::atomic::AtomicU64::new(0);
    let r = scan(&e.db, &e.pool, &target, &AtomicBool::new(false), &|p| {
        ticks.fetch_max(p.files_seen, Ordering::Relaxed);
    })
    .unwrap();
    assert_eq!(r.new_files, 3000);
    assert_eq!(ticks.load(Ordering::Relaxed), 3000);
    // Two scans racing (a watcher event during a scan) never duplicate records.
    std::thread::scope(|s| {
        let a = s.spawn(|| e.scan(&target));
        let b = s.spawn(|| e.scan(&target));
        a.join().unwrap();
        b.join().unwrap();
    });
    assert_eq!(e.count("SELECT COUNT(*) FROM assets"), 3000);
    assert_eq!(e.count("SELECT COUNT(*) FROM jobs"), 3000);
    let c = e.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!(c.total(), 3000);
    let _ = assets::count;
}

/// Browse-pass throughput on real files. `cargo test -p sa-index --release --test scan -- --ignored --nocapture`
#[test]
#[ignore = "benchmark: creates 30,000 files"]
fn bench_browse_pass_30k_files() {
    use std::time::Instant;
    let e = env();
    let t = Instant::now();
    for i in 0..30_000 {
        let dir = e.media.join(format!("shoot{}/day{}", i % 60, i % 7));
        if i < 420 {
            fs::create_dir_all(&dir).unwrap();
        }
        // ~60 KB each: large enough to exercise the sampled hash path, small enough to create quickly.
        let body = format!("{i:08}").repeat(7_500);
        fs::write(dir.join(format!("IMG_{i:06}.jpg")), body).unwrap();
    }
    println!("created 30,000 files in {:?}", t.elapsed());
    let (_, target) = e.folder(&e.media, &[]);
    let t = Instant::now();
    let r = e.scan(&target);
    let first = t.elapsed();
    println!(
        "first scan : {} new in {first:?} = {:.0} files/s",
        r.new_files,
        r.new_files as f64 / first.as_secs_f64()
    );
    let t = Instant::now();
    let r = e.scan(&target);
    let again = t.elapsed();
    println!("rescan     : {} changed in {again:?} = {:.0} files/s (stat only)", r.changed, 30_000.0 / again.as_secs_f64());
    // Move one folder of 500 files and rescan.
    fs::rename(e.media.join("shoot0"), e.media.join("renamed-shoot0")).unwrap();
    let t = Instant::now();
    let r = e.scan(&target);
    println!("500-file folder rename: {} relinked, {} new, {} missing in {:?}", r.relinked, r.new_files, r.marked_missing, t.elapsed());
}

fn put_bytes(root: &Path, rel: &str, bytes: &[u8]) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, bytes).unwrap();
    set_mtime(&p, 1_600_000_000);
}

fn pattern(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect()
}

/// Records the full hash the duplicate job would have stored for a scanned file.
fn store_full_hash(e: &Env, rel: &str, bytes: &[u8]) {
    let id = e.id_of(rel);
    let (size, mtime) = e.db.read(|c| assets::file_fingerprint(c, id)).unwrap().unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    assert!(e.db.write(move |tx| sa_store::dedupe::set_content_hash(tx, id, size, mtime, &hash)).unwrap());
}

/// Same size and same first, middle and last 16 KiB, one byte different in between.
fn lookalike(original: &[u8]) -> Vec<u8> {
    let mut other = original.to_vec();
    other[50_000] ^= 0xFF;
    other
}

#[test]
fn a_moved_file_is_confirmed_by_its_full_hash_when_the_library_has_one() {
    let e = env();
    let (real, fake, unhashed) = (pattern(200_000, 1), pattern(200_000, 2), pattern(200_000, 3));
    put_bytes(&e.media, "old/real.jpg", &real);
    put_bytes(&e.media, "old/fake.jpg", &fake);
    put_bytes(&e.media, "old/unhashed.jpg", &unhashed);
    let (_, target) = e.folder(&e.media, &[]);
    e.scan(&target);
    store_full_hash(&e, "old/real.jpg", &real);
    store_full_hash(&e, "old/fake.jpg", &fake);
    let (real_id, fake_id, unhashed_id) = (e.id_of("old/real.jpg"), e.id_of("old/fake.jpg"), e.id_of("old/unhashed.jpg"));
    e.db.write(move |tx| organize::set_rating(tx, &[real_id, fake_id, unhashed_id], 5)).unwrap();

    // All three move at once: one genuinely, one replaced by a look-alike, one without a stored hash.
    fs::remove_dir_all(e.media.join("old")).unwrap();
    put_bytes(&e.media, "new/real-moved.jpg", &real);
    put_bytes(&e.media, "new/fake-moved.jpg", &lookalike(&fake));
    put_bytes(&e.media, "new/unhashed-moved.jpg", &lookalike(&unhashed));
    let r = e.scan(&target);

    assert_eq!((r.relinked, r.new_files, r.marked_missing), (2, 1, 1), "{r:?}");
    assert!(r.relink_rejected >= 1, "the look-alike was refused: {r:?}");
    assert!(r.relink_checked_bytes >= 400_000, "files with a stored hash are read in full: {r:?}");
    assert_eq!(e.id_of("new/real-moved.jpg"), real_id, "a genuine move keeps its record");
    assert_eq!(e.id_of("new/unhashed-moved.jpg"), unhashed_id, "without a stored hash the quick hash decides, as before");
    assert_ne!(e.id_of("new/fake-moved.jpg"), fake_id, "a look-alike is a new file");
    let rows = e.rows();
    let status = |rel: &str| rows.iter().find(|r| r.1 == rel).map(|r| r.2);
    assert_eq!(status("new/fake-moved.jpg"), Some(0));
    assert_eq!(rows.iter().filter(|r| r.2 == 1).map(|r| r.0).collect::<Vec<_>>(), vec![fake_id.0], "the replaced file's record is missing, not reused");
}

#[test]
fn a_look_alike_in_another_folder_does_not_take_over_a_missing_files_record() {
    let e = env();
    let (a_dir, b_dir) = (e.media.join("a"), e.media.join("b"));
    fs::create_dir_all(&b_dir).unwrap();
    let original = pattern(200_000, 7);
    put_bytes(&a_dir, "shot.jpg", &original);
    let (_, a) = e.folder(&a_dir, &[]);
    e.scan(&a);
    store_full_hash(&e, "shot.jpg", &original);
    let id = e.id_of("shot.jpg");

    fs::remove_file(a_dir.join("shot.jpg")).unwrap();
    e.scan(&a);
    assert_eq!(e.rows()[0].2, 1, "now missing");

    put_bytes(&b_dir, "different.jpg", &lookalike(&original));
    let (_, b) = e.folder(&b_dir, &[]);
    let r = e.scan(&b);
    assert_eq!(r.relinked, 0, "{r:?}");
    assert_eq!(r.relink_rejected, 1);
    assert_eq!(e.rows().len(), 2);

    // The genuine file arriving later still finds its record.
    put_bytes(&b_dir, "genuine.jpg", &original);
    let r = e.scan(&b);
    assert_eq!(r.relinked, 1, "{r:?}");
    assert_eq!(e.id_of("genuine.jpg"), id);
}
