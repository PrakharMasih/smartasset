#![allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    clippy::many_single_char_names,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::assert_is_empty,
    clippy::type_complexity
)]

use sa_core::{
    AssetId, ColorLabel, DateRange, Filters, Flag, MediaKind, MissingFilter, Orientation, ResolutionClass,
    SearchQuery, Sort, SortKey,
};
use sa_search::{run, stats};
use sa_store::model::{ProbeResult, ScannedFile};
use sa_store::{Db, assets, folders, organize};

const NOW: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

struct Lib {
    _dir: tempfile::TempDir,
    db: Db,
    folder: sa_core::FolderId,
    ids: Vec<AssetId>,
}

/// Ten assets with distinct names, kinds, shapes, dates, ratings and tags.
fn lib() -> Lib {
    let dir = tempfile::tempdir().unwrap();
    let (db, _) = Db::open(&dir.path().join("library.sqlite")).unwrap();
    let (folder, _vol) = db
        .write(|tx| {
            let v = folders::upsert_volume(tx, "V", "Disk", "/", true, NOW)?;
            let out = folders::add_folder(tx, v, "m", "m", None, NOW)?;
            let folders::AddFolderOutcome::Added { id, .. } = out else { panic!() };
            Ok((id, v))
        })
        .unwrap();
    let specs: [(&str, i64, u32, u32, Option<i64>, i64); 10] = [
        ("beach_sunset.jpg", 4_000, 6000, 4000, None, 0),
        ("beach_drone.mov", 900_000, 3840, 2160, Some(90_000), 1),
        ("city_night.mov", 800_000, 1080, 1920, Some(15_000), 2),
        ("interview_cafe.wav", 50_000, 0, 0, Some(600_000), 3),
        ("Café Menu.png", 2_000, 1080, 1080, None, 4),
        ("IMG_4471.heic", 3_500, 4032, 3024, None, 5),
        ("podcast_ep12.mp3", 70_000, 0, 0, Some(3_600_000), 6),
        ("reel_vertical.mp4", 600_000, 1080, 1920, Some(30_000), 7),
        ("forest.jpg", 5_000, 6000, 4000, None, 8),
        ("zebra.jpg", 1_000, 800, 600, None, 9),
    ];
    let files: Vec<ScannedFile> = specs
        .iter()
        .map(|(n, size, _, _, _, i)| ScannedFile {
            rel_path: (*n).to_string(),
            kind: MediaKind::from_extension(n.rsplit('.').next().unwrap()).unwrap(),
            size: *size,
            mtime: NOW - i * DAY,
            quick_hash: [u8::try_from(*i).unwrap(); 16],
        })
        .collect();
    let ids = db.write(move |tx| assets::insert_assets(tx, folder, &files, 4, NOW)).unwrap();
    let probes: Vec<(AssetId, ProbeResult)> = specs
        .iter()
        .zip(&ids)
        .map(|((_, _, w, h, dur, _), id)| {
            (
                *id,
                ProbeResult {
                    width: (*w > 0).then_some(*w),
                    height: (*h > 0).then_some(*h),
                    duration_ms: *dur,
                    ..ProbeResult::default()
                },
            )
        })
        .collect();
    db.write(move |tx| {
        for (id, p) in &probes {
            assets::apply_probe(tx, *id, p, None)?;
        }
        Ok(())
    })
    .unwrap();
    Lib { _dir: dir, db, folder, ids }
}

fn names(l: &Lib, q: &SearchQuery) -> Vec<String> {
    let ids = l.db.read(|c| run(c, q)).unwrap();
    let sums = l.db.read(|c| assets::summaries(c, &ids)).unwrap();
    sums.into_iter().map(|s| s.name).collect()
}

fn text(t: &str) -> SearchQuery {
    SearchQuery { text: Some(t.into()), ..SearchQuery::default() }
}

fn filtered(f: Filters) -> SearchQuery {
    SearchQuery { filters: f, ..SearchQuery::default() }
}

