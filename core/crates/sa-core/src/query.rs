//! The search request model: free text, filters (plan S10) and sort.
//!
//! This is also the stored form of a smart collection (plan O3), so every field has a serde default and
//! unknown fields are ignored: a newer app can add filters without breaking older saved searches.

use crate::media::{MediaKind, Orientation};
use serde::{Deserialize, Serialize};

/// Pick / reject flag (plan O1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Flag {
    #[default]
    None,
    Pick,
    Reject,
}

impl Flag {
    #[must_use]
    pub const fn to_db(self) -> i64 {
        match self {
            Self::None => 0,
            Self::Pick => 1,
            Self::Reject => -1,
        }
    }

    #[must_use]
    pub const fn from_db(v: i64) -> Option<Self> {
        match v {
            0 => Some(Self::None),
            1 => Some(Self::Pick),
            -1 => Some(Self::Reject),
            _ => None,
        }
    }
}

/// Finder-style colour labels (plan O1). 0 means no label.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum ColorLabel {
    #[default]
    None = 0,
    Red = 1,
    Orange = 2,
    Yellow = 3,
    Green = 4,
    Blue = 5,
    Purple = 6,
    Gray = 7,
}

impl ColorLabel {
    #[must_use]
    pub const fn to_db(self) -> i64 {
        self as i64
    }

    #[must_use]
    pub const fn from_db(v: i64) -> Option<Self> {
        Some(match v {
            0 => Self::None,
            1 => Self::Red,
            2 => Self::Orange,
            3 => Self::Yellow,
            4 => Self::Green,
            5 => Self::Blue,
            6 => Self::Purple,
            7 => Self::Gray,
            _ => return None,
        })
    }
}

/// Minimum long edge in pixels, named the way creators name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResolutionClass {
    Hd720,
    Fhd1080,
    Qhd1440,
    Uhd4k,
    Uhd8k,
}

impl ResolutionClass {
    /// Smallest long edge that still counts. 4K accepts 3840x2160 UHD and 4096x2160 DCI, and a few pixels
    /// of cropping (3800) so "4K" finds what people call 4K.
    #[must_use]
    pub const fn min_long_edge(self) -> i64 {
        match self {
            Self::Hd720 => 1280,
            Self::Fhd1080 => 1900,
            Self::Qhd1440 => 2500,
            Self::Uhd4k => 3800,
            Self::Uhd8k => 7600,
        }
    }
}

/// Inclusive date range in milliseconds since the epoch. Either end may be open.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct DateRange {
    pub from: Option<i64>,
    pub to: Option<i64>,
}

/// How assets whose file has gone missing are treated. Offline drives are not "missing": they stay in results.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MissingFilter {
    #[default]
    Hide,
    Include,
    Only,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Filters {
    pub kinds: Vec<MediaKind>,
    /// Capture date, falling back to the file's modification date.
    pub date: Option<DateRange>,
    pub min_duration_ms: Option<i64>,
    pub max_duration_ms: Option<i64>,
    pub min_resolution: Option<ResolutionClass>,
    pub orientations: Vec<Orientation>,
    /// The asset must have every one of these tags.
    pub tags_all: Vec<String>,
    /// The asset must have at least one of these tags.
    pub tags_any: Vec<String>,
    pub min_rating: Option<u8>,
    /// Only unrated assets (rating 0). Wins over `min_rating`.
    pub unrated_only: bool,
    pub flag: Option<Flag>,
    pub color_labels: Vec<ColorLabel>,
    pub folder_ids: Vec<i64>,
    /// "Drive" filter.
    pub volume_ids: Vec<i64>,
    /// Restrict to the members of a manual collection.
    pub collection_id: Option<i64>,
    pub missing: MissingFilter,
}

impl Filters {
    /// True when no filter narrows the library (the default "All" view).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SortKey {
    /// Keyword relevance. Falls back to `DateCaptured` when there is no text.
    Relevance,
    Name,
    #[default]
    DateCaptured,
    DateAdded,
    DateModified,
    Size,
    Duration,
    Rating,
    Kind,
    /// The order the user arranged a collection in. Only valid with `Filters::collection_id`.
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default)]
pub struct Sort {
    pub key: SortKey,
    pub descending: bool,
}

impl Default for Sort {
    fn default() -> Self {
        Self {
            key: SortKey::DateCaptured,
            descending: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SearchQuery {
    /// Keyword text matched against names, paths, tags and notes (and transcripts/OCR from later milestones).
    pub text: Option<String>,
    pub filters: Filters,
    pub sort: Sort,
}

impl SearchQuery {
    /// Text with surrounding whitespace removed; `None` when nothing is left.
    #[must_use]
    pub fn trimmed_text(&self) -> Option<&str> {
        self.text.as_deref().map(str::trim).filter(|t| !t.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_query_is_the_whole_library_newest_first() {
        let q = SearchQuery::default();
        assert!(q.filters.is_empty());
        assert_eq!(q.sort.key, SortKey::DateCaptured);
        assert!(q.sort.descending);
        assert_eq!(q.filters.missing, MissingFilter::Hide);
    }

    #[test]
    fn saved_searches_survive_added_and_unknown_fields() {
        // A smart collection written by an older version has no `min_resolution`; a newer one has an unknown field.
        let old = r#"{"filters":{"kinds":["video"],"min_rating":3},"sort":{"key":"name","descending":false}}"#;
        let q: SearchQuery = serde_json::from_str(old).unwrap();
        assert_eq!(q.filters.kinds, vec![MediaKind::Video]);
        assert_eq!(q.filters.min_rating, Some(3));
        assert_eq!(q.filters.min_resolution, None);

        let newer = r#"{"text":"beach","future_field":123,"filters":{"unknown_filter":true}}"#;
        let q: SearchQuery = serde_json::from_str(newer).unwrap();
        assert_eq!(q.text.as_deref(), Some("beach"));
    }

    #[test]
    fn query_roundtrips() {
        let q = SearchQuery {
            text: Some("neon".into()),
            filters: Filters {
                kinds: vec![MediaKind::Video, MediaKind::Image],
                orientations: vec![Orientation::Vertical],
                min_resolution: Some(ResolutionClass::Uhd4k),
                tags_all: vec!["b-roll".into()],
                color_labels: vec![ColorLabel::Green],
                ..Filters::default()
            },
            sort: Sort { key: SortKey::Rating, descending: true },
        };
        let json = serde_json::to_string(&q).unwrap();
        assert_eq!(serde_json::from_str::<SearchQuery>(&json).unwrap(), q);
    }

    #[test]
    fn trimmed_text_ignores_blank() {
        let blank = SearchQuery { text: Some("   ".into()), ..SearchQuery::default() };
        assert_eq!(blank.trimmed_text(), None);
        let padded = SearchQuery { text: Some("  hi ".into()), ..SearchQuery::default() };
        assert_eq!(padded.trimmed_text(), Some("hi"));
    }

    #[test]
    fn flag_and_label_db_roundtrip() {
        for f in [Flag::None, Flag::Pick, Flag::Reject] {
            assert_eq!(Flag::from_db(f.to_db()), Some(f));
        }
        assert_eq!(Flag::from_db(2), None);
        for v in 0..=7 {
            assert_eq!(ColorLabel::from_db(v).map(ColorLabel::to_db), Some(v));
        }
        assert_eq!(ColorLabel::from_db(8), None);
    }
}
