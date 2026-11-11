use sa_watch::DebounceConfig;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// `~/Library/Application Support/SmartAsset/` in the app, a temp dir in tests.
    pub data_dir: PathBuf,
    /// Threads used for hashing during scans.
    pub scan_threads: usize,
    /// Parallel decodes a media worker may run when nothing holds it back.
    pub worker_parallelism: u32,
    /// Watch added folders for live updates (plan L2). Tests that do not need it switch it off.
    pub watch: bool,
    pub debounce: DebounceConfig,
    /// Pause after every megabyte read for a full-content hash. Zero in the app. Tests use it to hold a hash job
    /// in flight long enough to interrupt it.
    pub hash_throttle: std::time::Duration,
}

impl EngineConfig {
    #[must_use]
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        let cores = std::thread::available_parallelism().map_or(4, std::num::NonZeroUsize::get);
        Self {
            data_dir: data_dir.into(),
            scan_threads: (cores / 2).clamp(2, 6),
            worker_parallelism: u32::try_from((cores / 2).clamp(2, 6)).unwrap_or(4),
            watch: true,
            debounce: sa_watch::default_config(),
            hash_throttle: std::time::Duration::ZERO,
        }
    }
}
