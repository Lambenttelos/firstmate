// fm-desk - the compiled TUI captain's desk.
//
// This crate is a CONSUMER of the fm-desk.v1 view model (bin/fm-desk-lib.sh owns
// that model; the app never builds a second projection). It contains NO LLM call
// anywhere - a hard captain constraint - and is read-only.
//
// DATA SOURCE (the load-bearing design point): the interactive path reads the
// CACHED model at state/desk-model.json (~8ms) and parses the fm-desk.v1 JSON in
// Rust. It NEVER shells out to the tens-of-seconds projection - that is exactly
// what the cache exists to avoid. A missing or stale cache is rendered honestly
// (a "data is N minutes old" or "cache not available yet" note), never a silent
// slow fallback. The projection shell-out survives only as an explicit non-interactive
// escape hatch on the static path when no cache exists (model::project_once).
//
// LIFECYCLE (from WP-2, preserved): enter an alternate-screen TUI, quit cleanly
// on q, degrade on a non-terminal, and ALWAYS restore the terminal - on normal
// exit, on panic, on SIGINT, and on SIGHUP (SSH disconnect). The loop also
// quits on its own when the input terminal hangs up (terminal_hung_up), since a
// signal alone cannot break crossterm's poll spin on a dead tty.
//
// WP-3 is render only: a static painted board of the real model. Navigation and
// drill-down are WP-4/6.
//
// WP-5 adds FILE WATCHING and piecemeal updates: the interactive loop now watches
// the files the fleet writes (the model cache, state/, data/backlog.md) and
// reloads the CHEAP cache on a debounced change instead of on a timer, so the
// board tracks real activity. It still NEVER shells out to the slow projection -
// a reload is the same millisecond cache read as startup. The captain's place
// (cursor by stable id + section folds) is preserved across every reload
// (nav::Nav::reload), and the honest data-age note (WP-3) keeps telling the truth
// until a refresh lands.

mod debounce;
mod detail;
mod model;
mod nav;
mod render;
mod watch;

use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossterm::{
    cursor::{Hide, Show},
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::Rect;
use ratatui::text::Text;
use ratatui::widgets::Paragraph;
use ratatui::{Frame, Terminal};

use debounce::Debouncer;
use model::{Loaded, Model};
use render::{line_plain_text, Painter};
use watch::{resolve_paths, Watch};

fn main() {
    // Non-interactive surfaces (a pipe, a redirect, TERM=dumb) must NOT take over
    // the terminal: print the static desk and exit, exactly like the existing
    // boards' non-tty fallback.
    if should_degrade() {
        std::process::exit(run_static());
    }

    if let Err(e) = run_interactive() {
        // The RAII guard restores on a normal return; make sure a mid-run error
        // also restores before we print, so the terminal is never left raw.
        restore_terminal();
        eprintln!("fm-desk: {e}");
        std::process::exit(1);
    }
}

// Degrade (defer to the static board) whenever this is not a real interactive
// terminal on both ends. A TUI needs a tty for input and output; TERM=dumb or an
// empty TERM cannot drive one either.
fn should_degrade() -> bool {
    let term = std::env::var("TERM").unwrap_or_default();
    !io::stdout().is_terminal() || !io::stdin().is_terminal() || term.is_empty() || term == "dumb"
}

// terminal_hung_up: true once the input terminal is gone (POLLHUP/POLLERR/
// POLLNVAL on stdin). crossterm reads keys from stdin when it is a tty (the
// interactive path guarantees that via should_degrade), so stdin is the fd that
// carries the hangup. A non-blocking libc::poll with a zero timeout: POLLHUP is
// reported in revents even though we only ask for POLLIN, so a torn-down pty is
// seen without ever entering crossterm's spinning event::poll. Any poll error
// (a closed or invalid fd) is itself treated as hung up - the safe direction is
// to quit, never to keep an orphan alive.
fn terminal_hung_up() -> bool {
    use std::os::unix::io::AsRawFd;
    let mut pfd = libc::pollfd {
        fd: io::stdin().as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // Zero timeout: this is a probe, not a wait. The loop's real blocking wait
    // is the watch recv above.
    let rc = unsafe { libc::poll(&mut pfd, 1, 0) };
    if rc < 0 {
        // poll itself failed (EBADF on a closed fd, etc.): treat as hung up.
        return true;
    }
    pfd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
}

// --- data source note -------------------------------------------------------
// staleness_note: the honest one-line footnote about the data source. A fresh
// cache (under the freshness window) needs no note. A stale cache says how old.
// The watcher's desk pass runs on a minutes cadence, so a few minutes is normal
// and only a clearly-old model is worth flagging. This window must exceed the
// watcher's worst-case healthy refresh age (DESK_REGEN_INTERVAL plus one persist,
// bin/fm-watch.sh), or a healthy refresh would falsely trip the note; that
// relation is enforced by tests/fm-watch-desk.test.sh.
const FRESH_SECS: i64 = 180; // under 3 minutes: no note

fn staleness_note(loaded: &Loaded) -> Option<String> {
    let age = loaded.age_secs?;
    if age < FRESH_SECS {
        return None;
    }
    Some(format!("data is {} old", humanize_age(age)))
}

// humanize_age: seconds -> a terse "N min"/"N h"/"N d" phrase.
fn humanize_age(secs: i64) -> String {
    let s = secs.max(0);
    if s < 90 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{} min", (s + 30) / 60)
    } else if s < 172_800 {
        format!("{} h", (s + 1800) / 3600)
    } else {
        format!("{} d", (s + 43_200) / 86_400)
    }
}

// A model to paint plus the note to show, resolving the cache-absent case into an
// honest empty board rather than a silent projection.
fn load_for_paint() -> (Model, Option<String>) {
    match model::load() {
        Ok(loaded) => {
            let note = staleness_note(&loaded);
            (loaded.model, note)
        }
        Err(e) => (empty_model(), Some(format!("live data not available: {e}"))),
    }
}

// empty_model: a minimal well-formed model so the board still paints its chrome
// (and the note) when the cache is absent, instead of a blank screen.
fn empty_model() -> Model {
    model::parse(
        r#"{"now":"","header":{"summary":"Fleet data is not available yet."},
            "health":{"beat_age_seconds":null},"sections":{}}"#,
    )
    .expect("built-in empty model is valid")
}

