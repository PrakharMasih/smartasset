#![allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    clippy::many_single_char_names,
    clippy::assert_is_empty,
    clippy::manual_assert,
    clippy::used_underscore_binding
)]

use rusqlite::params;
use sa_core::{AssetId, ColorLabel, ErrorClass, Flag, FolderId, MediaKind, VolumeId};
use sa_store::folders::{self, AddFolderOutcome};
use sa_store::model::{ProbeResult, ScannedFile};
use sa_store::{Db, assets, jobs, migrate, organize};
use std::path::Path;

const NOW: i64 = 1_700_000_000_000;

fn open(dir: &Path) -> Db {
    Db::open(&dir.join("library.sqlite")).unwrap().0
}

fn file(rel: &str, size: i64, seed: u8) -> ScannedFile {
    ScannedFile {
        rel_path: rel.to_string(),
        kind: MediaKind::from_extension(rel.rsplit('.').next().unwrap()).unwrap(),
        size,
        mtime: NOW - 1000,
        quick_hash: [seed; 16],
    }
}

struct Lib {
    _dir: tempfile::TempDir,
    db: Db,
    volume: VolumeId,
}

fn lib() -> Lib {
    let dir = tempfile::tempdir().unwrap();
    let db = open(dir.path());
    let volume = db
        .write(|tx| folders::upsert_volume(tx, "VOL-1", "Macintosh HD", "/", true, NOW))
        .unwrap();
    Lib { _dir: dir, db, volume }
}

fn add_folder(l: &Lib, rel: &str) -> FolderId {
    let v = l.volume;
    let rel = rel.to_string();
    let out = l
        .db
        .write(move |tx| folders::add_folder(tx, v, &rel, "f", None, NOW))
        .unwrap();
    match out {
        AddFolderOutcome::Added { id, .. } => id,
        other => panic!("expected Added, got {other:?}"),
    }
}

fn insert(l: &Lib, folder: FolderId, files: Vec<ScannedFile>) -> Vec<AssetId> {
    l.db.write(move |tx| assets::insert_assets(tx, folder, &files, 4, NOW)).unwrap()
}

fn count(l: &Lib, sql: &'static str) -> i64 {
    l.db.read(|c| Ok(c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap())).unwrap()
}

#[test]
fn creates_schema_and_reopens() {
    let dir = tempfile::tempdir().unwrap();
    let (db, report) = Db::open(&dir.path().join("library.sqlite")).unwrap();
    assert_eq!(report.schema_before, 0);
    assert_eq!(report.schema_after, migrate::LATEST_VERSION);
    assert!(!report.unclean_exit);
    db.close().unwrap();
    let (db, report) = Db::open(&dir.path().join("library.sqlite")).unwrap();
    assert_eq!(report.schema_before, migrate::LATEST_VERSION);
    assert!(!report.unclean_exit, "a clean close must not look like a crash");
    db.close().unwrap();
}

#[test]
fn unclean_exit_is_detected_and_checked() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.sqlite");
    {
        let (db, _) = Db::open(&path).unwrap();
        drop(db); // never closed: simulates a crash
    }
    let (db, report) = Db::open(&path).unwrap();
    assert!(report.unclean_exit);
    assert_eq!(report.quick_check, Some(Ok(())));
    db.close().unwrap();
}

#[test]
fn refuses_a_database_from_the_future() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.sqlite");
    {
        let (db, _) = Db::open(&path).unwrap();
        db.write_conn(|c| {
            c.execute_batch("PRAGMA user_version = 999").unwrap();
            Ok(())
        })
        .unwrap();
        db.close().unwrap();
    }
    let err = Db::open(&path).unwrap_err();
    assert!(matches!(err, sa_core::Error::SchemaTooNew { found: 999, .. }), "{err:?}");
}

