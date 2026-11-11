//! Wall-clock time as milliseconds since the Unix epoch.

use std::time::{SystemTime, UNIX_EPOCH};

/// Milliseconds since the Unix epoch. Negative values are dates before 1970.
pub type UnixMillis = i64;

/// The current time. A clock set before 1970 reads as 0 instead of panicking.
#[must_use]
pub fn now_ms() -> UnixMillis {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Converts a file-system timestamp to [`UnixMillis`], handling dates before 1970.
#[must_use]
pub fn system_time_to_ms(t: SystemTime) -> UnixMillis {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_millis()).unwrap_or(i64::MAX),
        Err(e) => -i64::try_from(e.duration().as_millis()).unwrap_or(i64::MAX),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn before_epoch_is_negative() {
        let t = UNIX_EPOCH - Duration::from_secs(2);
        assert_eq!(system_time_to_ms(t), -2000);
    }

    #[test]
    fn after_epoch_is_positive() {
        let t = UNIX_EPOCH + Duration::from_millis(1500);
        assert_eq!(system_time_to_ms(t), 1500);
    }

    #[test]
    fn now_is_recent() {
        assert!(now_ms() > 1_700_000_000_000);
    }
}