#[test]
fn default_query_lists_everything_newest_first() {
    let l = lib();
    let n = names(&l, &SearchQuery::default());
    assert_eq!(n.len(), 10);
    assert_eq!(n[0], "beach_sunset.jpg");
    assert_eq!(n[9], "zebra.jpg");
}

#[test]
fn keyword_search_matches_prefixes_underscores_and_diacritics() {
    let l = lib();
    assert_eq!(names(&l, &text("beach")).len(), 2);
    assert_eq!(names(&l, &text("beac")).len(), 2, "type-ahead prefix");
    assert_eq!(names(&l, &text("beach drone")), vec!["beach_drone.mov"]);
    assert_eq!(names(&l, &text("IMG_4471")), vec!["IMG_4471.heic"]);
    assert_eq!(names(&l, &text("4471")), vec!["IMG_4471.heic"]);
    assert_eq!(names(&l, &text("cafe")).len(), 2, "café matches cafe in both directions");
    assert_eq!(names(&l, &text("CAFÉ")).len(), 2);
    assert_eq!(names(&l, &text("jpg")).len(), 3, "extension is searchable");
    assert!(names(&l, &text("nonexistentword")).is_empty());
}

#[test]
fn hostile_text_never_errors() {
    let l = lib();
    for t in ["\"", "(", ")", "*", "a AND", "NOT", "NEAR(a b)", "name:secret", "a OR b", "^x", "--", "'", "%", "\\", "\u{0}", "   ", "???"] {
        let q = text(t);
        let r = l.db.read(|c| run(c, &q));
        assert!(r.is_ok(), "{t:?} -> {r:?}");
    }
    assert!(names(&l, &text("???")).is_empty(), "text with no words matches nothing");
    assert_eq!(names(&l, &text("   ")).len(), 10, "blank text is no filter");
}

#[test]
fn relevance_prefers_name_matches_over_notes() {
    let l = lib();
    let forest = l.ids[8];
    let zebra = l.ids[9];
    l.db.write(move |tx| organize::set_notes(tx, zebra, "not a forest at all, just forest forest")).unwrap();
    let q = SearchQuery {
        text: Some("forest".into()),
        sort: Sort { key: SortKey::Relevance, descending: false },
        ..SearchQuery::default()
    };
    let ids = l.db.read(|c| run(c, &q)).unwrap();
    assert_eq!(ids[0], forest.0, "a name hit outranks notes hits");
    assert_eq!(ids.len(), 2);
}

#[test]
fn kind_and_shape_filters() {
    let l = lib();
    let kinds = |k: Vec<MediaKind>| names(&l, &filtered(Filters { kinds: k, ..Filters::default() }));
    assert_eq!(kinds(vec![MediaKind::Video]).len(), 3);
    assert_eq!(kinds(vec![MediaKind::Audio]).len(), 2);
    assert_eq!(kinds(vec![MediaKind::Image, MediaKind::Audio]).len(), 7);

    let vertical = names(&l, &filtered(Filters { orientations: vec![Orientation::Vertical], ..Filters::default() }));
    assert_eq!(vertical.len(), 2);
    assert!(vertical.contains(&"city_night.mov".to_string()) && vertical.contains(&"reel_vertical.mp4".to_string()));
    let square = names(&l, &filtered(Filters { orientations: vec![Orientation::Square], ..Filters::default() }));
    assert_eq!(square, vec!["Café Menu.png"]);

    let uhd = names(&l, &filtered(Filters { min_resolution: Some(ResolutionClass::Uhd4k), ..Filters::default() }));
    assert_eq!(uhd.len(), 4, "6000px photos and the 3840 drone clip; audio has no resolution");
    let long = names(&l, &filtered(Filters { min_duration_ms: Some(60_000), ..Filters::default() }));
    assert_eq!(long.len(), 3);
    let short = names(&l, &filtered(Filters { max_duration_ms: Some(30_000), ..Filters::default() }));
    assert_eq!(short.len(), 2);
}