#[test]
fn every_historic_version_upgrades_to_latest() {
    for &(version, _) in migrate::all_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("library.sqlite");
        {
            // Build a database exactly as an app at `version` would have left it.
            let mut conn = rusqlite::Connection::open(&path).unwrap();
            for &(v, sql) in migrate::all_migrations().iter().filter(|(v, _)| *v <= version) {
                conn.execute_batch(sql).unwrap();
                conn.execute_batch(&format!("PRAGMA user_version = {v}")).unwrap();
            }
            conn.execute(
                "INSERT INTO volumes(uuid, name, mount_path, last_seen_at) VALUES ('U','N','/',1)",
                [],
            )
            .unwrap();
            let _ = &mut conn;
        }
        let (db, report) = Db::open(&path).unwrap();
        assert_eq!(report.schema_before, version);
        assert_eq!(report.schema_after, migrate::LATEST_VERSION);
        let vols = db.read(folders::list_volumes).unwrap();
        assert_eq!(vols.len(), 1, "data written at v{version} survives the upgrade");
        db.close().unwrap();
    }
}

#[test]
fn adding_folders_handles_duplicates_nesting_and_absorption() {
    let l = lib();
    let shoots = add_folder(&l, "Users/me/Shoots");
    let v = l.volume;

    // Same folder again.
    let again = l
        .db
        .write(move |tx| folders::add_folder(tx, v, "Users/me/Shoots", "x", None, NOW))
        .unwrap();
    assert_eq!(again, AddFolderOutcome::AlreadyAdded(shoots));

    // A folder inside one already added.
    let inside = l
        .db
        .write(move |tx| folders::add_folder(tx, v, "Users/me/Shoots/Day1", "x", None, NOW))
        .unwrap();
    assert!(matches!(inside, AddFolderOutcome::InsideExisting { folder, excluded: false, .. } if folder == shoots));

    // Sibling with a shared name prefix is NOT inside.
    let sibling = l
        .db
        .write(move |tx| folders::add_folder(tx, v, "Users/me/Shoots2", "x", None, NOW))
        .unwrap();
    assert!(matches!(sibling, AddFolderOutcome::Added { .. }));

    // Excluded subfolders report that they are excluded.
    l.db.write(move |tx| folders::set_excludes(tx, shoots, &["Day2".to_string()])).unwrap();
    let excluded = l
        .db
        .write(move |tx| folders::add_folder(tx, v, "Users/me/Shoots/Day2/Cam", "x", None, NOW))
        .unwrap();
    assert!(matches!(excluded, AddFolderOutcome::InsideExisting { excluded: true, .. }));
}

#[test]
fn adding_a_parent_absorbs_children_and_keeps_user_data() {
    let l = lib();
    let child = add_folder(&l, "Users/me/Shoots/Day1");
    let ids = insert(&l, child, vec![file("a.mov", 10, 1), file("sub/b.jpg", 20, 2)]);
    l.db.write({
        let ids = ids.clone();
        move |tx| {
            organize::set_rating(tx, &ids[..1], 4)?;
            organize::add_tags(tx, &ids[..1], &["hero".to_string()])?;
            let c = organize::create_collection(tx, "Best", NOW)?;
            organize::add_to_collection(tx, c, &ids[..1], NOW)?;
            folders::set_excludes(tx, child, &["cache".to_string()])?;
            Ok(())
        }
    })
    .unwrap();

    let v = l.volume;
    let out = l
        .db
        .write(move |tx| folders::add_folder(tx, v, "Users/me/Shoots", "Shoots", None, NOW))
        .unwrap();
    let AddFolderOutcome::Added { id: parent, absorbed } = out else { panic!("{out:?}") };
    assert_eq!(absorbed, vec![child]);

    // Same asset ids, new relative paths, data intact.
    let paths: Vec<(i64, String, i64, i64)> = l
        .db
        .read(|c| {
            let mut s = c.prepare("SELECT id, rel_path, folder_id, rating FROM assets ORDER BY id").unwrap();
            let rows = s
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            Ok(rows)
        })
        .unwrap();
    assert_eq!(paths[0], (ids[0].0, "Day1/a.mov".to_string(), parent.0, 4));
    assert_eq!(paths[1].1, "Day1/sub/b.jpg");
    assert_eq!(count(&l, "SELECT COUNT(*) FROM folders"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM collection_items"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_tags"), 1);
    // The keyword index followed the move.
    assert_eq!(
        count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'path:day1'"),
        2
    );
    let ex = l.db.read(|c| folders::excludes(c, parent)).unwrap();
    assert_eq!(ex, vec!["Day1/cache".to_string()]);
}

