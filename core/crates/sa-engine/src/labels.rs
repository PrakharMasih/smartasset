//! Labels (Phase 4, C1 and C2).
//!
//! **Shows (C1):** what a picture shows, as words from a fixed list ("beach", "dog", …). Each word is embedded once by the
//! model (the Swift side announces the list with `set_labels`); a file gets a word when its own description is close
//! enough to it (the model's measured cut-off). Nothing is stored: the answer comes from the vectors already kept.
//!
//! **Content (C2):** what kind of picture a file is: a camera's, a screen capture, or mostly text. Measured on generated and
//! real pictures, the model could not tell photos from illustrations reliably (14 of 36 photos called illustrations), so
//! this uses facts about the file instead, and says nothing when no fact applies.

use crate::engine::Engine;
use sa_core::{AssetId, Result};
use sa_store::{embeddings, text};

/// A word from the label list and how close the file's description is to it.
#[derive(Debug, Clone, PartialEq)]
pub struct LabelScore {
    pub name: String,
    pub score: f32,
}

/// What kind of picture a file is, when a fact about it says so.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PictureContent {
    /// The file names the camera that made it.
    Camera,
    /// Named the way macOS and common tools name screenshots and screen recordings.
    ScreenCapture,
    /// A picture in which the text reader found at least [`TEXT_DOCUMENT_CHARS`] characters.
    TextDocument,
}

/// Enough text for a picture to be "mostly text" (a page, a slide full of words, a receipt).
pub const TEXT_DOCUMENT_CHARS: usize = 400;
/// The most labels a file shows.
pub const MAX_LABELS: usize = 5;

/// The label list as the model embedded it.
#[derive(Debug, Clone)]
pub(crate) struct LabelSet {
    names: Vec<String>,
    vectors: Vec<Vec<f32>>,
    cut: f32,
}

impl Engine {
    /// Announces the label words and their vectors (the model's question vector for each word) and the cut-off measured
    /// for this model. Words whose vector is unusable are left out.
    pub fn set_labels(&self, labels: Vec<(String, Vec<f32>)>, cut: f32) {
        let mut names = Vec::new();
        let mut vectors = Vec::new();
        for (name, mut v) in labels {
            if sa_vector::normalise(&mut v) {
                names.push(name);
                vectors.push(v);
            }
        }
        *self.inner.labels.lock() = Some(LabelSet { names, vectors, cut });
    }

    /// The words a file shows, closest first, at most [`MAX_LABELS`]. A video counts at its closest scene. Empty when no
    /// label list or model is announced, or the file has no description yet.
    pub fn labels_of(&self, asset: AssetId) -> Result<Vec<LabelScore>> {
        let Some(set) = self.inner.labels.lock().clone() else { return Ok(Vec::new()) };
        let Some(config) = self.inner.embedding.lock().clone() else { return Ok(Vec::new()) };
        let frames: Vec<Vec<f32>> = self
            .inner
            .db
            .read(|c| embeddings::frames_of(c, asset, &config))?
            .iter()
            .filter_map(|f| sa_vector::decode_f16(&f.vec))
            .collect();
        Ok(best_labels(&set, &frames))
    }

    /// What kind of picture a file is, from facts about it; `None` when no fact says.
    pub fn picture_content(&self, asset: AssetId) -> Result<Option<PictureContent>> {
        let facts = self.inner.db.read(|c| {
            let row = c
                .query_row(
                    "SELECT name, kind, COALESCE(camera_make, '') <> '' OR COALESCE(camera_model, '') <> '' FROM assets WHERE id = ?1",
                    [asset.0],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, bool>(2)?)),
                )
                .ok();
            Ok(row.map(|(name, kind, camera)| (name, kind, camera, text::text_of(c, asset).ok().flatten().map_or(0, |t| t.chars().count()))))
        })?;
        Ok(facts.and_then(|(name, kind, camera, text_chars)| content_from(&name, kind, camera, text_chars)))
    }
}

/// The rule behind [`Engine::picture_content`], kept apart so it is tested on its own. `kind` is the stored media kind
/// (0 picture, 1 video, 2 sound).
#[must_use]
pub fn content_from(name: &str, kind: i64, camera: bool, text_chars: usize) -> Option<PictureContent> {
    if kind == 2 {
        return None;
    }
    let lower = name.to_lowercase();
    if ["screenshot", "screen shot", "screen recording", "cleanshot"].iter().any(|p| lower.starts_with(p)) {
        return Some(PictureContent::ScreenCapture);
    }
    if kind == 0 && text_chars >= TEXT_DOCUMENT_CHARS {
        return Some(PictureContent::TextDocument);
    }
    camera.then_some(PictureContent::Camera)
}

fn best_labels(set: &LabelSet, frames: &[Vec<f32>]) -> Vec<LabelScore> {
    let mut out: Vec<LabelScore> = set
        .names
        .iter()
        .zip(&set.vectors)
        .filter_map(|(name, label)| {
            let score = frames
                .iter()
                .filter(|f| f.len() == label.len())
                .map(|f| f.iter().zip(label).map(|(a, b)| a * b).sum::<f32>())
                .fold(f32::MIN, f32::max);
            (score >= set.cut).then(|| LabelScore { name: name.clone(), score })
        })
        .collect();
    out.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.name.cmp(&b.name)));
    out.truncate(MAX_LABELS);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_comes_from_facts_in_this_order() {
        assert_eq!(content_from("Screenshot 2026-11-09 at 10.12.03.png", 0, false, 900), Some(PictureContent::ScreenCapture));
        assert_eq!(content_from("Screen Recording 2026-11-09.mov", 1, true, 0), Some(PictureContent::ScreenCapture));
        assert_eq!(content_from("receipt.jpg", 0, true, 400), Some(PictureContent::TextDocument), "a photographed page is mostly text");
        assert_eq!(content_from("receipt.jpg", 0, true, 399), Some(PictureContent::Camera));
        assert_eq!(content_from("clip.mov", 1, false, 5000), None, "a video is never a text document");
        assert_eq!(content_from("art.png", 0, false, 0), None, "no fact, no claim");
        assert_eq!(content_from("Screenshot.wav", 2, false, 0), None, "sounds have no picture");
    }

    #[test]
    fn labels_pass_the_cut_closest_first_and_at_most_five() {
        let unit = |i: usize| {
            let mut v = vec![0.0_f32; 8];
            v[i] = 1.0;
            v
        };
        let set = LabelSet { names: (0..8).map(|i| format!("w{i}")).collect(), vectors: (0..8).map(unit).collect(), cut: 0.5 };
        // A picture close to w1 (0.8) and w2 (0.6), far from the rest.
        let picture = vec![vec![0.0, 0.8, 0.6, 0.0, 0.0, 0.0, 0.0, 0.0]];
        let got: Vec<String> = best_labels(&set, &picture).into_iter().map(|l| l.name).collect();
        assert_eq!(got, vec!["w1", "w2"]);
        // A video counts at its closest scene.
        let video = vec![unit(3), unit(4)];
        assert_eq!(best_labels(&set, &video).len(), 2);
        assert!(best_labels(&set, &[]).is_empty(), "no description, no labels");
        let everything = vec![vec![1.0_f32; 8]];
        let wide = LabelSet { cut: 0.1, ..set };
        assert_eq!(best_labels(&wide, &everything).len(), MAX_LABELS);
    }
}