// --- static (non-tty) path --------------------------------------------------
// Print one plain-text frame and exit, touching NO terminal modes. Prefers the
// cache (fast, no projection); only when no cache exists does it use the explicit
// projection escape hatch so a fresh home still shows real state on a pipe.
fn run_static() -> i32 {
    let (model, note) = match model::load() {
        Ok(loaded) => {
            let note = staleness_note(&loaded);
            (loaded.model, note)
        }
        Err(_) => match model::project_once() {
            Ok(text) => match model::parse(&text) {
                Ok(m) => (m, None),
                Err(e) => {
                    eprintln!("fm-desk: {e}");
                    return 1;
                }
            },
            Err(e) => {
                // No cache and no projection: still print an honest board.
                (empty_model(), Some(format!("live data not available: {e}")))
            }
        },
    };
    let cols = std::env::var("FM_DESK_TUI_COLS")
        .ok()
        .and_then(|v| v.parse::<u16>().ok())
        .unwrap_or(80);
    // A pipe/redirect gets plain deterministic text (no color). When the caller
    // bounds the height (FM_DESK_TUI_ROWS), use WP-3's vertical fit so the static
    // board never overflows that budget; otherwise the fixed per-section cap keeps
    // it terse. This is the same width/height guarantee the interactive board
    // holds, on the non-tty path.
    let rows = std::env::var("FM_DESK_TUI_ROWS")
        .ok()
        .and_then(|v| v.parse::<u16>().ok());
    let painter = match rows {
        Some(h) => Painter::with_rows(cols, false, h),
        None => Painter::new(cols, false),
    };
    let mut out = io::stdout();
    for line in painter.frame(&model, note.as_deref()) {
        let _ = writeln!(out, "{}", line_plain_text(&line));
    }
    let _ = out.flush();
    0
}