#[test]
fn date_range_filter_is_inclusive() {
    let l = lib();
    let q = filtered(Filters {
        date: Some(DateRange { from: Some(NOW - 2 * DAY), to: Some(NOW) }),
        ..Filters::default()
    });
    assert_eq!(names(&l, &q).len(), 3);
    let none = filtered(Filters {
        date: Some(DateRange { from: Some(NOW + DAY), to: None }),
        ..Filters::default()
    });
    assert!(names(&l, &none).is_empty());
}

#[test]
fn rating_flag_label_and_tag_filters() {
    let l = lib();
    let ids = l.ids.clone();
    l.db.write(move |tx| {
        organize::set_rating(tx, &ids[0..3], 5)?;
        organize::set_rating(tx, &ids[3..4], 2)?;
        organize::set_flag(tx, &ids[0..1], Flag::Pick)?;
        organize::set_flag(tx, &ids[1..2], Flag::Reject)?;
        organize::set_color_label(tx, &ids[2..4], ColorLabel::Red)?;
        organize::add_tags(tx, &ids[0..2], &["travel".into(), "b-roll".into()])?;
        organize::add_tags(tx, &ids[2..3], &["Travel".into()])?;
        Ok(())
    })
    .unwrap();
    let f = |f: Filters| names(&l, &filtered(f)).len();
    assert_eq!(f(Filters { min_rating: Some(3), ..Filters::default() }), 3);
    assert_eq!(f(Filters { min_rating: Some(1), ..Filters::default() }), 4);
    assert_eq!(f(Filters { unrated_only: true, ..Filters::default() }), 6);
    assert_eq!(f(Filters { flag: Some(Flag::Pick), ..Filters::default() }), 1);
    assert_eq!(f(Filters { flag: Some(Flag::Reject), ..Filters::default() }), 1);
    assert_eq!(f(Filters { color_labels: vec![ColorLabel::Red], ..Filters::default() }), 2);
    assert_eq!(f(Filters { tags_all: vec!["travel".into()], ..Filters::default() }), 3, "tags are case-insensitive");
    assert_eq!(f(Filters { tags_all: vec!["travel".into(), "b-roll".into()], ..Filters::default() }), 2);
    assert_eq!(f(Filters { tags_any: vec!["b-roll".into(), "nothing".into()], ..Filters::default() }), 2);
    assert_eq!(f(Filters { tags_all: vec!["nothing".into()], ..Filters::default() }), 0);
}

#[test]
fn missing_and_disabled_folders_are_hidden_by_default() {
    let l = lib();
    let gone = l.ids[0];
    l.db.write(move |tx| assets::mark_missing(tx, &[gone], NOW)).unwrap();
    assert_eq!(names(&l, &SearchQuery::default()).len(), 9);
    let only = filtered(Filters { missing: MissingFilter::Only, ..Filters::default() });
    assert_eq!(names(&l, &only), vec!["beach_sunset.jpg"]);
    let all = filtered(Filters { missing: MissingFilter::Include, ..Filters::default() });
    assert_eq!(names(&l, &all).len(), 10);

    let folder = l.folder;
    l.db.write(move |tx| folders::set_folder_enabled(tx, folder, false)).unwrap();
    assert!(names(&l, &all).is_empty(), "a switched-off folder disappears from every view");
    let s = l.db.read(stats).unwrap();
    assert_eq!(s.total, 0);
}

#[test]
fn offline_drives_stay_searchable() {
    let l = lib();
    l.db.write(|tx| folders::set_volume_online(tx, "V", None, NOW)).unwrap();
    assert_eq!(names(&l, &text("beach")).len(), 2, "L4: results remain while the drive is unplugged");
}

#[test]
fn sorting_is_deterministic_in_both_directions() {
    let l = lib();
    let by = |key, descending| {
        names(&l, &SearchQuery { sort: Sort { key, descending }, ..SearchQuery::default() })
    };
    assert_eq!(by(SortKey::Name, false)[0], "beach_drone.mov");
    assert_eq!(by(SortKey::Name, false)[9], "zebra.jpg");
    assert_eq!(by(SortKey::Name, true)[0], "zebra.jpg");
    assert_eq!(by(SortKey::Size, true)[0], "beach_drone.mov");
    assert_eq!(by(SortKey::Size, false)[0], "zebra.jpg");
    assert_eq!(by(SortKey::Duration, true)[0], "podcast_ep12.mp3");
    assert_eq!(by(SortKey::DateModified, false)[0], "zebra.jpg");
    assert_eq!(by(SortKey::DateCaptured, true), by(SortKey::DateCaptured, true), "stable");
    // Relevance with no text and Manual without a collection fall back to newest first.
    assert_eq!(by(SortKey::Relevance, true), by(SortKey::DateCaptured, true));
    assert_eq!(by(SortKey::Manual, true), by(SortKey::DateCaptured, true));
}