#[test]
fn insert_is_idempotent() {
    let l = lib();
    let f = add_folder(&l, "m");
    let files = vec![file("a.jpg", 1, 1), file("b.jpg", 2, 2)];
    let first = insert(&l, f, files.clone());
    let second = insert(&l, f, files);
    assert_eq!(first.len(), 2);
    assert!(second.is_empty(), "re-inserting the same paths must not create records");
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 2);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM jobs"), 2);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts"), 2);
}

#[test]
fn moved_file_is_relinked_with_its_data() {
    let l = lib();
    let f = add_folder(&l, "m");
    let id = insert(&l, f, vec![file("old/IMG_1.jpg", 500, 9)])[0];
    l.db.write(move |tx| {
        organize::set_rating(tx, &[id], 5)?;
        organize::set_flag(tx, &[id], Flag::Pick)?;
        organize::set_color_label(tx, &[id], ColorLabel::Green)?;
        organize::add_tags(tx, &[id], &["keeper".to_string()])?;
        organize::set_notes(tx, id, "sunset over the bay")?;
        assets::mark_missing(tx, &[id], NOW)
    })
    .unwrap();

    let cands = l.db.read(|c| assets::relink_candidates(c, 500, [9; 16])).unwrap();
    assert_eq!(cands.len(), 1);
    assert_eq!(cands[0].id, id);
    let none = l.db.read(|c| assets::relink_candidates(c, 501, [9; 16])).unwrap();
    assert!(none.is_empty());

    l.db.write(move |tx| assets::relink(tx, id, f, "new/Renamed.jpg", NOW)).unwrap();
    let d = l.db.read(|c| assets::detail(c, id)).unwrap();
    assert_eq!(d.summary.name, "Renamed.jpg");
    assert_eq!(d.rel_path, "new/Renamed.jpg");
    assert_eq!(d.summary.rating, 5);
    assert_eq!(d.summary.flag, Flag::Pick);
    assert_eq!(d.summary.color_label, ColorLabel::Green);
    assert_eq!(d.tags, vec!["keeper".to_string()]);
    assert_eq!(d.notes, "sunset over the bay");
    assert_eq!(d.summary.status, sa_store::model::AssetStatus::Present);
    // Search by the new name, the old one is gone, and the tag/notes still match.
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'renamed'"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'img_1'"), 0);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'keeper'"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'bay'"), 1);
}

#[test]
fn missing_assets_do_not_leave_jobs_to_run() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, vec![file("a.mov", 1, 1)]);
    l.db.write(move |tx| assets::mark_missing(tx, &ids, NOW)).unwrap();
    assert_eq!(count(&l, "SELECT COUNT(*) FROM jobs WHERE state = 0"), 0);
    let leased = l.db.write(|tx| jobs::lease(tx, "media", 10, "t", 60_000, NOW)).unwrap();
    assert!(leased.is_empty());
}

#[test]
fn removing_a_folder_removes_only_index_data() {
    let l = lib();
    let a = add_folder(&l, "a");
    let b = add_folder(&l, "b");
    let ia = insert(&l, a, vec![file("1.jpg", 1, 1), file("2.jpg", 2, 2)]);
    insert(&l, b, vec![file("3.jpg", 3, 3)]);
    l.db.write(move |tx| {
        let p = ProbeResult { width: Some(100), height: Some(50), ..ProbeResult::default() };
        assets::apply_probe(tx, ia[0], &p, Some(1))?;
        let c = organize::create_collection(tx, "c", NOW)?;
        organize::add_to_collection(tx, c, &ia, NOW)?;
        Ok(())
    })
    .unwrap();

    let removed = l.db.write(move |tx| folders::remove_folder(tx, a)).unwrap();
    assert_eq!(removed.asset_count, 2);
    assert_eq!(removed.thumbs.len(), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM jobs"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM collection_items"), 0);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM collections"), 1, "the collection itself stays");
    let err = l.db.write(move |tx| folders::remove_folder(tx, a)).unwrap_err();
    assert!(matches!(err, sa_core::Error::NotFound(_)));
}