// --- interactive path -------------------------------------------------------
fn run_interactive() -> io::Result<()> {
    install_panic_hook();

    // SIGINT, SIGHUP (SSH disconnect), and SIGTERM set a quit flag rather than
    // killing the process, so the loop breaks and the RAII guard restores the
    // terminal as the stack unwinds. In raw mode the terminal driver no longer
    // turns Ctrl-C into SIGINT, so we also treat Ctrl-C as a quit key below.
    let quit = Arc::new(AtomicBool::new(false));
    for sig in [
        signal_hook::consts::SIGINT,
        signal_hook::consts::SIGHUP,
        signal_hook::consts::SIGTERM,
    ] {
        signal_hook::flag::register(sig, Arc::clone(&quit))?;
    }

    // Load the model ONCE at startup from the cache (fast, no projection). WP-5
    // reloads this same cheap source on a debounced file change, never on a timer;
    // WP-4's App navigates and drills into whatever model is currently loaded.
    let (mut model, note) = load_for_paint();
    let mut app = App::new(&model, note);

    // Watch the files the fleet writes (the cache, state/, data/backlog.md) and
    // coalesce a burst of writes into one reload. inotify with an mtime-poll
    // fallback; both feed the same tick stream.
    let paths = resolve_paths(
        model::state_dir_for_watch(),
        model::repo_root_for_watch().as_deref(),
    );
    let watch = Watch::start(paths);
    let mut debouncer = Debouncer::new(debounce_quiet(), debounce_max());

    let _guard = TerminalGuard::enter()?;
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = Terminal::new(backend)?;

    // Test seam: panic AFTER entering raw mode + the alternate screen, to prove
    // the panic hook restores the terminal. Never set in normal use.
    if std::env::var_os("FM_DESK_PANIC_TEST").is_some() {
        panic!("FM_DESK_PANIC_TEST: forced panic to exercise the restore hook");
    }

    // Paint once up front so the board is on screen before the first event.
    terminal.draw(|f| app.draw(f, &model))?;

    loop {
        if quit.load(Ordering::Relaxed) {
            break;
        }

        // How long we may block: a keypress or a watch tick, but never longer
        // than the debouncer's own deadline when an update is pending, so a
        // settled burst fires promptly even with no further events.
        let now = Instant::now();
        let block = debouncer
            .wait_hint(now)
            .unwrap_or_else(|| Duration::from_millis(250))
            .min(Duration::from_millis(250));

        // 1. A file change: fund the debouncer, but do NOT reload yet (a burst
        //    keeps arriving). The reload happens when the debouncer says quiet.
        if watch.recv_timeout(block).is_some() {
            debouncer.record(Instant::now());
        }

        // 2. A settled burst: reload the CHEAP cache and reconcile the captain's
        //    place onto the new model. This is the piecemeal update - the model
        //    swaps, but the captain's place (cursor by stable id + section folds)
        //    survives, so a background update never yanks the cursor (App::reload).
        if debouncer.pending() && debouncer.ready(Instant::now()) {
            debouncer.take();
            // Capture the captain's place by SECTION + stable id against the OLD
            // model BEFORE swapping, so reload can keep the cursor on the same task
            // even when re-ranking moves it to a different slot - and, crucially,
            // on the same SECTION so a duplicate id elsewhere (a promotion in
            // flight) never steals the cursor.
            let prev_place = app.selected_place(&model);
            let (new_model, new_note) = load_for_paint();
            let prev = prev_place.as_ref().map(|(k, id)| (*k, id.as_str()));
            app.reload(prev, &new_model, new_note);
            model = new_model;
            terminal.draw(|f| app.draw(f, &model))?;
        }

        // 3. Keys. A short poll so a signal that set the quit flag also wakes the
        //    loop promptly even when nothing else happens.
        //
        // HANGUP GUARD (the structural fix for the validation-run orphan leak):
        // when the controlling terminal is torn down (a validation worktree is
        // deleted, an SSH pty drops), the input fd goes to POLLHUP. crossterm's
        // event::poll busy-loops at 100% CPU on that dead fd, and the SIGHUP/
        // SIGTERM handlers are installed with SA_RESTART, so a signal cannot
        // break that spin - which is exactly why the leaked desks ignored
        // SIGTERM. Detect the hangup ourselves BEFORE calling event::poll and
        // quit, so no run can leave an interactive desk spinning as an orphan.
        // This lives at the loop's own poll point, not in a cleanup a future
        // test could skip.
        //
        // Test seam: FM_DESK_DISABLE_HANGUP_GUARD skips the guard so a test can
        // prove, on the SAME binary, that the orphan returns without it and is
        // gone with it (a break-and-restore of the guard). Never set in normal
        // use, exactly like FM_DESK_PANIC_TEST above.
        if std::env::var_os("FM_DESK_DISABLE_HANGUP_GUARD").is_none() && terminal_hung_up() {
            break;
        }
        if event::poll(Duration::from_millis(0))? {
            if let Event::Key(key) = event::read()? {
                match app.handle_key(key, &model) {
                    Flow::Quit => break,
                    Flow::RunSwitch(email) => {
                        // Suspend the TUI, run the switch helper on a normal
                        // screen so its output and any prompt are visible, then
                        // restore the alternate screen and report the result.
                        let result = run_switch_suspended(&mut terminal, &email);
                        app.finish_switch(&email, result);
                    }
                    Flow::Continue => {}
                }
            }
            // Repaint after a key so navigation, folds, and drill-down are
            // reflected immediately (the reload path repaints on its own tick).
            terminal.draw(|f| app.draw(f, &model))?;
        }
    }
    Ok(())
    // _guard Drop restores the terminal here.
}