#[test]
fn collections_filter_and_manual_order() {
    let l = lib();
    let ids = l.ids.clone();
    let c = l
        .db
        .write(move |tx| {
            let c = organize::create_collection(tx, "Reel", NOW)?;
            organize::add_to_collection(tx, c, &[ids[7], ids[2], ids[5]], NOW)?;
            Ok(c)
        })
        .unwrap();
    let q = SearchQuery {
        filters: Filters { collection_id: Some(c), ..Filters::default() },
        sort: Sort { key: SortKey::Manual, descending: false },
        ..SearchQuery::default()
    };
    assert_eq!(names(&l, &q), vec!["reel_vertical.mp4", "city_night.mov", "IMG_4471.heic"]);
    let both = SearchQuery { text: Some("city".into()), ..q };
    assert_eq!(names(&l, &both), vec!["city_night.mov"]);
}

#[test]
fn smart_collection_definitions_run_like_any_query() {
    let l = lib();
    let ids = l.ids.clone();
    l.db.write(move |tx| organize::set_rating(tx, &ids[1..3], 4)).unwrap();
    let def = SearchQuery {
        text: Some("beach".into()),
        filters: Filters { min_rating: Some(4), ..Filters::default() },
        ..SearchQuery::default()
    };
    let d2 = def.clone();
    l.db.write(move |tx| organize::create_smart_collection(tx, "Top beach", &d2, NOW)).unwrap();
    // "Updates live": after a new rating the same stored definition returns the new set.
    let stored = l.db.read(organize::list_smart_collections).unwrap().remove(0).query;
    assert_eq!(names(&l, &stored), vec!["beach_drone.mov"]);
    let ids = l.ids.clone();
    l.db.write(move |tx| organize::set_rating(tx, &ids[0..1], 5)).unwrap();
    assert_eq!(names(&l, &stored).len(), 2);
}

#[test]
fn stats_count_kinds_and_missing() {
    let l = lib();
    let s = l.db.read(stats).unwrap();
    assert_eq!((s.total, s.images, s.videos, s.audio, s.missing), (10, 5, 3, 2, 0));
    let gone = l.ids[1];
    l.db.write(move |tx| assets::mark_missing(tx, &[gone], NOW)).unwrap();
    let s = l.db.read(stats).unwrap();
    assert_eq!((s.total, s.videos, s.missing), (9, 2, 1));
}

