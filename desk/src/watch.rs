// File watching for the interactive board (WP-5).
//
// The board must track REAL fleet activity, not a timer. So it watches the files
// the fleet actually writes and reacts only when one changes:
//   - state/desk-model.json  the cache the app renders (the watcher refreshes it)
//   - state/                 status writes and other runtime signals between
//                            model refreshes
//   - data/backlog.md        the queue the captain reasons about
//
// It NEVER shells out to the tens-of-seconds projection - reacting means
// re-reading the cheap cache and cheap live files, exactly the Tier-1/Tier-2
// reads model.rs owns.
//
// TRANSPORT: a background thread turns raw change signals into ticks on an
// mpsc::Receiver<Tick> the main loop selects on. The debouncer (debounce.rs)
// coalesces a burst into one update; this module's only job is to DETECT change
// and fund the debouncer, cheaply and without missing a write.
//
// TWO backends, same Tick stream:
//   - inotify via the `notify` crate (the fast path on Linux).
//   - an mtime poll fallback for when inotify is unavailable (a filesystem
//     notify cannot watch - NFS, some containers - or the platform lacks it).
// The fallback is chosen automatically when the notify watcher cannot be built,
// and can be forced for testing with FM_DESK_WATCH_POLL=1. Either way the main
// loop sees the same Tick, so the rest of the app is backend-agnostic.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, SystemTime};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

// A single change signal. The payload is intentionally coarse: WP-5 reloads the
// whole (cheap) model on any watched change rather than trying to patch one row
// from a raw event, because the model.rs load is milliseconds and the ranking
// that decides a row's place lives in the lib, not the app. "Piecemeal update"
// is delivered by the DIFF against the preserved view state, not by parsing which
// byte changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tick;

pub struct Watch {
    rx: Receiver<Tick>,
    // Keep the notify watcher alive for the process lifetime; dropping it stops
    // the backend. None on the poll fallback.
    _watcher: Option<RecommendedWatcher>,
    // Join handle for the poll thread; None on the inotify path.
    _poll: Option<thread::JoinHandle<()>>,
    // Which backend is live. Read by tests and available for a later surface that
    // wants to tell the captain the board fell back to polling.
    #[allow(dead_code)]
    backend: Backend,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Inotify,
    Poll,
}

impl Watch {
    // start: begin watching the given roots. Chooses inotify unless it cannot be
    // built or the poll fallback is forced, then falls back to mtime polling.
    pub fn start(paths: WatchPaths) -> Watch {
        if std::env::var_os("FM_DESK_WATCH_POLL").is_some() {
            return Self::start_poll(paths);
        }
        match Self::start_inotify(&paths) {
            Some(w) => w,
            None => Self::start_poll(paths),
        }
    }

    #[allow(dead_code)]
    pub fn backend(&self) -> Backend {
        self.backend
    }
    // recv_timeout: block up to `dur` for the next change tick. Returns None on a
    // timeout (so the caller can still service the debouncer's own deadline) and
    // treats a disconnected sender as an endless timeout (the watcher thread died;
    // the app keeps running on whatever is on screen rather than crashing).
    pub fn recv_timeout(&self, dur: Duration) -> Option<Tick> {
        match self.rx.recv_timeout(dur) {
            Ok(t) => Some(t),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => {
                thread::sleep(dur);
                None
            }
        }
    }

    fn start_inotify(paths: &WatchPaths) -> Option<Watch> {
        let (tx, rx) = mpsc::channel::<Tick>();
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            // Any successful event is a coarse "something changed" tick; the
            // debouncer decides when to act. An error event is ignored (the poll
            // fallback is the safety net for a broken backend).
            if res.is_ok() {
                let _ = tx.send(Tick);
            }
        })
        .ok()?;

        // Watch each existing root. state/ is recursive so a write to any status
        // file under it ticks; the two files are watched directly. A path that
        // does not exist yet is skipped rather than failing the whole watcher -
        // the poll fallback would be needed only if EVERY watch failed.
        let mut watched_any = false;
        for (path, mode) in paths.entries() {
            if path.exists() && watcher.watch(&path, mode).is_ok() {
                watched_any = true;
            }
        }
        if !watched_any {
            return None;
        }
        Some(Watch {
            rx,
            _watcher: Some(watcher),
            _poll: None,
            backend: Backend::Inotify,
        })
    }

    fn start_poll(paths: WatchPaths) -> Watch {
        let (tx, rx) = mpsc::channel::<Tick>();
        let interval = poll_interval();
        let handle = thread::spawn(move || {
            let mut last = signature(&paths);
            loop {
                thread::sleep(interval);
                let now = signature(&paths);
                if now != last {
                    last = now;
                    if tx.send(Tick).is_err() {
                        return; // main loop gone; stop polling.
                    }
                }
            }
        });
        Watch {
            rx,
            _watcher: None,
            _poll: Some(handle),
            backend: Backend::Poll,
        }
    }
}