// SWITCH_PLANE: the credential plane the desk's `w` switch acts on. `jcode`
// targets ~/.jcode/auth.json alone, the plane the fleet actually runs on. See
// run_switch_suspended for the WHY, and bin/fm-claude-switch.sh --help for the
// full flag contract (`--plane both|cswap|jcode`).
const SWITCH_PLANE: &str = "jcode";

// Debounce tuning. A quiet window long enough to coalesce a burst of status
// writes, and a cap so a steady drip still updates on a bounded cadence. Both
// overridable for tests and for a captain who wants a snappier or calmer board.
fn debounce_quiet() -> Duration {
    env_ms("FM_DESK_DEBOUNCE_MS", 200)
}
fn debounce_max() -> Duration {
    env_ms("FM_DESK_DEBOUNCE_MAX_MS", 1000)
}
fn env_ms(key: &str, default: u64) -> Duration {
    Duration::from_millis(
        std::env::var(key)
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(default),
    )
}

// Which overlay is on top. The board is the terse main view; detail is the
// on-demand drill-down of one item's underlying file; help is the ? overlay;
// switch is the two-phase global-account picker (w); cost is the spend and
// efficiency drill-down ($).
enum View {
    Board,
    Detail(detail::Detail, usize), // loaded file + scroll offset
    Help,
    Switch(SwitchState),
    // The spend/efficiency drill-down: the model's pre-rendered cost detail lines
    // plus a scroll offset. Carries its own copy of the lines so a background model
    // reload cannot yank the body out from under a captain who is reading it.
    Cost(Vec<String>, usize),
}

// The switch overlay's own state. Pick lists the accounts; once one is chosen it
// moves to Confirm(email); after a successful switch it moves to Applied(email),
// which is where the restart-to-apply affordance is shown; a status message
// reports an in-progress or failed switch. The chosen account carries the email
// (the stable key both stores share) and its display line.
struct SwitchState {
    // (key label shown, email, display line) for each pickable account.
    entries: Vec<(String, String, String)>,
    // Some(email) once the captain picked an account and must confirm.
    confirm: Option<String>,
    // Some(email) once the switch succeeded. The overlay STAYS open in this
    // phase so the captain cannot miss that a running session keeps its old
    // account until it restarts.
    applied: Option<String>,
    // A transient message (an error, or "switching...").
    status: Option<String>,
}

impl SwitchState {
    // Build the pick list from the model's accounts block. Each account gets a
    // 1-based number key. Returns None when the model carries no accounts (the
    // overlay then shows a plain "no accounts to switch" note).
    fn from_model(model: &Model) -> Self {
        let mut entries = Vec::new();
        if let Some(a) = &model.header.accounts {
            for (i, acct) in a.accounts.iter().enumerate() {
                let email = acct
                    .get("email")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if email.is_empty() {
                    continue;
                }
                // Prefer the pre-rendered compact line; fall back to the email.
                let line = a.lines.get(i).cloned().unwrap_or_else(|| email.clone());
                entries.push(((i + 1).to_string(), email, line));
            }
        }
        SwitchState {
            entries,
            confirm: None,
            applied: None,
            status: None,
        }
    }

    // The (key, line) pairs the render frame paints.
    fn render_entries(&self) -> Vec<(String, String)> {
        self.entries
            .iter()
            .map(|(k, _e, l)| (k.clone(), l.clone()))
            .collect()
    }
}

#[derive(PartialEq, Eq)]
enum Flow {
    Continue,
    Quit,
    // The captain confirmed a switch: the run loop suspends the terminal, runs
    // the switch helper, and reports the result. Carries the target email.
    RunSwitch(String),
}

// App: the whole interactive state - the navigation model, the current overlay,
// and the last painted height (so detail scrolling knows the page size). It owns
// no terminal state; run_interactive drives it and the RAII guard restores.
struct App {
    nav: nav::Nav,
    view: View,
    note: Option<String>,
    height: u16,
    // Last painted pane width, so an overlay's scroll clamp uses the SAME wrapped
    // row count the paint produced (wrapping is width-dependent). Detail and cost
    // scroll count wrapped rows, not raw source lines.
    width: u16,
}

impl App {
    fn new(model: &Model, note: Option<String>) -> Self {
        App {
            nav: nav::Nav::new(model),
            view: View::Board,
            note,
            height: 24,
            width: 80,
        }
    }