/// 250k synthetic assets: checks the plan's §8 latency targets and that every filter uses an index sensibly.
/// `cargo test -p sa-search --release -- --ignored --nocapture`
#[test]
#[ignore = "benchmark: 250k assets, run on demand"]
fn bench_250k_assets() {
    use std::time::Instant;
    // `SA_BENCH_DB=/tmp/sa-250k` keeps the library so the app can open it (tools/bench-grid.sh).
    let kept = std::env::var("SA_BENCH_DB").ok().map(std::path::PathBuf::from);
    let tmp = tempfile::tempdir().unwrap();
    let dir_path = kept.clone().unwrap_or_else(|| tmp.path().to_path_buf());
    std::fs::create_dir_all(&dir_path).unwrap();
    let (db, _) = Db::open(&dir_path.join("library.sqlite")).unwrap();
    let t = Instant::now();
    db.write(|tx| {
        let v = folders::upsert_volume(tx, "V", "Disk", "/", true, NOW)?;
        folders::add_folder(tx, v, "m", "m", None, NOW)?;
        let mut ins = tx
            .prepare(
                "INSERT INTO assets(folder_id, rel_path, name, ext, kind, size, mtime, quick_hash, added_at, sort_date,
                                    width, height, orientation, duration_ms, rating, probe_state)
                 VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?6, ?6, ?8, ?9, ?10, ?11, ?12, 1)",
            )
            .unwrap();
        let mut fts = tx.prepare("INSERT INTO asset_fts(rowid, name, path, tags, notes) VALUES (?1, ?2, ?3, '', '')").unwrap();
        let words = ["beach", "city", "night", "drone", "interview", "forest", "mountain", "studio", "street", "portrait"];
        for i in 0..250_000i64 {
            let kind = i % 3;
            let name = format!("{}_{}_{i}.{}", words[(i % 10) as usize], words[((i / 10) % 10) as usize], ["jpg", "mov", "wav"][kind as usize]);
            ins.execute(rusqlite::params![
                format!("d{}/{name}", i % 500),
                name,
                ["jpg", "mov", "wav"][kind as usize],
                kind,
                i * 7,
                NOW - i * 60_000,
                (i as u64).to_le_bytes().repeat(2),
                if kind == 2 { None } else { Some(1920 + (i % 5) * 480) },
                if kind == 2 { None } else { Some(1080 + (i % 5) * 270) },
                i % 3,
                if kind == 0 { None } else { Some(i % 600_000) },
                i % 6,
            ])
            .unwrap();
            fts.execute(rusqlite::params![i + 1, name, format!("d{}/{name}", i % 500)]).unwrap();
        }
        // This library is "fully indexed": its picture-hash pass is finished too. Without these records the app would
        // start hashing 166,667 files that do not exist, and the benchmark would measure that instead of an idle app.
        tx.execute(
            "INSERT INTO jobs(kind, asset_id, variant, lane, state, created_at, updated_at)
             SELECT 'phash', id, 'v1', 5, 2, ?1, ?1 FROM assets WHERE kind IN (0, 1)",
            [NOW],
        )
        .unwrap();
        Ok(())
    })
    .unwrap();
    println!("insert 250k: {:?}", t.elapsed());

    let time = |label: &str, q: SearchQuery| {
        let t = Instant::now();
        let n = db.read(|c| run(c, &q)).unwrap().len();
        println!("{label:<36} {n:>7} rows  {:>8.1?}", t.elapsed());
    };
    time("all, newest first", SearchQuery::default());
    time("all, by name", SearchQuery { sort: Sort { key: SortKey::Name, descending: false }, ..SearchQuery::default() });
    time("keyword 'beach'", text("beach"));
    time("keyword 'beach city'", text("beach city"));
    time("keyword prefix 'mount'", text("mount"));
    time("keyword rare '24999'", text("24999"));
    time("videos only", filtered(Filters { kinds: vec![MediaKind::Video], ..Filters::default() }));
    time("4K videos rated 3+", filtered(Filters { kinds: vec![MediaKind::Video], min_resolution: Some(ResolutionClass::Uhd4k), min_rating: Some(3), ..Filters::default() }));
    time("vertical, last 30 days", filtered(Filters { orientations: vec![Orientation::Vertical], date: Some(DateRange { from: Some(NOW - 30 * DAY), to: None }), ..Filters::default() }));
    time("keyword + videos + rating", SearchQuery { text: Some("drone".into()), filters: Filters { kinds: vec![MediaKind::Video], min_rating: Some(2), ..Filters::default() }, ..SearchQuery::default() });
    let t = Instant::now();
    let s = db.read(stats).unwrap();
    println!("stats: {:?} -> {:?}", t.elapsed(), s);
    let ids: Vec<i64> = (1..=120).collect();
    let t = Instant::now();
    let page = db.read(|c| assets::summaries(c, &ids)).unwrap();
    println!("summaries page of 120: {:?} ({} rows)", t.elapsed(), page.len());
    let ids: Vec<i64> = (200_000..200_120).collect();
    let t = Instant::now();
    db.read(|c| assets::summaries(c, &ids)).unwrap();
    println!("summaries page deep in the set: {:?}", t.elapsed());
    db.close().unwrap();
}