// The set of paths to watch, resolved once at startup.
#[derive(Debug, Clone)]
pub struct WatchPaths {
    pub state_dir: PathBuf,
    pub model_cache: PathBuf,
    pub data_dir: PathBuf,
    pub backlog: PathBuf,
}

impl WatchPaths {
    // entries: (path, recursive?) pairs for the inotify backend. Both state/ and
    // data/ are watched as dirs (state/ recursive, since it has many files) so a
    // create or atomic temp+rename of a file inside them still ticks even when the
    // bare-file watch is absent (file missing at startup) or stale (rename swapped
    // the inode); the cache and backlog are also watched directly.
    fn entries(&self) -> Vec<(PathBuf, RecursiveMode)> {
        vec![
            (self.state_dir.clone(), RecursiveMode::Recursive),
            (self.model_cache.clone(), RecursiveMode::NonRecursive),
            (self.data_dir.clone(), RecursiveMode::NonRecursive),
            (self.backlog.clone(), RecursiveMode::NonRecursive),
        ]
    }

    // files: the individual files whose mtime the poll fallback samples. state/ is
    // sampled as its own mtime plus each direct child's, so a status write under
    // it changes the signature without an expensive deep recursive walk on every
    // poll (status files live directly in state/).
    fn poll_targets(&self) -> Vec<PathBuf> {
        let mut t = vec![
            self.model_cache.clone(),
            self.backlog.clone(),
            self.state_dir.clone(),
        ];
        if let Ok(rd) = std::fs::read_dir(&self.state_dir) {
            for entry in rd.flatten() {
                t.push(entry.path());
            }
        }
        t
    }
}

// signature: a cheap fingerprint of the watched set. Concatenates (path, mtime,
// len) so a status write (mtime + size change), a model refresh (temp+rename
// changes mtime), a new status file (a new entry appears), or a removed file all
// shift the signature. A missing file contributes a stable sentinel so it
// appearing later registers as a change.
pub fn signature(paths: &WatchPaths) -> Vec<(PathBuf, u128, u64)> {
    let mut sig: Vec<(PathBuf, u128, u64)> = paths
        .poll_targets()
        .into_iter()
        .map(|p| {
            let (mtime, len) = match std::fs::metadata(&p) {
                Ok(m) => (mtime_nanos(&m), m.len()),
                Err(_) => (0, 0),
            };
            (p, mtime, len)
        })
        .collect();
    // read_dir order is not stable across platforms; sort so an unchanged
    // directory always produces the same signature.
    sig.sort();
    sig
}