    fn draw(&mut self, frame: &mut Frame, model: &Model) {
        let area: Rect = frame.area();
        self.height = area.height;
        self.width = area.width;
        let color = supports_color();
        let painter = Painter::new(area.width, color);
        let lines = match &self.view {
            View::Board => {
                // The nav board is fully navigable, so instead of WP-3's static
                // vertical-fit cap it uses a cursor-following viewport: paint the
                // whole board, then slice a window of `height` lines that keeps the
                // selected line on screen. This preserves WP-3's "never overflow the
                // pane" guarantee for the interactive view while letting the cursor
                // reach every item, even those below the first screenful.
                let full = painter.nav_frame(model, &self.nav, self.note.as_deref());
                viewport(full, area.height)
            }
            View::Detail(d, scroll) => {
                painter.detail_frame(&d.title, &d.body, *scroll, area.height)
            }
            View::Help => painter.help_frame(),
            View::Switch(s) => painter.switch_frame(
                &s.render_entries(),
                s.confirm.as_deref(),
                s.applied.as_deref(),
                s.status.as_deref(),
            ),
            View::Cost(detail, scroll) => painter.cost_frame(detail, *scroll, area.height),
        };
        let para = Paragraph::new(Text::from(lines));
        frame.render_widget(para, area);
    }

