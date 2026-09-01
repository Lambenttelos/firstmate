// Debounce for file-change events (WP-5).
//
// The board reacts to file changes, but a single logical update - a burst of
// status writes, an atomic temp+rename of the model cache - fires MANY raw
// inotify events in a few milliseconds. Repainting on each would be the exact
// "repaint the world" churn WP-5 exists to avoid. So raw change signals are
// COALESCED here into at most one board update per quiet window.
//
// Two knobs, both needed:
//   - quiet:    fire once the stream has been silent this long (the common case:
//               a burst settles, then we update once).
//   - max_wait: never postpone longer than this since the FIRST pending event,
//               so a steady drip of writes still updates on a bounded cadence
//               instead of starving forever.
//
// This type is pure and clock-injected (every method takes `now`), so the whole
// coalescing policy is unit-tested with no real filesystem and no sleeping.

use std::time::{Duration, Instant};

pub struct Debouncer {
    quiet: Duration,
    max_wait: Duration,
    first_pending: Option<Instant>,
    last_event: Option<Instant>,
}

impl Debouncer {
    pub fn new(quiet: Duration, max_wait: Duration) -> Self {
        Debouncer {
            quiet,
            max_wait,
            first_pending: None,
            last_event: None,
        }
    }

    // record: a raw change signal arrived at `now`. Marks work pending and
    // restarts the quiet timer; the first record in a burst also starts the
    // max_wait clock.
    pub fn record(&mut self, now: Instant) {
        if self.first_pending.is_none() {
            self.first_pending = Some(now);
        }
        self.last_event = Some(now);
    }

    pub fn pending(&self) -> bool {
        self.first_pending.is_some()
    }

    // ready: is it time to fire? True when something is pending AND either the
    // stream has gone quiet for `quiet`, or `max_wait` has elapsed since the
    // first pending event (the anti-starvation cap).
    pub fn ready(&self, now: Instant) -> bool {
        let (Some(first), Some(last)) = (self.first_pending, self.last_event) else {
            return false;
        };
        now.duration_since(last) >= self.quiet || now.duration_since(first) >= self.max_wait
    }

    // take: clear the pending burst after firing an update.
    pub fn take(&mut self) {
        self.first_pending = None;
        self.last_event = None;
    }

    // wait_hint: how long the caller may sleep before it must re-check ready().
    // None when nothing is pending (the caller can wait on other work). When
    // pending, the shorter of "until quiet elapses" and "until max_wait elapses",
    // never negative, so the loop wakes exactly when a fire becomes due.
    pub fn wait_hint(&self, now: Instant) -> Option<Duration> {
        let (first, last) = (self.first_pending?, self.last_event?);
        let until_quiet = self
            .quiet
            .checked_sub(now.duration_since(last))
            .unwrap_or_default();
        let until_cap = self
            .max_wait
            .checked_sub(now.duration_since(first))
            .unwrap_or_default();
        Some(until_quiet.min(until_cap))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn a_burst_of_events_fires_exactly_once() {
        // quiet=150ms, cap=750ms. A burst of five writes 10ms apart is one update.
        let mut d = Debouncer::new(ms(150), ms(750));
        let t0 = Instant::now();
        for i in 0..5 {
            d.record(t0 + ms(i * 10));
        }
        // 40ms after the last event: still within the quiet window, do NOT fire.
        assert!(!d.ready(t0 + ms(40 + 40)));
        // 150ms after the last event (at t=40): quiet elapsed, fire once.
        let last = t0 + ms(40);
        assert!(d.ready(last + ms(150)));
        d.take();
        // After firing, nothing pending until a new event arrives.
        assert!(!d.pending());
        assert!(!d.ready(last + ms(10_000)));
    }

    #[test]
    fn quiet_window_restarts_on_each_event() {
        let mut d = Debouncer::new(ms(150), ms(750));
        let t0 = Instant::now();
        d.record(t0);
        // 100ms later, still quiet-pending, not ready.
        assert!(!d.ready(t0 + ms(100)));
        // A new event at 100ms restarts the quiet timer.
        d.record(t0 + ms(100));
        // 100ms after THAT (t=200 overall) is still within the restarted window.
        assert!(!d.ready(t0 + ms(200)));
        // 150ms after the last event (t=250) fires.
        assert!(d.ready(t0 + ms(250)));
    }

    #[test]
    fn max_wait_caps_a_steady_drip() {
        // A write every 100ms never lets the 150ms quiet window close, so the
        // 750ms cap is what forces an update.
        let mut d = Debouncer::new(ms(150), ms(750));
        let t0 = Instant::now();
        for i in 0..20 {
            let t = t0 + ms(i * 100);
            d.record(t);
            // Before the cap and within quiet: not ready.
            if i < 7 {
                assert!(!d.ready(t + ms(50)), "fired too early at drip {i}");
            }
        }
        // By 750ms after the first event, the cap forces readiness even though
        // events keep arriving.
        assert!(d.ready(t0 + ms(750)));
    }

    #[test]
    fn wait_hint_is_none_when_idle_and_bounded_when_pending() {
        let mut d = Debouncer::new(ms(150), ms(750));
        let t0 = Instant::now();
        assert!(d.wait_hint(t0).is_none());
        d.record(t0);
        // Right after an event, the hint is the full quiet window.
        assert_eq!(d.wait_hint(t0), Some(ms(150)));
        // Halfway through the quiet window, the hint shrinks.
        assert_eq!(d.wait_hint(t0 + ms(100)), Some(ms(50)));
        // Past due, the hint is zero (fire now), never negative.
        assert_eq!(d.wait_hint(t0 + ms(1000)), Some(ms(0)));
    }
}