fn mtime_nanos(meta: &std::fs::Metadata) -> u128 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// poll_interval: how often the fallback samples mtimes. Short enough that the
// board still feels live (a few hundred ms), overridable for tests.
fn poll_interval() -> Duration {
    std::env::var("FM_DESK_POLL_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or_else(|| Duration::from_millis(400))
}

// resolve_paths: the watched set for this home. Mirrors model.rs's cache
// resolution (FM_HOME/state or <root>/state) so the app watches exactly the file
// it reads. The backlog lives at <FM_HOME|root>/data/backlog.md.
pub fn resolve_paths(state_dir: PathBuf, root: Option<&Path>) -> WatchPaths {
    let model_cache = state_dir.join("desk-model.json");
    let data_dir = data_dir(&state_dir, root);
    let backlog = data_dir.join("backlog.md");
    WatchPaths {
        state_dir,
        model_cache,
        data_dir,
        backlog,
    }
}

// data_dir: sibling of state/. FM_HOME/data when set, else <root>/data, else the
// state dir's parent joined with data.
fn data_dir(state_dir: &Path, root: Option<&Path>) -> PathBuf {
    if let Ok(home) = std::env::var("FM_HOME") {
        if !home.is_empty() {
            return PathBuf::from(home).join("data");
        }
    }
    if let Some(r) = root {
        return r.join("data");
    }
    state_dir
        .parent()
        .map(|p| p.join("data"))
        .unwrap_or_else(|| PathBuf::from("data"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    fn tmp_home() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fm-desk-watch-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(d.join("state")).unwrap();
        fs::create_dir_all(d.join("data")).unwrap();
        d
    }

    fn paths_under(home: &Path) -> WatchPaths {
        resolve_paths(home.join("state"), Some(home))
    }

    #[test]
    fn signature_changes_when_a_status_file_is_written() {
        let home = tmp_home();
        let paths = paths_under(&home);
        let s0 = signature(&paths);
        // A brand-new status file under state/ must shift the signature.
        let mut f = fs::File::create(home.join("state/task-a.status")).unwrap();
        writeln!(f, "working: started").unwrap();
        f.sync_all().unwrap();
        let s1 = signature(&paths);
        assert_ne!(s0, s1, "a new status file must change the poll signature");
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn signature_changes_when_the_model_cache_is_refreshed() {
        let home = tmp_home();
        let paths = paths_under(&home);
        let cache = home.join("state/desk-model.json");
        fs::write(&cache, r#"{"now":"a"}"#).unwrap();
        let s0 = signature(&paths);
        // Append content so BOTH size and mtime change even at coarse mtime
        // resolution, mirroring a real temp+rename refresh.
        fs::write(&cache, r#"{"now":"b","extra":"grew"}"#).unwrap();
        let s1 = signature(&paths);
        assert_ne!(s0, s1, "a model refresh must change the poll signature");
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn signature_is_stable_when_nothing_changes() {
        let home = tmp_home();
        let paths = paths_under(&home);
        fs::write(home.join("state/x.status"), "working: a").unwrap();
        let s0 = signature(&paths);
        let s1 = signature(&paths);
        assert_eq!(s0, s1, "an unchanged tree must produce the same signature");
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn poll_backend_delivers_a_tick_on_a_real_write() {
        // Force the poll fallback with a fast interval, then prove a write ticks.
        std::env::set_var("FM_DESK_WATCH_POLL", "1");
        std::env::set_var("FM_DESK_POLL_MS", "30");
        let home = tmp_home();
        let paths = paths_under(&home);
        fs::write(home.join("state/desk-model.json"), r#"{"now":"a"}"#).unwrap();
        let watch = Watch::start(paths);
        assert_eq!(watch.backend(), Backend::Poll);
        // No change yet: a short wait times out.
        assert!(watch.recv_timeout(Duration::from_millis(90)).is_none());
        // Write a status file; the poller must deliver a tick.
        fs::write(home.join("state/task-b.status"), "working: go").unwrap();
        let got = watch.recv_timeout(Duration::from_millis(1500));
        std::env::remove_var("FM_DESK_WATCH_POLL");
        std::env::remove_var("FM_DESK_POLL_MS");
        let _ = fs::remove_dir_all(&home);
        assert_eq!(got, Some(Tick), "poll backend must tick on a real write");
    }

    #[test]
    fn resolve_paths_points_at_state_and_data_siblings() {
        let home = tmp_home();
        // Clear FM_HOME so root-based resolution is exercised deterministically.
        let saved = std::env::var("FM_HOME").ok();
        std::env::remove_var("FM_HOME");
        let paths = resolve_paths(home.join("state"), Some(&home));
        assert_eq!(paths.model_cache, home.join("state/desk-model.json"));
        assert_eq!(paths.backlog, home.join("data/backlog.md"));
        if let Some(v) = saved {
            std::env::set_var("FM_HOME", v);
        }
        let _ = fs::remove_dir_all(&home);
    }
}