#[test]
fn excluding_a_subfolder_drops_its_assets_and_nothing_else() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, vec![file("keep/a.jpg", 1, 1), file("cache/b.jpg", 2, 2), file("cache2/c.jpg", 3, 3), file("cache.jpg", 4, 4)]);
    let removed = l.db.write(move |tx| folders::set_excludes(tx, f, &["cache".into()])).unwrap();
    assert_eq!(removed.asset_count, 1);
    let left: Vec<String> = l
        .db
        .read(|c| {
            let mut s = c.prepare("SELECT rel_path FROM assets ORDER BY rel_path").unwrap();
            Ok(s.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect())
        })
        .unwrap();
    assert_eq!(left, vec!["cache.jpg", "cache2/c.jpg", "keep/a.jpg"]);
    assert!(l.db.write(move |tx| folders::set_excludes(tx, f, &["../x".into()])).is_err());
    assert!(l.db.write(move |tx| folders::set_excludes(tx, f, &[String::new()])).is_err());
}

#[test]
fn job_leasing_respects_lanes_drives_and_folder_switches() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, (0..5).map(|i| file(&format!("{i}.jpg"), i + 1, u8::try_from(i).unwrap())).collect());
    // Promote the last asset to the visible lane: it must be leased first.
    l.db.write({
        let last = ids[4];
        move |tx| jobs::promote(tx, "media", &[last], jobs::lane::VISIBLE, NOW)
    })
    .unwrap();
    let first = l.db.write(|tx| jobs::lease(tx, "media", 2, "tok", 60_000, NOW)).unwrap();
    assert_eq!(first.len(), 2);
    assert_eq!(first[0].asset_id, ids[4]);
    assert_eq!(first[0].attempt, 1);
    assert_eq!(first[0].thumb_rev, 0);
    assert_eq!(first[0].mount_path, "/");
    assert_eq!(first[0].rel_path, "4.jpg");

    // Unplug the drive: nothing more can be leased, but the queue is kept.
    l.db.write(|tx| folders::set_volume_online(tx, "VOL-1", None, NOW)).unwrap();
    assert!(l.db.write(|tx| jobs::lease(tx, "media", 10, "tok2", 60_000, NOW)).unwrap().is_empty());
    assert_eq!(count(&l, "SELECT COUNT(*) FROM jobs WHERE state = 0"), 3);
    l.db.write(|tx| folders::set_volume_online(tx, "VOL-1", Some("/"), NOW)).unwrap();

    // Disabling the folder also stops leasing (L5).
    l.db.write(move |tx| folders::set_folder_enabled(tx, f, false)).unwrap();
    assert!(l.db.write(|tx| jobs::lease(tx, "media", 10, "tok3", 60_000, NOW)).unwrap().is_empty());
    l.db.write(move |tx| folders::set_folder_enabled(tx, f, true)).unwrap();
    assert_eq!(l.db.write(|tx| jobs::lease(tx, "media", 10, "tok4", 60_000, NOW)).unwrap().len(), 3);
}