    // handle_key: the ONE key dispatcher. q and Ctrl-C ALWAYS quit from any view.
    // Otherwise keys are routed by the active overlay. Returns Flow::Quit to break
    // the loop (the guard then restores the terminal).
    fn handle_key(&mut self, key: KeyEvent, model: &Model) -> Flow {
        // Quit that always works, from any view.
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            return Flow::Quit;
        }
        if matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q')) {
            return Flow::Quit;
        }
        match &mut self.view {
            View::Help => {
                // Any of ?, Esc closes help; other keys are swallowed.
                if matches!(key.code, KeyCode::Char('?') | KeyCode::Esc) {
                    self.view = View::Board;
                }
                Flow::Continue
            }
            View::Detail(d, scroll) => {
                // The stored offset is clamped to the last full page so it never
                // runs past the body; detail_frame paints (height - 3) WRAPPED body
                // rows. Wrapping is width-dependent, so count wrapped rows at the
                // last painted width, not raw source lines - otherwise j/k could
                // not reach text that only exists because it wrapped.
                let page = (self.height as usize).saturating_sub(3).max(1);
                let painter = Painter::new(self.width, supports_color());
                let total = painter.detail_wrapped_len(&d.body);
                let max_scroll = total.saturating_sub(page);
                let jump = self.height.saturating_sub(4).max(1) as usize;
                match key.code {
                    KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => self.view = View::Board,
                    KeyCode::Char('?') => self.view = View::Help,
                    KeyCode::Down | KeyCode::Char('j') => *scroll = (*scroll + 1).min(max_scroll),
                    KeyCode::Up | KeyCode::Char('k') => *scroll = scroll.saturating_sub(1),
                    KeyCode::Char('g') | KeyCode::Home => *scroll = 0,
                    KeyCode::PageDown => *scroll = (*scroll + jump).min(max_scroll),
                    KeyCode::PageUp => *scroll = scroll.saturating_sub(jump),
                    _ => {}
                }
                Flow::Continue
            }
            View::Switch(_) => self.handle_switch_key(key),
            View::Cost(detail, scroll) => {
                // Same scroll model as Detail: the offset is clamped to the last
                // full page of WRAPPED rows. Esc or $ closes back to the board; ?
                // opens help.
                let page = (self.height as usize).saturating_sub(3).max(1);
                let painter = Painter::new(self.width, supports_color());
                let total = painter.cost_wrapped_len(detail);
                let max_scroll = total.saturating_sub(page);
                let jump = self.height.saturating_sub(4).max(1) as usize;
                match key.code {
                    KeyCode::Esc | KeyCode::Char('$') | KeyCode::Char('h') | KeyCode::Left => {
                        self.view = View::Board
                    }
                    KeyCode::Char('?') => self.view = View::Help,
                    KeyCode::Down | KeyCode::Char('j') => *scroll = (*scroll + 1).min(max_scroll),
                    KeyCode::Up | KeyCode::Char('k') => *scroll = scroll.saturating_sub(1),
                    KeyCode::Char('g') | KeyCode::Home => *scroll = 0,
                    KeyCode::PageDown => *scroll = (*scroll + jump).min(max_scroll),
                    KeyCode::PageUp => *scroll = scroll.saturating_sub(jump),
                    _ => {}
                }
                Flow::Continue
            }
            View::Board => {
                self.handle_board_key(key, model);
                Flow::Continue
            }
        }
    }

    // handle_switch_key: drive the three-phase account switch overlay. Pick
    // phase: a number selects an account and moves to Confirm; Esc cancels.
    // Confirm phase: y returns Flow::RunSwitch (the run loop suspends the
    // terminal and runs the helper); n/Esc goes back to the pick list. Applied
    // phase: any key closes the overlay, so the restart-to-apply notice is
    // dismissed deliberately rather than painted over by the next repaint. This
    // never shells out itself - the run loop owns the terminal, so it owns the
    // suspend/run/restore.
    fn handle_switch_key(&mut self, key: KeyEvent) -> Flow {
        let View::Switch(s) = &mut self.view else {
            return Flow::Continue;
        };
        if s.applied.is_some() {
            // Any key acknowledges the restart notice and returns to the board.
            let _ = key;
            self.view = View::Board;
            return Flow::Continue;
        }
        if s.confirm.is_some() {
            match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    if let Some(email) = s.confirm.clone() {
                        return Flow::RunSwitch(email);
                    }
                }
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') => {
                    s.confirm = None;
                    s.status = None;
                }
                _ => {}
            }
            return Flow::Continue;
        }
        match key.code {
            KeyCode::Esc => self.view = View::Board,
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let pick = c.to_string();
                if let Some((_k, email, _l)) = s.entries.iter().find(|(k, _e, _l)| *k == pick) {
                    s.confirm = Some(email.clone());
                }
            }
            _ => {}
        }
        Flow::Continue
    }

    fn handle_board_key(&mut self, key: KeyEvent, model: &Model) {
        match key.code {
            KeyCode::Char('?') => self.view = View::Help,
            KeyCode::Down | KeyCode::Char('j') => self.nav.move_down(),
            KeyCode::Up | KeyCode::Char('k') => self.nav.move_up(),
            KeyCode::Char('g') | KeyCode::Home => self.nav.move_first(),
            KeyCode::Char('G') | KeyCode::End => self.nav.move_last(),
            KeyCode::Tab | KeyCode::Char(']') => self.nav.next_section(),
            KeyCode::BackTab | KeyCode::Char('[') => self.nav.prev_section(),
            // Expand/collapse the section under the cursor.
            KeyCode::Char(' ') | KeyCode::Char('h') | KeyCode::Left => self.nav.toggle_fold(model),
            // Open the item's underlying file on demand (drill-down).
            KeyCode::Enter | KeyCode::Char('l') | KeyCode::Right => self.open_selected(model),
            // Single-key section shortcuts (c u a d m s).
            KeyCode::Char('c') => {
                self.nav.jump_to(model::SectionKind::CaptainsCall);
            }
            KeyCode::Char('u') => {
                self.nav.jump_to(model::SectionKind::UnderWay);
            }
            KeyCode::Char('a') => {
                self.nav.jump_to(model::SectionKind::Charted);
            }
            KeyCode::Char('d') => {
                self.nav.jump_to(model::SectionKind::Landed);
            }
            KeyCode::Char('m') => {
                self.nav.jump_to(model::SectionKind::Merge);
            }
            KeyCode::Char('s') => {
                self.nav.jump_to(model::SectionKind::Secondmates);
            }
            // Open the global-account switch overlay (w). No accounts in the model
            // still opens it, showing an honest "no accounts to switch" note.
            KeyCode::Char('w') | KeyCode::Char('W') => {
                self.view = View::Switch(SwitchState::from_model(model));
            }
            // Open the spend/efficiency drill-down ($). The body is the model's
            // pre-rendered cost detail; with no cost data the overlay still opens
            // and says so honestly rather than pretending the key does nothing.
            KeyCode::Char('$') => {
                let detail = model
                    .header
                    .token_cost
                    .as_ref()
                    .map(|t| t.detail.clone())
                    .filter(|d| !d.is_empty())
                    .unwrap_or_else(|| {
                        vec!["Spend and efficiency figures are not available right now.".to_string()]
                    });
                self.view = View::Cost(detail, 0);
            }
            _ => {}
        }
    }

    // finish_switch: report the switch result back into the overlay. Ok moves the
    // overlay to the Applied phase and KEEPS it open, because a jcode-plane
    // switch edits ~/.jcode/auth.json and cannot reach an already-live session:
    // the captain must see the restart-to-apply notice rather than a silent
    // return to the board. Err stays in the overlay with the error so the captain
    // sees exactly what failed. The confirm flag is cleared either way.
    fn finish_switch(&mut self, email: &str, result: Result<(), String>) {
        let View::Switch(s) = &mut self.view else {
            self.view = View::Board;
            return;
        };
        s.confirm = None;
        match result {
            Ok(()) => {
                s.applied = Some(email.to_string());
                s.status = None;
            }
            Err(e) => s.status = Some(format!("switch failed: {e}")),
        }
    }

    // open_selected: the drill-down. Reads the ONE underlying file for the row at
    // the cursor at THIS moment (never pre-loaded), and shows it in the detail
    // overlay. A header (no openable row) is a no-op.
    fn open_selected(&mut self, model: &Model) {
        if let Some((kind, row)) = self.nav.selected_row(model) {
            let d = detail::open(kind, row);
            self.view = View::Detail(d, 0);
        }
    }

    // reload: fold a freshly loaded model into the running app (WP-5). The whole
    // point is that a background update must NOT move the captain's place: nav
    // keeps the section folds (they are keyed by SectionKind, untouched here) and
    // rebuilds the flattened list while preserving the selected ITEM by its stable
    // row id, so re-ranking never yanks the cursor to the top. The honest data-age
    // note is refreshed so staleness keeps telling the truth. An open drill-down or
    // help overlay is left as it is - the captain is reading it - and the board
    // beneath it reflects the new model the next time it is shown.
    fn reload(&mut self, prev: Option<(model::SectionKind, &str)>, model: &Model, note: Option<String>) {
        self.note = note;
        self.nav.reload(model, prev);
    }

    // selected_id: the stable id of the row under the cursor against `model`.
    // Superseded by selected_place for reload (which re-anchors by SECTION + id);
    // retained as the id-only accessor.
    #[allow(dead_code)]
    fn selected_id(&self, model: &Model) -> Option<String> {
        self.nav.selected_id(model)
    }

    // selected_place: the section + stable id under the cursor, captured before a
    // reload so the cursor re-anchors on the SAME row in the SAME section.
    fn selected_place(&self, model: &Model) -> Option<(model::SectionKind, String)> {
        self.nav.selected_place(model)
    }
}

