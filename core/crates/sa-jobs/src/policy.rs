//! Pure scheduling policy: "may background work run right now, and how hard?" (plan global requirement 11).

/// Thermal state reported by the OS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Thermal {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MemoryPressure {
    #[default]
    Normal,
    Warning,
    Critical,
}

/// What the Mac is doing right now. Reported by the app; the core never polls the OS itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Conditions {
    pub on_battery: bool,
    pub low_power_mode: bool,
    pub thermal: Thermal,
    pub memory: MemoryPressure,
    /// The user is typing, scrolling or dragging right now.
    pub user_active: bool,
}

/// User-facing indexing settings (plan L5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settings {
    /// "Index only on power".
    pub index_only_on_power: bool,
    /// Parallel decodes the worker may run when nothing is holding it back. Chosen from the core count.
    pub max_parallelism: u32,
    pub max_batch: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self { index_only_on_power: false, max_parallelism: 4, max_batch: 32 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PauseReason {
    /// The user paused indexing.
    User,
    /// "Index only on power" is on and the Mac is on battery.
    Battery,
    /// The Mac is running hot.
    Thermal,
    /// The system is short of memory.
    Memory,
}

/// How much a worker may take on right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Throttle {
    /// Items per batch.
    pub max_batch: u32,
    /// Items the worker should process at once.
    pub parallelism: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    Run(Throttle),
    Hold(PauseReason),
}

/// Decides whether background work may run and how hard. Strictest condition wins.
#[must_use]
pub fn gate(user_paused: bool, settings: Settings, c: Conditions) -> Gate {
    if user_paused {
        return Gate::Hold(PauseReason::User);
    }
    if settings.index_only_on_power && c.on_battery {
        return Gate::Hold(PauseReason::Battery);
    }
    if matches!(c.thermal, Thermal::Serious | Thermal::Critical) {
        return Gate::Hold(PauseReason::Thermal);
    }
    if c.memory == MemoryPressure::Critical {
        return Gate::Hold(PauseReason::Memory);
    }
    let mut t = Throttle { max_batch: settings.max_batch.max(1), parallelism: settings.max_parallelism.max(1) };
    // Back off gently: smaller batches and fewer parallel decodes, never zero.
    if c.thermal == Thermal::Fair || c.memory == MemoryPressure::Warning || c.low_power_mode || c.on_battery {
        t.max_batch = (t.max_batch / 4).max(1);
        t.parallelism = (t.parallelism / 2).max(1);
    }
    if c.user_active {
        t.parallelism = t.parallelism.min(2);
    }
    Gate::Run(t)
}

/// Delay before retrying a transient failure: 2 s, 4 s, 8 s, … capped at one hour.
#[must_use]
pub fn backoff_ms(attempt: u32) -> i64 {
    let exp = attempt.saturating_sub(1).min(20);
    (2_000_i64 << exp).min(3_600_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(g: Gate) -> Throttle {
        match g {
            Gate::Run(t) => t,
            Gate::Hold(r) => panic!("expected to run, held for {r:?}"),
        }
    }

    #[test]
    fn calm_mac_runs_at_full_speed() {
        let t = run(gate(false, Settings::default(), Conditions::default()));
        assert_eq!(t, Throttle { max_batch: 32, parallelism: 4 });
    }

    #[test]
    fn user_pause_beats_everything() {
        assert_eq!(gate(true, Settings::default(), Conditions::default()), Gate::Hold(PauseReason::User));
    }

    #[test]
    fn index_only_on_power_holds_on_battery_only_when_enabled() {
        let c = Conditions { on_battery: true, ..Conditions::default() };
        let on = Settings { index_only_on_power: true, ..Settings::default() };
        assert_eq!(gate(false, on, c), Gate::Hold(PauseReason::Battery));
        assert!(matches!(gate(false, Settings::default(), c), Gate::Run(_)));
        // The default still eases off on battery.
        assert_eq!(run(gate(false, Settings::default(), c)), Throttle { max_batch: 8, parallelism: 2 });
    }

    #[test]
    fn heat_and_memory_hold_or_slow() {
        let hot = Conditions { thermal: Thermal::Serious, ..Conditions::default() };
        assert_eq!(gate(false, Settings::default(), hot), Gate::Hold(PauseReason::Thermal));
        let crit = Conditions { thermal: Thermal::Critical, ..Conditions::default() };
        assert_eq!(gate(false, Settings::default(), crit), Gate::Hold(PauseReason::Thermal));
        let mem = Conditions { memory: MemoryPressure::Critical, ..Conditions::default() };
        assert_eq!(gate(false, Settings::default(), mem), Gate::Hold(PauseReason::Memory));
        let warm = Conditions { thermal: Thermal::Fair, ..Conditions::default() };
        assert_eq!(run(gate(false, Settings::default(), warm)).parallelism, 2);
        let warn = Conditions { memory: MemoryPressure::Warning, ..Conditions::default() };
        assert_eq!(run(gate(false, Settings::default(), warn)).max_batch, 8);
    }

    #[test]
    fn user_activity_caps_parallelism_but_never_stops_work() {
        let c = Conditions { user_active: true, ..Conditions::default() };
        assert_eq!(run(gate(false, Settings::default(), c)).parallelism, 2);
        let one = Settings { max_parallelism: 1, ..Settings::default() };
        assert_eq!(run(gate(false, one, c)).parallelism, 1);
    }

    #[test]
    fn throttle_never_reaches_zero() {
        let tiny = Settings { max_batch: 1, max_parallelism: 1, index_only_on_power: false };
        let c = Conditions { on_battery: true, thermal: Thermal::Fair, memory: MemoryPressure::Warning, low_power_mode: true, user_active: true };
        assert_eq!(run(gate(false, tiny, c)), Throttle { max_batch: 1, parallelism: 1 });
    }

    #[test]
    fn backoff_grows_and_caps() {
        assert_eq!(backoff_ms(1), 2_000);
        assert_eq!(backoff_ms(2), 4_000);
        assert_eq!(backoff_ms(3), 8_000);
        assert_eq!(backoff_ms(40), 3_600_000);
        assert_eq!(backoff_ms(0), 2_000);
    }
}