#[test]
fn job_completion_requires_the_lease_and_is_idempotent() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, vec![file("a.jpg", 1, 1)]);
    let job = l.db.write(|tx| jobs::lease(tx, "media", 1, "A", 1_000, NOW)).unwrap().remove(0);

    // Someone else's token cannot complete it.
    assert!(!l.db.write(move |tx| jobs::complete(tx, job.job_id, "B", NOW)).unwrap());
    // The lease expires; another worker takes it.
    assert_eq!(l.db.write(|tx| jobs::expire_leases(tx, NOW + 2_000)).unwrap(), 1);
    let again = l.db.write(|tx| jobs::lease(tx, "media", 1, "C", 1_000, NOW + 2_000)).unwrap();
    assert_eq!(again.len(), 1);
    assert_eq!(again[0].attempt, 2);
    // The first worker's late result is rejected, the second one's accepted exactly once.
    assert!(!l.db.write(move |tx| jobs::complete(tx, job.job_id, "A", NOW)).unwrap());
    assert!(l.db.write(move |tx| jobs::complete(tx, job.job_id, "C", NOW)).unwrap());
    assert!(!l.db.write(move |tx| jobs::complete(tx, job.job_id, "C", NOW)).unwrap());
    let c = l.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!((c.done, c.queued, c.leased), (1, 0, 0));

    // Enqueueing a finished job is a no-op unless forced (the file changed).
    let id = job.asset_id;
    l.db.write(move |tx| jobs::enqueue(tx, "media", id, "", 4, false, NOW)).unwrap();
    assert_eq!(l.db.read(|c| jobs::counts(c, "media")).unwrap().queued, 0);
    l.db.write(move |tx| jobs::enqueue(tx, "media", id, "", 4, true, NOW)).unwrap();
    assert_eq!(l.db.read(|c| jobs::counts(c, "media")).unwrap().queued, 1);
}

#[test]
fn failures_retry_with_backoff_then_give_up() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, vec![file("a.jpg", 1, 1), file("b.jpg", 2, 2)]);
    let jobs_ = l.db.write(|tx| jobs::lease(tx, "media", 2, "T", 60_000, NOW)).unwrap();

    // A corrupt file fails alone, immediately, and is not retried.
    let corrupt = jobs_[0].job_id;
    l.db.write(move |tx| jobs::fail(tx, corrupt, "T", ErrorClass::FileCorrupt, "bad header", NOW + 5_000, NOW)).unwrap();
    // A transient error goes back to the queue, but not before its backoff.
    let transient = jobs_[1].job_id;
    l.db.write(move |tx| jobs::fail(tx, transient, "T", ErrorClass::Transient, "busy", NOW + 5_000, NOW)).unwrap();

    let c = l.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!((c.failed, c.queued), (1, 1));
    assert!(l.db.write(|tx| jobs::lease(tx, "media", 5, "U", 60_000, NOW + 1_000)).unwrap().is_empty());
    assert_eq!(l.db.read(|c| jobs::next_retry_at(c, "media", NOW)).unwrap(), Some(NOW + 5_000));
    let again = l.db.write(|tx| jobs::lease(tx, "media", 5, "U", 60_000, NOW + 5_000)).unwrap();
    assert_eq!(again.len(), 1);

    // Attempts so far: 2 (this lease). Failing it requeues; the third attempt is the last one allowed.
    assert_eq!(again[0].attempt, 2);
    let second = again[0].job_id;
    l.db.write(move |tx| jobs::fail(tx, second, "U", ErrorClass::Transient, "busy", NOW + 6_000, NOW + 5_000)).unwrap();
    let third = l.db.write(|tx| jobs::lease(tx, "media", 5, "W", 60_000, NOW + 6_000)).unwrap();
    assert_eq!(third.len(), 1);
    assert_eq!(third[0].attempt, 3);
    let last = third[0].job_id;
    l.db.write(move |tx| jobs::fail(tx, last, "W", ErrorClass::Transient, "busy", NOW + 7_000, NOW + 6_000)).unwrap();
    let c = l.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!((c.failed, c.queued, c.leased), (2, 0, 0), "out of attempts: the job fails for good, alone");
    assert!(l.db.write(|tx| jobs::lease(tx, "media", 5, "X", 60_000, NOW + 10_000_000)).unwrap().is_empty());
}

#[test]
fn a_restart_returns_orphaned_leases_to_the_queue() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, vec![file("a.jpg", 1, 1), file("b.jpg", 2, 2)]);
    l.db.write(|tx| jobs::lease(tx, "media", 2, "T", 600_000, NOW)).unwrap();
    assert_eq!(l.db.read(|c| jobs::counts(c, "media")).unwrap().leased, 2);
    assert_eq!(l.db.write(|tx| jobs::reset_all_leases(tx, NOW)).unwrap(), 2);
    let c = l.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!((c.queued, c.leased), (2, 0));
}