// supports_color: color only on a real terminal that is not TERM=dumb. ratatui
// keeps style separate from text, so painted width is identical with or without.
fn supports_color() -> bool {
    let term = std::env::var("TERM").unwrap_or_default();
    io::stdout().is_terminal() && !term.is_empty() && term != "dumb"
}

// viewport: slice a full painted board down to a window of `height` lines that
// keeps the SELECTED line on screen, so the cursor is always visible even when it
// moves past the first screenful. This is the navigable analog of WP-3's static
// vertical fit: the static board caps rows to the pane, while the interactive
// board keeps every row reachable but shows only a pane-height window around the
// cursor - either way no painted frame exceeds the pane height (no overflow).
//
// The selected line is the one carrying the "> " selection gutter (render's
// with_gutter is the one owner of that marker). When nothing is selected, or the
// board already fits, the top of the board is shown.
fn viewport(
    lines: Vec<ratatui::text::Line<'static>>,
    height: u16,
) -> Vec<ratatui::text::Line<'static>> {
    let h = height as usize;
    if h == 0 || lines.len() <= h {
        return lines;
    }
    let sel = lines
        .iter()
        .position(|l| line_plain_text(l).starts_with("> "));
    let Some(sel) = sel else {
        // No cursor on screen: show the top screenful.
        return lines.into_iter().take(h).collect();
    };
    // Center the selected line in the window where possible, then clamp so the
    // window never runs past either end of the board.
    let half = h / 2;
    let start = sel.saturating_sub(half).min(lines.len().saturating_sub(h));
    lines.into_iter().skip(start).take(h).collect()
}

// --- terminal restore (from WP-2, unchanged) --------------------------------
// Restore the terminal to a sane state. Idempotent and best-effort: it is called
// from the RAII guard's Drop, the panic hook, and the mid-run error path, and
// each step ignores its own failure (a dropped SSH pty makes writes fail, which
// is fine - we just want to undo whatever modes we set).
fn restore_terminal() {
    let mut out = io::stdout();
    let _ = execute!(out, LeaveAlternateScreen, Show);
    let _ = disable_raw_mode();
    let _ = out.flush();
}

