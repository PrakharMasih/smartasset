//! Media kinds, supported formats (plan L6) and aspect classification (plan C3).

use serde::{Deserialize, Serialize};

/// The three kinds of asset SmartAsset indexes. Documents, fonts and 3D files are out of scope (plan §4.10).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum MediaKind {
    Image = 0,
    Video = 1,
    Audio = 2,
}

/// Formats the primary decoders (ImageIO, AVFoundation) handle: images incl. HEIC and camera RAW.
const IMAGE_EXTS: &[&str] = &[
    "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff",
    // camera RAW
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
    "srw", "x3f", "3fr", "erf", "kdc", "mrw", "mef", "mos", "rwl", "iiq", "fff",
];
const VIDEO_EXTS: &[&str] = &["mov", "mp4", "m4v"];
const AUDIO_EXTS: &[&str] = &["wav", "aif", "aiff", "mp3", "aac", "m4a", "flac"];

impl MediaKind {
    pub const ALL: [Self; 3] = [Self::Image, Self::Video, Self::Audio];

    /// Kind for a file extension (case-insensitive, without the dot). `None` means "not a media file we index".
    #[must_use]
    pub fn from_extension(ext: &str) -> Option<Self> {
        let ext = ext.to_ascii_lowercase();
        let ext = ext.as_str();
        if IMAGE_EXTS.contains(&ext) {
            Some(Self::Image)
        } else if VIDEO_EXTS.contains(&ext) {
            Some(Self::Video)
        } else if AUDIO_EXTS.contains(&ext) {
            Some(Self::Audio)
        } else {
            None
        }
    }

    #[must_use]
    pub const fn to_db(self) -> i64 {
        self as i64
    }

    #[must_use]
    pub const fn from_db(v: i64) -> Option<Self> {
        match v {
            0 => Some(Self::Image),
            1 => Some(Self::Video),
            2 => Some(Self::Audio),
            _ => None,
        }
    }

    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Image => "Image",
            Self::Video => "Video",
            Self::Audio => "Audio",
        }
    }
}

/// Camera RAW extensions, used to label files and to choose the embedded-preview thumbnail path.
#[must_use]
pub fn is_raw_extension(ext: &str) -> bool {
    const RAW: &[&str] = &[
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
        "srw", "x3f", "3fr", "erf", "kdc", "mrw", "mef", "mos", "rwl", "iiq", "fff",
    ];
    RAW.contains(&ext.to_ascii_lowercase().as_str())
}

/// Coarse shape of a picture or video frame, from file dimensions only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum Orientation {
    Horizontal = 0,
    Vertical = 1,
    Square = 2,
}

/// The common delivery ratios creators think in (plan C3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum AspectClass {
    Other = 0,
    Square1x1 = 1,
    Wide16x9 = 2,
    Vertical9x16 = 3,
    Standard4x3 = 4,
    Portrait3x4 = 5,
    Photo3x2 = 6,
    Portrait2x3 = 7,
    Landscape5x4 = 8,
    Portrait4x5 = 9,
    Ultrawide21x9 = 10,
}

impl Orientation {
    #[must_use]
    pub const fn to_db(self) -> i64 {
        self as i64
    }

    #[must_use]
    pub const fn from_db(v: i64) -> Option<Self> {
        match v {
            0 => Some(Self::Horizontal),
            1 => Some(Self::Vertical),
            2 => Some(Self::Square),
            _ => None,
        }
    }
}

impl AspectClass {
    #[must_use]
    pub const fn to_db(self) -> i64 {
        self as i64
    }

    #[must_use]
    pub const fn from_db(v: i64) -> Option<Self> {
        Some(match v {
            0 => Self::Other,
            1 => Self::Square1x1,
            2 => Self::Wide16x9,
            3 => Self::Vertical9x16,
            4 => Self::Standard4x3,
            5 => Self::Portrait3x4,
            6 => Self::Photo3x2,
            7 => Self::Portrait2x3,
            8 => Self::Landscape5x4,
            9 => Self::Portrait4x5,
            10 => Self::Ultrawide21x9,
            _ => return None,
        })
    }

    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Other => "Other",
            Self::Square1x1 => "1:1",
            Self::Wide16x9 => "16:9",
            Self::Vertical9x16 => "9:16",
            Self::Standard4x3 => "4:3",
            Self::Portrait3x4 => "3:4",
            Self::Photo3x2 => "3:2",
            Self::Portrait2x3 => "2:3",
            Self::Landscape5x4 => "5:4",
            Self::Portrait4x5 => "4:5",
            Self::Ultrawide21x9 => "21:9",
        }
    }
}