#[test]
fn cancel_stops_pending_work_for_a_folder_only() {
    let l = lib();
    let a = add_folder(&l, "a");
    let b = add_folder(&l, "b");
    insert(&l, a, vec![file("1.jpg", 1, 1)]);
    insert(&l, b, vec![file("2.jpg", 2, 2)]);
    assert_eq!(l.db.write(move |tx| jobs::cancel(tx, "media", Some(a), NOW)).unwrap(), 1);
    let c = l.db.read(|c| jobs::counts(c, "media")).unwrap();
    assert_eq!((c.cancelled, c.queued), (1, 1));
    // A cancelled asset can be found again to resume later.
    let orphans = l.db.read(|c| assets::unprobed_without_job(c, 10)).unwrap();
    assert_eq!(orphans.len(), 1);
}

#[test]
fn tags_ratings_and_notes_drive_the_keyword_index() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, vec![file("a.jpg", 1, 1), file("b.jpg", 2, 2)]);
    let i2 = ids.clone();
    l.db.write(move |tx| organize::add_tags(tx, &i2, &["  Sunset  ".into(), "beach".into()])).unwrap();
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'tags:sunset'"), 2);
    // Case-insensitive uniqueness.
    let i2 = ids.clone();
    l.db.write(move |tx| organize::add_tags(tx, &i2, &["SUNSET".into()])).unwrap();
    assert_eq!(l.db.read(organize::list_tags).unwrap().len(), 2);

    let first = ids[0];
    l.db.write(move |tx| organize::remove_tags(tx, &[first], &["beach".into()])).unwrap();
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'beach'"), 1);

    // Renaming onto an existing tag merges.
    l.db.write(|tx| organize::rename_tag(tx, "beach", "sunset")).unwrap();
    let tags = l.db.read(organize::list_tags).unwrap();
    assert_eq!(tags.len(), 1);
    assert_eq!(tags[0].asset_count, 2);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'tags:sunset'"), 2);

    l.db.write(|tx| organize::delete_tag(tx, "sunset")).unwrap();
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts WHERE asset_fts MATCH 'sunset'"), 0);

    assert!(l.db.write(|tx| organize::add_tags(tx, &[], &["   ".into()])).is_err());
    assert!(l.db.write(move |tx| organize::set_rating(tx, &[first], 6)).is_err());
}

#[test]
fn collections_keep_order_and_ignore_duplicates() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, (0..4).map(|i| file(&format!("{i}.jpg"), i + 1, u8::try_from(i).unwrap())).collect());
    let c = l.db.write(|tx| organize::create_collection(tx, "  Picks ", NOW)).unwrap();
    let i2 = ids.clone();
    assert_eq!(l.db.write(move |tx| organize::add_to_collection(tx, c, &[i2[2], i2[0]], NOW)).unwrap(), 2);
    let i2 = ids.clone();
    assert_eq!(l.db.write(move |tx| organize::add_to_collection(tx, c, &[i2[0], i2[3]], NOW)).unwrap(), 1);
    let order: Vec<i64> = l
        .db
        .read(|conn| {
            let mut s = conn.prepare("SELECT asset_id FROM collection_items ORDER BY position").unwrap();
            Ok(s.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect())
        })
        .unwrap();
    assert_eq!(order, vec![ids[2].0, ids[0].0, ids[3].0]);
    let list = l.db.read(organize::list_collections).unwrap();
    assert_eq!((list[0].name.as_str(), list[0].asset_count), ("Picks", 3));
    assert!(l.db.write(|tx| organize::add_to_collection(tx, 999, &[], NOW)).is_err());
    // Deleting a collection never deletes assets.
    l.db.write(move |tx| organize::delete_collection(tx, c)).unwrap();
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 4);
}

