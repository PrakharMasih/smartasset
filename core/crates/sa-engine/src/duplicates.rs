//! Duplicate groups for the Duplicates page (plan A1, A2). Read-only: nothing here touches a file.
//!
//! * **Exact** groups come from the full-content hash: same size, same BLAKE3, all present.
//! * **Similar** groups come from the perceptual hashes (`sa-dedupe`): resized, re-encoded or lightly edited copies.
//!
//! Groups are computed on demand and cached until the library changes.

use crate::engine::{Engine, Inner};
use sa_core::Result;
use sa_dedupe::{Config, Hash, Item, Kind};
use sa_core::MediaKind;
use sa_store::model::AssetSummary;
use sa_store::{assets, dedupe, embeddings};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DuplicateKind {
    /// Byte-for-byte identical.
    Exact,
    /// Looks like the same shot.
    Similar,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateMember {
    pub asset_id: i64,
    /// 100 for an exact copy; otherwise how close the picture is to the group's anchor.
    pub similarity: u8,
    /// The copy the app would keep: the one with the user's own work on it, then the sharpest, then the oldest.
    pub suggested_keep: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateGroup {
    /// Identifies the group while the Duplicates page is open.
    pub key: String,
    pub kind: DuplicateKind,
    /// The suggested copy to keep first.
    pub members: Vec<DuplicateMember>,
    /// What removing every copy but the largest would free.
    pub wasted_bytes: i64,
}

#[derive(Debug, Default)]
pub struct GroupSets {
    pub exact: Vec<DuplicateGroup>,
    pub similar: Vec<DuplicateGroup>,
    pub exact_wasted: i64,
    pub similar_wasted: i64,
}

/// What the Duplicates page shows.
#[derive(Debug, Clone)]
pub struct Duplicates {
    pub sets: Arc<GroupSets>,
    /// Suspected copies still being read in full.
    pub hash_remaining: i64,
    /// Pictures and videos still waiting for their look-alike hash.
    pub perceptual_remaining: i64,
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

/// Sort key for "which copy to keep", best first: has the user's work on it, more pixels, larger file, older, lower id.
fn keep_rank(s: &AssetSummary, has_user_data: bool) -> impl Ord {
    let pixels = u64::from(s.width.unwrap_or(0)) * u64::from(s.height.unwrap_or(0));
    (!has_user_data, std::cmp::Reverse(pixels), std::cmp::Reverse(s.size), s.mtime, s.id.0)
}

impl Inner {
    /// Queues full hashes for new suspects and picture hashes for pictures that have none.
    pub(crate) fn refresh_dedupe_queue(&self) {
        for enqueue in [dedupe::enqueue_hash_candidates, dedupe::enqueue_perceptual_backlog] {
            loop {
                let n = self.db.write(move |tx| enqueue(tx, 5_000, sa_core::time::now_ms()));
                match n {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        }
        self.notifier.work_started();
    }

    /// Files were added or changed: look for new suspects when the hasher next has a turn.
    pub(crate) fn mark_dedupe_dirty(&self) {
        self.queue_dirty.store(true, Ordering::Relaxed);
        self.embed_dirty.store(true, Ordering::Relaxed);
        self.text_dirty.store(true, Ordering::Relaxed);
        self.hasher.wake();
    }

    /// True when one of `ids` is in a group of similar copies the Duplicates page last showed.
    pub(crate) fn in_similar_group(&self, ids: &[i64]) -> bool {
        let cached = self.dup_cache.lock();
        let Some((_, sets)) = cached.as_ref() else { return false };
        sets.similar.iter().any(|g| g.members.iter().any(|m| ids.contains(&m.asset_id)))
    }

    /// Something the Duplicates page shows may have changed.
    pub(crate) fn touch_duplicates(&self) {
        self.notifier.duplicates_changed();
    }

    fn compute_duplicates(&self) -> Result<GroupSets> {
        let (exact_rows, perceptual_rows) =
            self.db.read(|c| Ok((dedupe::exact_groups(c)?, dedupe::perceptual_rows(c)?)))?;
        let items: Vec<Item> = perceptual_rows
            .iter()
            .map(|r| Item {
                id: r.id,
                kind: if r.kind == MediaKind::Video { Kind::Video } else { Kind::Image },
                duration_ms: r.duration_ms,
                exact_key: r.content_hash.as_deref().and_then(|h| h.get(..8)).map(|b| {
                    let mut a = [0u8; 8];
                    a.copy_from_slice(b);
                    u64::from_le_bytes(a)
                }),
                slots: r.slots.iter().map(|h| Hash { d: h.dhash, p: h.phash }).collect(),
            })
            .collect();
        let near = confirm_by_meaning(self, sa_dedupe::group(&items, Config::default()))?;

        let mut ids: Vec<i64> = exact_rows.iter().flat_map(|g| g.ids.iter().copied()).collect();
        ids.extend(near.iter().flat_map(|g| g.members.iter().map(|m| m.id)));
        ids.sort_unstable();
        ids.dedup();
        let (summaries, with_data) = self.db.read(|c| Ok((assets::summaries(c, &ids)?, dedupe::assets_with_user_data(c, &ids)?)))?;
        let by_id: HashMap<i64, &AssetSummary> = summaries.iter().map(|s| (s.id.0, s)).collect();

        let order = |members: &mut Vec<DuplicateMember>| {
            members.sort_by(|a, b| {
                let key = |m: &DuplicateMember| {
                    by_id.get(&m.asset_id).map(|s| keep_rank(s, with_data.contains(&m.asset_id)))
                };
                match (key(a), key(b)) {
                    (Some(x), Some(y)) => x.cmp(&y),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => a.asset_id.cmp(&b.asset_id),
                }
            });
            if let Some(first) = members.first_mut() {
                first.suggested_keep = true;
            }
        };
        let wasted = |members: &[DuplicateMember]| {
            let sizes: Vec<i64> = members.iter().filter_map(|m| by_id.get(&m.asset_id).map(|s| s.size)).collect();
            sizes.iter().sum::<i64>() - sizes.iter().copied().max().unwrap_or(0)
        };

        let mut sets = GroupSets::default();
        for g in exact_rows {
            let mut members: Vec<DuplicateMember> =
                g.ids.iter().map(|&asset_id| DuplicateMember { asset_id, similarity: 100, suggested_keep: false }).collect();
            order(&mut members);
            sets.exact_wasted += g.wasted();
            sets.exact.push(DuplicateGroup {
                key: format!("x:{}", hex(&g.hash)),
                kind: DuplicateKind::Exact,
                wasted_bytes: g.wasted(),
                members,
            });
        }
        for g in near {
            let anchor = g.members[0].id;
            let mut members: Vec<DuplicateMember> = g
                .members
                .iter()
                .map(|m| DuplicateMember { asset_id: m.id, similarity: m.similarity, suggested_keep: false })
                .collect();
            order(&mut members);
            let w = wasted(&members);
            sets.similar_wasted += w;
            sets.similar.push(DuplicateGroup {
                key: format!("s:{anchor}"),
                kind: DuplicateKind::Similar,
                wasted_bytes: w,
                members,
            });
        }
        sets.similar.sort_by_key(|g| (std::cmp::Reverse(g.wasted_bytes), g.members[0].asset_id));
        Ok(sets)
    }
}

impl Engine {
    /// The duplicate groups right now. Cheap when nothing changed since the last call.
    pub fn duplicates(&self) -> Result<Duplicates> {
        let inner = &self.inner;
        let epoch = inner.notifier.epoch();
        let cached = inner.dup_cache.lock().as_ref().filter(|(e, _)| *e == epoch).map(|(_, s)| Arc::clone(s));
        let sets = if let Some(s) = cached {
            s
        } else {
            let fresh = Arc::new(inner.compute_duplicates()?);
            *inner.dup_cache.lock() = Some((epoch, Arc::clone(&fresh)));
            fresh
        };
        let p = inner.db.read(dedupe::progress)?;
        Ok(Duplicates { sets, hash_remaining: p.hash_remaining, perceptual_remaining: p.perceptual_remaining })
    }
}

/// A2: a group found by picture fingerprints is confirmed by meaning. Each file must look like the group's first file
/// (the cut-off the model announced, `Calibration::copy_match`) or it leaves the group; a group left with one file is
/// no group. A file without a description yet stays: it is confirmed once it has one. With no model, or a model whose
/// cut-off was never measured, groups are as the fingerprints found them.
fn confirm_by_meaning(inner: &Inner, groups: Vec<sa_dedupe::Group>) -> Result<Vec<sa_dedupe::Group>> {
    let Some(config) = inner.embedding.lock().clone() else { return Ok(groups) };
    let Some(cut) = inner.calibration.lock().copy_match else { return Ok(groups) };
    let ids: Vec<i64> = groups.iter().flat_map(|g| g.members.iter().map(|m| m.id)).collect();
    let frames: HashMap<i64, Vec<Vec<f32>>> = inner.db.read(|c| {
        let mut out = HashMap::new();
        for id in &ids {
            let vectors = embeddings::frames_of(c, sa_core::AssetId(*id), &config)?
                .iter()
                .filter_map(|f| sa_vector::decode_f16(&f.vec))
                .collect::<Vec<_>>();
            out.insert(*id, vectors);
        }
        Ok(out)
    })?;
    let mut confirmed = Vec::with_capacity(groups.len());
    for mut g in groups {
        let Some(anchor) = g.members.first().and_then(|m| frames.get(&m.id)).filter(|f| !f.is_empty()).cloned() else {
            confirmed.push(g);
            continue;
        };
        let first = g.members[0].id;
        g.members.retain(|m| {
            m.id == first
                || frames.get(&m.id).is_none_or(|f| f.is_empty() || look_alike(&anchor, f) >= cut)
        });
        if g.members.len() >= 2 {
            confirmed.push(g);
        }
    }
    Ok(confirmed)
}

/// How much two files look alike by meaning: for each vector of `a` (one per picture, one per scene of a video), its
/// closest vector in `b`, averaged. Vectors are stored normalised, so a dot product is the cosine.
fn look_alike(a: &[Vec<f32>], b: &[Vec<f32>]) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let best = |x: &Vec<f32>| b.iter().map(|y| x.iter().zip(y).map(|(p, q)| p * q).sum::<f32>()).fold(f32::MIN, f32::max);
    #[allow(clippy::cast_precision_loss)]
    let n = a.len() as f32;
    a.iter().map(best).sum::<f32>() / n
}

#[cfg(test)]
mod meaning_tests {
    use super::look_alike;

    #[test]
    fn a_copy_looks_alike_and_a_different_picture_does_not() {
        let a = vec![vec![1.0, 0.0, 0.0]];
        assert!((look_alike(&a, &[vec![1.0, 0.0, 0.0]]) - 1.0).abs() < 1e-6);
        assert!(look_alike(&a, &[vec![0.0, 1.0, 0.0]]).abs() < 1e-6);
        // A video: each scene finds its closest scene in the other.
        let video = vec![vec![1.0, 0.0, 0.0], vec![0.0, 1.0, 0.0]];
        let reordered = vec![vec![0.0, 1.0, 0.0], vec![1.0, 0.0, 0.0]];
        assert!((look_alike(&video, &reordered) - 1.0).abs() < 1e-6);
        assert!(look_alike(&[], &a).abs() < 1e-6, "no description, no likeness");
    }
}
