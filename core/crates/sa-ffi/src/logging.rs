//! Local rotating logs (plan §6.4). Nothing is ever sent anywhere.

use std::path::Path;
use std::sync::{Once, OnceLock};
use tracing_appender::non_blocking::WorkerGuard;

static INIT: Once = Once::new();
static GUARD: OnceLock<WorkerGuard> = OnceLock::new();

/// Starts logging to `<dir>/smartasset.<date>.log`, keeping a week of files. Safe to call more than once.
pub fn init(dir: &Path) {
    INIT.call_once(|| {
        let _ = std::fs::create_dir_all(dir);
        let appender = tracing_appender::rolling::Builder::new()
            .rotation(tracing_appender::rolling::Rotation::DAILY)
            .filename_prefix("smartasset")
            .filename_suffix("log")
            .max_log_files(7)
            .build(dir);
        let Ok(appender) = appender else { return };
        let (writer, guard) = tracing_appender::non_blocking(appender);
        let filter = tracing_subscriber::EnvFilter::try_from_env("SA_LOG")
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
        let installed = tracing_subscriber::fmt()
            .with_writer(writer)
            .with_ansi(false)
            .with_env_filter(filter)
            .try_init()
            .is_ok();
        if installed {
            let _ = GUARD.set(guard);
        }
    });
}