#[test]
fn smart_collections_roundtrip_and_survive_bad_definitions() {
    let l = lib();
    let q = sa_core::SearchQuery {
        text: Some("beach".into()),
        filters: sa_core::Filters { min_rating: Some(3), ..sa_core::Filters::default() },
        ..sa_core::SearchQuery::default()
    };
    let q2 = q.clone();
    let id = l.db.write(move |tx| organize::create_smart_collection(tx, "Good beaches", &q2, NOW)).unwrap();
    let listed = l.db.read(organize::list_smart_collections).unwrap();
    assert_eq!(listed[0].query, q);
    l.db.write_conn(move |c| {
        c.execute("UPDATE smart_collections SET definition = '{broken' WHERE id = ?1", [id]).unwrap();
        Ok(())
    })
    .unwrap();
    let listed = l.db.read(organize::list_smart_collections).unwrap();
    assert_eq!(listed.len(), 1, "an unreadable definition must not hide the collection");
    assert_eq!(listed[0].query, sa_core::SearchQuery::default());
}

#[test]
fn summaries_keep_order_skip_unknown_and_report_offline_drives() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, (0..3).map(|i| file(&format!("{i}.jpg"), i + 1, u8::try_from(i).unwrap())).collect());
    let want = vec![ids[2].0, 9_999, ids[0].0, ids[1].0];
    let got = l.db.read(|c| assets::summaries(c, &want)).unwrap();
    assert_eq!(got.iter().map(|s| s.id.0).collect::<Vec<_>>(), vec![ids[2].0, ids[0].0, ids[1].0]);
    assert!(got.iter().all(|s| s.volume_online && s.volume_name == "Macintosh HD"));
    assert!(l.db.read(|c| assets::summaries(c, &[])).unwrap().is_empty());

    l.db.write(|tx| folders::set_volume_online(tx, "VOL-1", None, NOW)).unwrap();
    let got = l.db.read(|c| assets::summaries(c, &[ids[0].0])).unwrap();
    assert!(!got[0].volume_online, "L4: the app can name the drive to plug in");
    let paths = l.db.read(|c| assets::resolve_paths(c, &[ids[0].0])).unwrap();
    assert_eq!(paths[0].1, None);
    l.db.write(|tx| folders::set_volume_online(tx, "VOL-1", Some("/Volumes/Cards"), NOW)).unwrap();
    let paths = l.db.read(|c| assets::resolve_paths(c, &[ids[0].0])).unwrap();
    assert_eq!(paths[0].1.as_deref(), Some(Path::new("/Volumes/Cards/m/0.jpg")));
}

#[test]
fn probe_results_classify_shape_and_set_the_sort_date() {
    let l = lib();
    let f = add_folder(&l, "m");
    let id = insert(&l, f, vec![file("v.mov", 1, 1)])[0];
    let probe = ProbeResult {
        width: Some(1080),
        height: Some(1920),
        duration_ms: Some(12_500),
        codec: Some("hvc1".into()),
        fps: Some(29.97),
        capture_at: Some(NOW - 86_400_000),
        ..ProbeResult::default()
    };
    assert!(l.db.write(move |tx| assets::apply_probe(tx, id, &probe, Some(1))).unwrap());
    let d = l.db.read(|c| assets::detail(c, id)).unwrap();
    assert_eq!(d.summary.aspect_class, Some(sa_core::AspectClass::Vertical9x16));
    assert_eq!(d.summary.sort_date, NOW - 86_400_000, "capture date wins over modification date");
    assert_eq!(d.summary.thumb_rev, 1);
    assert_eq!(d.summary.probe_state, sa_store::model::ProbeState::Ok);
    // A stale lower revision never moves the thumbnail back.
    l.db.write(move |tx| assets::apply_probe(tx, id, &ProbeResult::default(), Some(0))).unwrap();
    assert_eq!(l.db.read(|c| assets::detail(c, id)).unwrap().summary.thumb_rev, 1);
    // Unknown asset: reported, not an error.
    assert!(!l.db.write(|tx| assets::apply_probe(tx, AssetId(424_242), &ProbeResult::default(), None)).unwrap());
}