// run_switch_suspended: leave the TUI, run the switch helper on a normal screen
// (so the captain sees its output and any prompt), then re-enter the alternate
// screen. The helper (bin/fm-claude-switch.sh) owns the actual credential change;
// this crate never edits a credential file itself and never touches a token.
// Returns Ok on a zero exit, else the captured message.
//
// PLANE: the desk targets the jcode plane alone (`--plane jcode`, which rewrites
// ~/.jcode/auth.json). Captain decision 2026-08-25: the fleet runs 100% on that
// plane, so switching the Claude Code plane from this button would act on a store
// the fleet does not use. cswap-auto still serves the Claude Code plane for the
// no-mistakes claude CLI; that is a separate path, not this button.
//
// FM_DESK_SWITCH_CMD overrides the command for tests (it receives the email as a
// single argument, then the plane flag), so this path is exercised without
// touching real credentials.
fn run_switch_suspended(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    email: &str,
) -> Result<(), String> {
    use std::process::Command;
    // Suspend: leave the alternate screen and raw mode so the child has a normal
    // terminal. We re-enter unconditionally afterwards.
    let _ = execute!(io::stdout(), LeaveAlternateScreen, Show);
    let _ = disable_raw_mode();

    let result = (|| {
        let mut cmd = if let Ok(override_cmd) = std::env::var("FM_DESK_SWITCH_CMD") {
            let mut c = Command::new("sh");
            c.arg("-c")
                .arg(format!("{override_cmd} \"$1\" \"$2\" \"$3\""))
                .arg("_")
                .arg(email)
                .arg("--plane")
                .arg(SWITCH_PLANE);
            c
        } else {
            let script = switch_script_path()
                .ok_or_else(|| "could not locate bin/fm-claude-switch.sh".to_string())?;
            let mut c = Command::new(&script);
            c.arg(email).arg("--plane").arg(SWITCH_PLANE);
            c
        };
        let status = cmd
            .status()
            .map_err(|e| format!("could not run the switch helper: {e}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!(
                "the switch helper exited with status {}",
                status.code().unwrap_or(-1)
            ))
        }
    })();

    // Re-enter the TUI regardless of the switch outcome.
    let _ = enable_raw_mode();
    let _ = execute!(io::stdout(), EnterAlternateScreen, Hide);
    let _ = terminal.clear();
    result
}

// switch_script_path: bin/fm-claude-switch.sh next to this repo's bin/. Resolved
// the same way model::repo_root finds bin/fm-desk-lib.sh, so the app finds its
// sibling helper regardless of the working directory.
fn switch_script_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent();
    while let Some(d) = dir {
        let cand = d.join("bin/fm-claude-switch.sh");
        if cand.is_file() {
            return Some(cand);
        }
        dir = d.parent();
    }
    None
}

// Leave the panic message readable: restore the terminal FIRST, then run the
// default hook so the backtrace prints on a normal screen, not over the TUI.
fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_terminal();
        default_hook(info);
    }));
}

struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> io::Result<Self> {
        enable_raw_mode()?;
        let mut out = io::stdout();
        execute!(out, EnterAlternateScreen, Hide)?;
        Ok(TerminalGuard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        restore_terminal();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Line;

    // Build a fake painted board of `n` lines, with the selection gutter on the
    // line at `sel` (mirroring render's "> " marker), so viewport() can be tested
    // without a real Painter.
    fn board(n: usize, sel: Option<usize>) -> Vec<Line<'static>> {
        (0..n)
            .map(|i| {
                let prefix = if Some(i) == sel { "> " } else { "  " };
                Line::from(format!("{prefix}row {i}"))
            })
            .collect()
    }

    #[test]
    fn viewport_never_exceeds_the_pane_height() {
        for &h in &[1u16, 5, 10, 24] {
            for sel in [None, Some(0usize), Some(20), Some(49)] {
                let win = viewport(board(50, sel), h);
                assert!(
                    win.len() <= h as usize,
                    "viewport painted {} lines into a {h}-row pane",
                    win.len()
                );
            }
        }
    }

    #[test]
    fn viewport_keeps_the_selected_line_on_screen() {
        // A selection near the bottom must still appear in the window.
        let win = viewport(board(50, Some(45)), 10);
        let has_sel = win.iter().any(|l| line_plain_text(l).starts_with("> "));
        assert!(
            has_sel,
            "the selected line must remain visible when it scrolls off the top"
        );
    }

    #[test]
    fn viewport_returns_the_whole_board_when_it_already_fits() {
        let full = board(8, Some(3));
        let win = viewport(full.clone(), 24);
        assert_eq!(win.len(), full.len(), "a fitting board is shown whole");
    }

    #[test]
    fn humanize_age_reads_naturally() {
        assert_eq!(humanize_age(10), "10s");
        assert_eq!(humanize_age(120), "2 min");
        assert_eq!(humanize_age(3600), "1 h");
        assert_eq!(humanize_age(180_000), "2 d");
    }

    #[test]
    fn fresh_cache_needs_no_note() {
        let loaded = Loaded {
            model: empty_model(),
            source: model::Source::Cache,
            age_secs: Some(30),
        };
        assert!(staleness_note(&loaded).is_none());
    }

    #[test]
    fn stale_cache_gets_an_honest_note() {
        let loaded = Loaded {
            model: empty_model(),
            source: model::Source::Cache,
            age_secs: Some(1200),
        };
        let note = staleness_note(&loaded).unwrap();
        assert!(note.contains("data is"), "note: {note}");
        assert!(note.contains("min"), "note: {note}");
    }
}