/// Relative distance within which a frame counts as a named ratio. 1920x1080 and 1920x1088 are both 16:9.
const ASPECT_TOLERANCE: f64 = 0.03;
/// A frame this close to 1:1 counts as square.
const SQUARE_TOLERANCE: f64 = 0.05;

/// Classifies displayed dimensions (rotation already applied). Zero dimensions classify as `Other`/`Square` neutral.
#[must_use]
pub fn classify(width: u32, height: u32) -> (Orientation, AspectClass) {
    const REFS: [(f64, AspectClass); 10] = [
        (1.0, AspectClass::Square1x1),
        (16.0 / 9.0, AspectClass::Wide16x9),
        (9.0 / 16.0, AspectClass::Vertical9x16),
        (4.0 / 3.0, AspectClass::Standard4x3),
        (3.0 / 4.0, AspectClass::Portrait3x4),
        (3.0 / 2.0, AspectClass::Photo3x2),
        (2.0 / 3.0, AspectClass::Portrait2x3),
        (5.0 / 4.0, AspectClass::Landscape5x4),
        (4.0 / 5.0, AspectClass::Portrait4x5),
        (21.0 / 9.0, AspectClass::Ultrawide21x9),
    ];

    if width == 0 || height == 0 {
        return (Orientation::Square, AspectClass::Other);
    }
    let r = f64::from(width) / f64::from(height);
    let orientation = if (r - 1.0).abs() <= SQUARE_TOLERANCE {
        Orientation::Square
    } else if r > 1.0 {
        Orientation::Horizontal
    } else {
        Orientation::Vertical
    };

    let best = REFS
        .iter()
        .map(|&(ratio, class)| ((r - ratio).abs() / ratio, class))
        .min_by(|a, b| a.0.total_cmp(&b.0));
    let class = match best {
        Some((err, class)) if err <= ASPECT_TOLERANCE => class,
        _ => AspectClass::Other,
    };
    (orientation, class)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions_are_case_insensitive() {
        assert_eq!(MediaKind::from_extension("JPG"), Some(MediaKind::Image));
        assert_eq!(MediaKind::from_extension("Mov"), Some(MediaKind::Video));
        assert_eq!(MediaKind::from_extension("FLAC"), Some(MediaKind::Audio));
        assert_eq!(MediaKind::from_extension("cr3"), Some(MediaKind::Image));
    }

    #[test]
    fn out_of_scope_formats_are_not_media() {
        for ext in ["pdf", "ttf", "obj", "psd", "txt", "mkv", "avi", "heic.xmp", ""] {
            assert_eq!(MediaKind::from_extension(ext), None, "{ext}");
        }
    }

    #[test]
    fn db_roundtrip() {
        for k in MediaKind::ALL {
            assert_eq!(MediaKind::from_db(k.to_db()), Some(k));
        }
        assert_eq!(MediaKind::from_db(9), None);
        for v in 0..=10 {
            assert_eq!(AspectClass::from_db(v).map(AspectClass::to_db), Some(v));
        }
        assert_eq!(AspectClass::from_db(11), None);
    }

    #[test]
    fn creator_formats_classify() {
        assert_eq!(classify(1920, 1080).1, AspectClass::Wide16x9);
        assert_eq!(classify(3840, 2160).1, AspectClass::Wide16x9);
        assert_eq!(classify(1080, 1920), (Orientation::Vertical, AspectClass::Vertical9x16));
        assert_eq!(classify(1080, 1350).1, AspectClass::Portrait4x5);
        assert_eq!(classify(1080, 1080), (Orientation::Square, AspectClass::Square1x1));
        assert_eq!(classify(6000, 4000).1, AspectClass::Photo3x2);
        assert_eq!(classify(4032, 3024).1, AspectClass::Standard4x3);
        assert_eq!(classify(2560, 1080).1, AspectClass::Ultrawide21x9);
        assert_eq!(classify(4096, 2160).1, AspectClass::Other);
    }

    #[test]
    fn near_square_counts_as_square() {
        assert_eq!(classify(1000, 1040).0, Orientation::Square);
        assert_eq!(classify(1000, 1200).0, Orientation::Vertical);
    }

    #[test]
    fn zero_dimensions_do_not_panic() {
        assert_eq!(classify(0, 100).1, AspectClass::Other);
        assert_eq!(classify(100, 0).1, AspectClass::Other);
    }
}