#[test]
fn a_panicking_write_rolls_back_and_the_writer_survives() {
    let l = lib();
    let v = l.volume;
    let err = l
        .db
        .write(move |tx| {
            folders::add_folder(tx, v, "boom", "boom", None, NOW)?;
            if v.0 > 0 {
                panic!("simulated bug inside a write");
            }
            Ok(())
        })
        .unwrap_err();
    assert!(matches!(err, sa_core::Error::Db(_)));
    assert_eq!(count(&l, "SELECT COUNT(*) FROM folders"), 0, "a panic must roll the transaction back");
    add_folder(&l, "after"); // the writer thread is still alive
}

#[test]
fn concurrent_readers_and_a_writer_do_not_block_or_corrupt() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, (0..200).map(|i| file(&format!("{i}.jpg"), i + 1, u8::try_from(i % 250).unwrap())).collect());
    let db = l.db.clone();
    std::thread::scope(|s| {
        let writer = s.spawn(|| {
            for round in 0..50i64 {
                let batch: Vec<ScannedFile> =
                    (0..20).map(|i| file(&format!("w{round}_{i}.jpg"), 1000 + round * 20 + i, 7)).collect();
                db.write(move |tx| assets::insert_assets(tx, f, &batch, 4, NOW)).unwrap();
            }
        });
        let readers: Vec<_> = (0..8)
            .map(|_| {
                s.spawn(|| {
                    for _ in 0..200 {
                        let n = db
                            .read(|c| Ok(c.query_row("SELECT COUNT(*) FROM assets", [], |r| r.get::<_, i64>(0)).unwrap()))
                            .unwrap();
                        assert!((200..=1200).contains(&n));
                    }
                })
            })
            .collect();
        writer.join().unwrap();
        for r in readers {
            r.join().unwrap();
        }
    });
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 1200);
    assert_eq!(l.db.integrity_check().unwrap(), Ok(()));
}

#[test]
fn snapshot_produces_a_readable_copy() {
    let l = lib();
    let f = add_folder(&l, "m");
    insert(&l, f, vec![file("a.jpg", 1, 1)]);
    let dest = l._dir.path().join("snap.sqlite");
    l.db.snapshot_to(&dest).unwrap();
    let conn = rusqlite::Connection::open(&dest).unwrap();
    let n: i64 = conn.query_row("SELECT COUNT(*) FROM assets", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 1);
    let v: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
    assert_eq!(v, migrate::LATEST_VERSION);
    let _ = params![1];
}

#[test]
fn only_missing_files_can_be_removed_from_the_library() {
    let l = lib();
    let f = add_folder(&l, "m");
    let ids = insert(&l, f, vec![file("here.jpg", 1, 1), file("gone1.jpg", 2, 2), file("gone2.jpg", 3, 3)]);
    l.db.write({
        let ids = ids.clone();
        move |tx| {
            organize::set_rating(tx, &[ids[1]], 5)?;
            assets::apply_probe(tx, ids[1], &ProbeResult::default(), Some(1))?;
            assets::mark_missing(tx, &ids[1..], NOW)
        }
    })
    .unwrap();

    // Asking to remove a present file removes nothing, however it is asked.
    let (n, _) = l.db.write({ let ids = ids.clone(); move |tx| assets::delete_missing(tx, Some(&ids[..1])) }).unwrap();
    assert_eq!(n, 0);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 3);
    // A mixed request removes only the missing one, with its thumbnail reported for cleanup.
    let (n, thumbs) = l.db.write({ let ids = ids.clone(); move |tx| assets::delete_missing(tx, Some(&ids[..2])) }).unwrap();
    assert_eq!((n, thumbs.len()), (1, 1));
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets WHERE name = 'here.jpg'"), 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM asset_fts"), 2);
    // None removes every remaining missing file and still spares the present one.
    let (n, _) = l.db.write(|tx| assets::delete_missing(tx, None)).unwrap();
    assert_eq!(n, 1);
    assert_eq!(count(&l, "SELECT COUNT(*) FROM assets"), 1);
}
