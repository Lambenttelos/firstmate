// Drill-down (Tier 3): read the ONE underlying file for the opened item, at the
// moment it is opened. This is plain on-demand file reading, never a projection
// and never an LLM call. Nothing here is pre-loaded: main.rs calls open() only
// when the captain presses Enter on a row, and the result is dropped when the
// detail view closes.
//
// The whole point of WP-4: the main board stays terse BECAUSE the real detail -
// a task brief, a decision record, a scout report, a full status log - is one
// keystroke away in its own view, read live from firstmate's own files.
//
// The body is the primary record for the row, and small enrichment sections are
// appended after it so opening a row answers "what happened here" without leaving
// the board. The enrichment is still just on-demand file reads under base_dir():
//   - a task row also gets its state/<id>.status wake-event timeline;
//   - a decision row gets the folded keyed open-decision trail (via the ONE owner
//     of that grammar, bin/fm-classify-lib.sh, shelled for one file only);
//   - a landed/scout row prefers data/<id>/report.md as its body (it survives
//     teardown and is the deliverable the captain wants);
//   - a merge/landed row shows the locally-recorded compare URL and pr=/pr_head=
//     from state/<id>.meta - LOCAL reads only, never a live gh/CI call;
//   - every row gets a compact footer line of meta fields when meta exists.
// None of this touches the fold, the model schema, or fm-desk-lib.sh, and none of
// it makes a network call on the interactive path.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::model::{base_dir, repo_root_for_watch, str_field, SectionKind};
use crate::nav::row_id;

// A resolved drill-down target: the human label for the view title, and the file
// to read. Kept separate from the read so the resolver is pure and testable
// without a filesystem.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub title: String,
    pub path: PathBuf,
}

// The loaded detail: the resolved target plus the file body (or an honest
// not-found / unreadable message). Never partial - a missing file yields a clear
// note, not a blank pane.
pub struct Detail {
    pub title: String,
    // The resolved path, kept for a future footer/diagnostics; not painted yet.
    #[allow(dead_code)]
    pub path: PathBuf,
    pub body: String,
}

// A hard cap on how much of a file we hold, so a runaway status log or a huge
// decision record cannot blow up memory or the render. The detail view scrolls
// within this; a truncation is marked honestly.
const MAX_BYTES: usize = 256 * 1024;

// The honest marker appended when a capped read dropped the tail of a file, so a
// reader always knows the view holds a prefix rather than the whole file.
const TRUNCATION_NOTE: &str = "\n\n[... truncated: file is larger than the detail view holds ...]";

// read_capped: read a file holding at most MAX_BYTES of it, so neither the primary
// body nor an appended enrichment block can pull a runaway file into Detail.body
// (which the render re-splits on every frame). Returns the possibly-truncated text
// and whether the tail was dropped; the caller marks the truncation where it fits.
fn read_capped(path: &Path) -> std::io::Result<(String, bool)> {
    let bytes = std::fs::read(path)?;
    let truncated = bytes.len() > MAX_BYTES;
    let slice = &bytes[..bytes.len().min(MAX_BYTES)];
    Ok((String::from_utf8_lossy(slice).into_owned(), truncated))
}

// resolve: given the section and its row, pick the single file this item drills
// into. The mapping is deterministic and per-section:
//   - captains_call / under_way / charted: the task's brief, else its status log.
//   - landed: the artifact path the row names (a report/decision), else the
//     status log.
//   - merge: the branch's status log (the id is the branch; there is no body
//     file, so the status log is the honest underlying record).
//   - secondmates: the secondmate's status log.
// Every path is resolved under base_dir() so the app reads the SAME live files
// the fleet writes. Returns None only when the row carries no usable id.
#[allow(dead_code)]
pub fn resolve(kind: SectionKind, row: &Value) -> Option<Target> {
    resolve_in(base_dir()?.as_path(), kind, row)
}

// resolve_in: the pure resolver against an explicit base, so path mapping is
// testable without relying on the process-global FM_HOME (which parallel tests
// would race on). resolve() is the thin env-based wrapper.
pub fn resolve_in(base: &Path, kind: SectionKind, row: &Value) -> Option<Target> {
    let id = row_id(row);
    if id.is_empty() {
        return None;
    }
    match kind {
        SectionKind::Landed => {
            let artifact = str_field(row, "artifact");
            if !artifact.is_empty() && artifact != "-" {
                return Some(Target {
                    title: format!("{id} - {artifact}"),
                    path: resolve_artifact(base, &artifact),
                });
            }
            Some(brief_or_status(base, &id))
        }
        SectionKind::Secondmates => Some(status_target(base, &id)),
        SectionKind::Merge => {
            // A merge row is a finished, torn-down task: its status log is usually
            // gone but its brief survives teardown, so prefer the brief and let
            // open() fall back to the status log when it still exists.
            Some(brief_or_status(base, &id))
        }
        _ => Some(brief_or_status(base, &id)),
    }
}

// An artifact path from a row is repo-relative (e.g. data/x/report.md); join it
// under base, but never let it escape base via .. or an absolute path.
fn resolve_artifact(base: &Path, artifact: &str) -> PathBuf {
    let rel = Path::new(artifact);
    if rel.is_absolute() || artifact.contains("..") {
        // Refuse traversal: keep only the final file name, or stay at base when
        // there is none (a path whose last component is "..").
        return match rel.file_name() {
            Some(name) => base.join(name),
            None => base.to_path_buf(),
        };
    }
    base.join(rel)
}

// brief_or_status: prefer the task brief (the body the captain wants), and record
// the status log as the fallback the reader uses when the brief is absent. The
// resolver stays pure (no stat here); open() picks the first that exists.
fn brief_or_status(base: &Path, id: &str) -> Target {
    Target {
        title: format!("{id} - task"),
        path: base.join("data").join(id).join("brief.md"),
    }
}

fn status_target(base: &Path, id: &str) -> Target {
    Target {
        title: format!("{id} - status log"),
        path: base.join("state").join(format!("{id}.status")),
    }
}

// The status-log path for an id, used as the universal fallback when a preferred
// body file (brief/artifact) does not exist.
fn status_path(base: &Path, id: &str) -> PathBuf {
    base.join("state").join(format!("{id}.status"))
}

// open: the on-demand read. Resolves the target, reads that one file NOW, and
// falls back to the status log when the preferred file is absent, so opening an
// item always shows the most real record available. Never reads more than one
// item's files.
pub fn open(kind: SectionKind, row: &Value) -> Detail {
    match base_dir() {
        Some(base) => open_in(base.as_path(), kind, row),
        None => Detail {
            title: "no detail".to_string(),
            path: PathBuf::new(),
            body: "Could not locate the firstmate home to read detail files.".to_string(),
        },
    }
}

// open_in: the pure on-demand read against an explicit base. Loads the primary
// body for the row (report-preferred for landed/scout rows), then appends the
// small enrichment sections so opening a row answers "what happened here". Reads
// only this one item's files; makes no network call.
pub fn open_in(base: &Path, kind: SectionKind, row: &Value) -> Detail {
    let mut detail = load_primary(base, kind, row);
    let extra = enrichment(base, kind, row, &detail.path);
    if !extra.is_empty() {
        // Separate the enrichment from the primary body with a blank line so the
        // real record stays first and the added context reads as a footer.
        if !detail.body.is_empty() {
            detail.body.push_str("\n\n");
        }
        detail.body.push_str(&extra);
    }
    detail
}

// load_primary: resolve and read the single primary body file for the row, with
// the section fallbacks. Landed/scout rows prefer data/<id>/report.md when it
// exists (it survives teardown and is the deliverable the captain wants), over
// whatever artifact/brief the row otherwise names.
fn load_primary(base: &Path, kind: SectionKind, row: &Value) -> Detail {
    let id = row_id(row);
    // Item 3: a landed/scout row prefers its report deliverable when present.
    if kind == SectionKind::Landed && !id.is_empty() {
        let report = report_path(base, &id);
        if report.is_file() {
            return read_target(Target {
                title: format!("{id} - report"),
                path: report,
            });
        }
    }
    let Some(target) = resolve_in(base, kind, row) else {
        return Detail {
            title: "no detail".to_string(),
            path: PathBuf::new(),
            body: "This item has no underlying file to open.".to_string(),
        };
    };
    // First choice: the resolved file. Fallback: the status log for the id, which
    // exists for essentially every live task even when a brief does not.
    if target.path.is_file() {
        return read_target(target);
    }
    let sp = status_path(base, &id);
    if sp != target.path && sp.is_file() {
        return read_target(Target {
            title: format!("{id} - status log"),
            path: sp,
        });
    }
    // Last resort: a Captain's Call decision or a charted item is a backlog entry
    // with no task dir - its real record is its backlog line. Pull that one entry
    // so opening it still shows the live decision text, read on demand.
    if let Some(entry) = backlog_entry(base, &id) {
        return Detail {
            title: format!("{id} - backlog entry"),
            path: base.join("data").join("backlog.md"),
            body: entry,
        };
    }
    // Nothing on disk: an honest note, not a blank pane.
    Detail {
        title: target.title,
        body: format!(
            "No underlying file found yet.\nLooked for: {}",
            target.path.display()
        ),
        path: target.path,
    }
}

// data/<id>/report.md, the scout deliverable that survives teardown.
fn report_path(base: &Path, id: &str) -> PathBuf {
    base.join("data").join(id).join("report.md")
}

// enrichment: the small per-row context appended after the primary body. Each
// block is added only when its source exists, so an item with nothing extra to
// show stays a clean single body. Blocks, in order:
//   1. the status-log wake-event timeline (unless the body already IS it);
//   2. the folded open-decision trail for a decision row;
//   3. the locally-recorded merge/PR links for a merge or landed row;
//   4. a compact meta footer (harness/model/backend/window/worktree).
fn enrichment(base: &Path, kind: SectionKind, row: &Value, body_path: &Path) -> String {
    let id = row_id(row);
    if id.is_empty() {
        return String::new();
    }
    let mut blocks: Vec<String> = Vec::new();

    // Item 1: always offer the status-log timeline alongside the brief/report, but
    // never duplicate it when the primary body already is the status log.
    let sp = status_path(base, &id);
    if sp != *body_path {
        if let Ok((text, truncated)) = read_capped(&sp) {
            let text = text.trim_end();
            if !text.is_empty() {
                let mark = if truncated { TRUNCATION_NOTE } else { "" };
                blocks.push(format!("--- status log ({id}.status) ---\n{text}{mark}"));
            }
        }
    }

    // Item 2: for a decision row, surface the keyed open-decision trail (folded by
    // the ONE owner of that grammar) plus the originating decision lines.
    if kind == SectionKind::CaptainsCall {
        if let Some(trail) = decision_trail(base, &id) {
            blocks.push(trail);
        }
    }

    // Item 4: on a merge or landed row, show the locally-recorded compare URL and
    // the recorded PR - local file reads only, never a live gh/CI call.
    if matches!(kind, SectionKind::Merge | SectionKind::Landed) {
        if let Some(links) = merge_links(base, &id, row) {
            blocks.push(links);
        }
    }

    // Item 5: a compact meta footer, useful when a task looks stuck.
    if let Some(footer) = meta_footer(base, &id) {
        blocks.push(footer);
    }

    blocks.join("\n\n")
}

// decision_trail: the still-open keyed decisions (folded by fm-classify-lib.sh,
// the ONE owner of the open/resolved grammar) plus the raw decision lines from
// the status log as the human-readable "why". Returns None when there is no
// status log or no decision activity, so a plain backlog decision adds nothing.
fn decision_trail(base: &Path, id: &str) -> Option<String> {
    let sp = status_path(base, id);
    let (text, truncated) = read_capped(&sp).ok()?;
    // The raw decision lines (display filter only - not the decision grammar):
    // needs-decision / blocked / resolved / captain-held, in file order.
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| {
            let v = leading_verb(l);
            matches!(
                v,
                "needs-decision" | "blocked" | "resolved" | "captain-held"
            )
        })
        .collect();
    if lines.is_empty() {
        return None;
    }
    let mut out = String::from("--- decision trail ---");
    match fold_open_decisions(base, &sp) {
        Some(open) if !open.trim().is_empty() => {
            out.push_str("\nstill open (key / verb / summary):\n");
            out.push_str(open.trim_end());
        }
        Some(_) => out.push_str("\nstill open: none (all resolved)"),
        None => {} // owner unavailable: fall through to the raw lines below.
    }
    out.push_str("\ntrail:\n");
    out.push_str(&lines.join("\n"));
    if truncated {
        out.push_str(TRUNCATION_NOTE);
    }
    Some(out)
}

// fold_open_decisions: reuse bin/fm-classify-lib.sh's status_open_decisions on the
// ONE status file, so the keyed open/resolved semantics have a single owner and
// this crate never reimplements them. Shells for exactly one file on the explicit
// Enter path. Returns None when the lib or bash is not reachable.
fn fold_open_decisions(base: &Path, status_file: &Path) -> Option<String> {
    let lib = classify_lib(base)?;
    if !lib.is_file() {
        return None;
    }
    let out = Command::new("bash")
        .arg("-c")
        .arg(r#"set -e; . "$1"; status_open_decisions "$2""#)
        .arg("_")
        .arg(&lib)
        .arg(status_file)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

// classify_lib: bin/fm-classify-lib.sh under the repo root (the SCRIPTS live in
// the repo even when FM_HOME points the DATA elsewhere). Falls back to base when
// the repo root cannot be located, so a colocated layout still resolves.
fn classify_lib(base: &Path) -> Option<PathBuf> {
    if let Some(root) = repo_root_for_watch() {
        let p = root.join("bin").join("fm-classify-lib.sh");
        if p.is_file() {
            return Some(p);
        }
    }
    Some(base.join("bin").join("fm-classify-lib.sh"))
}

// leading_verb: the first whitespace-delimited word before the first colon of a
// status line, matching fm-classify-lib.sh's status_line_verb for the common
// "verb: note" and "verb [key=x]: note" shapes. Display-only classification.
fn leading_verb(line: &str) -> &str {
    let head = line.split(':').next().unwrap_or("");
    head.split_whitespace().next().unwrap_or("")
}

// merge_links: the locally-recorded compare URL (already in the model row for a
// merge row) plus the recorded pr=/pr_head= from state/<id>.meta. LOCAL reads
// only - live CI status is not a file read, so it is deliberately not shown.
fn merge_links(base: &Path, id: &str, row: &Value) -> Option<String> {
    let mut lines: Vec<String> = Vec::new();
    let url = str_field(row, "url");
    if !url.is_empty() && url != "-" {
        lines.push(format!("compare: {url}"));
    }
    let meta = read_meta(base, id);
    if let Some(pr) = meta.get("pr") {
        if !pr.is_empty() {
            lines.push(format!("pr: {pr}"));
        }
    }
    if let Some(head) = meta.get("pr_head") {
        if !head.is_empty() {
            lines.push(format!("pr head: {head}"));
        }
    }
    if lines.is_empty() {
        return None;
    }
    Some(format!(
        "--- links (local record) ---\n{}",
        lines.join("\n")
    ))
}

// meta_footer: one compact line of the operator-facing meta fields, useful when a
// task looks stuck. Legibility over density: only the fields that exist, on a
// single line, never a full dump.
fn meta_footer(base: &Path, id: &str) -> Option<String> {
    let meta = read_meta(base, id);
    if meta.is_empty() {
        return None;
    }
    let mut parts: Vec<String> = Vec::new();
    for key in ["harness", "model", "backend", "window", "worktree"] {
        if let Some(v) = meta.get(key) {
            if !v.is_empty() {
                parts.push(format!("{key}={v}"));
            }
        }
    }
    if parts.is_empty() {
        return None;
    }
    Some(format!("meta: {}", parts.join(" · ")))
}

// read_meta: parse state/<id>.meta into a key->value map. Simple key=value lines,
// tolerant of blanks and comments; an absent file yields an empty map.
fn read_meta(base: &Path, id: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let path = base.join("state").join(format!("{id}.meta"));
    if let Ok(text) = std::fs::read_to_string(&path) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                map.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    map
}

// backlog_entry: the single backlog line (and any continuation) for an id, read
// on demand from data/backlog.md. This is the underlying record for a decision or
// charted item that has no task directory. Returns None when the id is absent.
fn backlog_entry(base: &Path, id: &str) -> Option<String> {
    let path = base.join("data").join("backlog.md");
    let text = std::fs::read_to_string(&path).ok()?;
    // A backlog item line names the id early: "- [ ] <id> - ...". Match the id as
    // a whole token so a prefix id does not catch a longer one.
    let needle_a = format!("] {id} -");
    let needle_b = format!("] {id} ("); // some entries go straight to metadata
    for line in text.lines() {
        if line.contains(&needle_a) || line.contains(&needle_b) {
            return Some(line.trim_start_matches('-').trim().to_string());
        }
    }
    None
}

fn read_target(target: Target) -> Detail {
    match read_capped(&target.path) {
        Ok((mut body, truncated)) => {
            if truncated {
                body.push_str(TRUNCATION_NOTE);
            }
            Detail {
                title: target.title,
                path: target.path,
                body,
            }
        }
        Err(e) => Detail {
            title: target.title,
            body: format!(
                "Could not read this file: {e}\nPath: {}",
                target.path.display()
            ),
            path: target.path,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Tests use the pure *_in variants against an explicit temp base, so they
    // never touch the process-global FM_HOME and run safely in parallel.
    fn tmp_home() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "fm-desk-detail-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(d.join("data")).unwrap();
        std::fs::create_dir_all(d.join("state")).unwrap();
        d
    }

    #[test]
    fn resolve_maps_each_section_to_its_underlying_file() {
        let home = tmp_home();

        let t = resolve_in(&home, SectionKind::CaptainsCall, &json!({"id":"task-x"})).unwrap();
        assert!(
            t.path.ends_with("data/task-x/brief.md"),
            "cc -> brief: {:?}",
            t.path
        );

        let t = resolve_in(&home, SectionKind::Merge, &json!({"id":"fm/branch"})).unwrap();
        assert!(
            t.path.ends_with("data/fm/branch/brief.md"),
            "merge -> brief (survives teardown): {:?}",
            t.path
        );

        let t = resolve_in(&home, SectionKind::Secondmates, &json!({"id":"builder"})).unwrap();
        assert!(
            t.path.ends_with("state/builder.status"),
            "sm -> status: {:?}",
            t.path
        );

        let t = resolve_in(
            &home,
            SectionKind::Landed,
            &json!({"id":"done-1","artifact":"data/done-1/report.md"}),
        )
        .unwrap();
        assert!(
            t.path.ends_with("data/done-1/report.md"),
            "landed -> artifact: {:?}",
            t.path
        );

        // A missing id is unopenable.
        assert!(resolve_in(&home, SectionKind::Charted, &json!({"title":"no id"})).is_none());
    }

    #[test]
    fn resolve_refuses_path_traversal_in_an_artifact() {
        let home = tmp_home();
        let t = resolve_in(
            &home,
            SectionKind::Landed,
            &json!({"id":"x","artifact":"../../etc/passwd"}),
        )
        .unwrap();
        assert!(
            !t.path.to_string_lossy().contains(".."),
            "traversal not neutralized: {:?}",
            t.path
        );
        assert!(t.path.starts_with(&home), "escaped base: {:?}", t.path);

        // A path whose final component is ".." has no file name; it must still be
        // neutralized to stay within base rather than falling back to the raw path.
        let t = resolve_in(
            &home,
            SectionKind::Landed,
            &json!({"id":"x","artifact":"a/b/.."}),
        )
        .unwrap();
        assert!(
            !t.path.to_string_lossy().contains(".."),
            "trailing .. not neutralized: {:?}",
            t.path
        );
        assert!(t.path.starts_with(&home), "escaped base: {:?}", t.path);
    }

    #[test]
    fn open_reads_the_brief_on_demand() {
        let home = tmp_home();
        std::fs::create_dir_all(home.join("data/task-x")).unwrap();
        std::fs::write(home.join("data/task-x/brief.md"), "# Task\nreal brief body").unwrap();
        let d = open_in(&home, SectionKind::CaptainsCall, &json!({"id":"task-x"}));
        assert!(
            d.body.contains("real brief body"),
            "brief not read: {}",
            d.body
        );
    }

    #[test]
    fn open_falls_back_to_the_status_log_when_no_brief_exists() {
        let home = tmp_home();
        // No brief; only a status log exists for this id.
        std::fs::write(
            home.join("state/task-y.status"),
            "working: started\ndone: shipped",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::CaptainsCall, &json!({"id":"task-y"}));
        assert!(
            d.body.contains("done: shipped"),
            "status fallback not read: {}",
            d.body
        );
        assert!(
            d.title.contains("status log"),
            "title should mark the fallback: {}",
            d.title
        );
    }

    #[test]
    fn open_gives_an_honest_note_when_nothing_exists() {
        let home = tmp_home();
        let d = open_in(&home, SectionKind::Charted, &json!({"id":"ghost"}));
        assert!(
            d.body.contains("No underlying file"),
            "expected honest note: {}",
            d.body
        );
    }

    #[test]
    fn open_falls_back_to_the_backlog_entry_for_a_decision_with_no_files() {
        let home = tmp_home();
        // A decision item lives only as a backlog line - no brief, no status log.
        std::fs::write(
            home.join("data/backlog.md"),
            "- [ ] some-decision - restore X or keep it dropped? (kind: captain)\n- [ ] other - unrelated\n",
        )
        .unwrap();
        let d = open_in(
            &home,
            SectionKind::CaptainsCall,
            &json!({"id":"some-decision"}),
        );
        assert!(
            d.body.contains("restore X or keep it dropped"),
            "backlog entry not read: {}",
            d.body
        );
        assert!(
            d.title.contains("backlog entry"),
            "title should mark the backlog source: {}",
            d.title
        );
        // The whole-token match must not catch a different id.
        assert!(
            !d.body.contains("unrelated"),
            "matched the wrong backlog line: {}",
            d.body
        );
    }

    // === Item 3: report.md preferred as the body for a landed/scout row ========
    #[test]
    fn landed_row_prefers_the_report_over_the_named_artifact() {
        let home = tmp_home();
        // The row names one artifact, but a report.md exists too. The report wins:
        // it survives teardown and is the deliverable the captain wants.
        std::fs::create_dir_all(home.join("data/scout-1")).unwrap();
        std::fs::write(home.join("data/scout-1/report.md"), "the scout deliverable").unwrap();
        std::fs::write(home.join("data/scout-1/other.md"), "some other artifact").unwrap();
        let d = open_in(
            &home,
            SectionKind::Landed,
            &json!({"id":"scout-1","artifact":"data/scout-1/other.md"}),
        );
        assert!(
            d.body.contains("the scout deliverable"),
            "report not preferred: {}",
            d.body
        );
        assert!(
            d.title.contains("report"),
            "title should mark the report source: {}",
            d.title
        );
    }

    #[test]
    fn landed_row_uses_the_named_artifact_when_no_report_exists() {
        let home = tmp_home();
        // No report.md: the row's named artifact is still read as before.
        std::fs::create_dir_all(home.join("data/land-2")).unwrap();
        std::fs::write(home.join("data/land-2/decision.md"), "the decision record").unwrap();
        let d = open_in(
            &home,
            SectionKind::Landed,
            &json!({"id":"land-2","artifact":"data/land-2/decision.md"}),
        );
        assert!(
            d.body.contains("the decision record"),
            "artifact not read when no report: {}",
            d.body
        );
    }

    // === Item 1: the status-log timeline is offered alongside the brief ========
    #[test]
    fn a_task_row_appends_its_status_log_timeline_to_the_brief() {
        let home = tmp_home();
        std::fs::create_dir_all(home.join("data/task-z")).unwrap();
        std::fs::write(home.join("data/task-z/brief.md"), "# Task\nthe brief body").unwrap();
        std::fs::write(
            home.join("state/task-z.status"),
            "working: started\ndone: shipped\n",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::UnderWay, &json!({"id":"task-z"}));
        // The brief stays the primary body, and the status timeline is appended.
        assert!(
            d.body.contains("the brief body"),
            "brief missing: {}",
            d.body
        );
        assert!(
            d.body.contains("status log") && d.body.contains("done: shipped"),
            "status timeline not appended: {}",
            d.body
        );
        // The brief comes first; the status log follows it.
        let brief_at = d.body.find("the brief body").unwrap();
        let log_at = d.body.find("done: shipped").unwrap();
        assert!(brief_at < log_at, "status log should follow the brief");
    }

    #[test]
    fn an_oversized_status_log_is_capped_in_the_enrichment_block() {
        let home = tmp_home();
        std::fs::create_dir_all(home.join("data/task-big")).unwrap();
        std::fs::write(home.join("data/task-big/brief.md"), "brief").unwrap();
        // A runaway status log larger than the detail cap must not inflate the body
        // the render re-splits every frame; the appended timeline stays capped.
        let huge = "x".repeat(MAX_BYTES + 4096);
        std::fs::write(home.join("state/task-big.status"), &huge).unwrap();
        let d = open_in(&home, SectionKind::UnderWay, &json!({"id":"task-big"}));
        assert!(
            d.body.len() < MAX_BYTES + 1024,
            "status-log enrichment bypassed the cap: {} bytes",
            d.body.len()
        );
        assert!(
            d.body.contains("truncated"),
            "truncation not marked on the appended status log"
        );
    }

    #[test]
    fn the_status_log_is_not_duplicated_when_it_is_the_body() {
        let home = tmp_home();
        // No brief; the primary body IS the status log. It must appear once, not
        // once as the body and again as an appended timeline.
        std::fs::write(
            home.join("state/task-w.status"),
            "working: only the status log here\n",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::UnderWay, &json!({"id":"task-w"}));
        assert_eq!(
            d.body.matches("only the status log here").count(),
            1,
            "status log duplicated: {}",
            d.body
        );
    }

    // === Item 4: local merge/PR links on a merge or landed row =================
    #[test]
    fn merge_row_shows_the_local_compare_url_and_recorded_pr() {
        let home = tmp_home();
        std::fs::write(
            home.join("state/fm-branch.meta"),
            "harness=claude\npr=https://example.test/mr/7\npr_head=abc123\n",
        )
        .unwrap();
        let d = open_in(
            &home,
            SectionKind::Merge,
            &json!({"id":"fm-branch","url":"https://compare.test/fm-branch"}),
        );
        assert!(
            d.body.contains("compare: https://compare.test/fm-branch"),
            "compare url missing: {}",
            d.body
        );
        assert!(
            d.body.contains("pr: https://example.test/mr/7"),
            "recorded pr missing: {}",
            d.body
        );
        assert!(d.body.contains("abc123"), "pr head missing: {}", d.body);
    }

    #[test]
    fn merge_row_omits_the_links_block_when_nothing_is_recorded() {
        let home = tmp_home();
        // No url on the row and no meta: the links block must not appear.
        let d = open_in(&home, SectionKind::Merge, &json!({"id":"fm-bare"}));
        assert!(
            !d.body.contains("links (local record)"),
            "links block should be absent: {}",
            d.body
        );
    }

    // === Item 5: the compact meta footer ======================================
    #[test]
    fn a_meta_footer_lists_only_present_fields_on_one_line() {
        let home = tmp_home();
        std::fs::create_dir_all(home.join("data/task-m")).unwrap();
        std::fs::write(home.join("data/task-m/brief.md"), "brief").unwrap();
        std::fs::write(
            home.join("state/task-m.meta"),
            "harness=pi\nmodel=opus\nbackend=tmux\n# a comment\nyolo=off\n",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::UnderWay, &json!({"id":"task-m"}));
        assert!(d.body.contains("meta:"), "meta footer missing: {}", d.body);
        assert!(d.body.contains("harness=pi"), "harness missing: {}", d.body);
        assert!(d.body.contains("model=opus"), "model missing: {}", d.body);
        // A field not in the compact set (yolo) is not shown; the footer is terse.
        assert!(
            !d.body.contains("yolo=off"),
            "footer should not dump every field: {}",
            d.body
        );
    }

    // read_meta parses key=value lines and tolerates blanks/comments.
    #[test]
    fn read_meta_parses_key_value_lines() {
        let home = tmp_home();
        std::fs::write(
            home.join("state/mt.meta"),
            "\n# header\nharness=claude\n  model = opus \nempty=\n",
        )
        .unwrap();
        let m = read_meta(&home, "mt");
        assert_eq!(m.get("harness").map(String::as_str), Some("claude"));
        assert_eq!(m.get("model").map(String::as_str), Some("opus"));
        assert_eq!(m.get("empty").map(String::as_str), Some(""));
        assert!(m.get("header").is_none(), "comment line was parsed");
    }

    // leading_verb matches the classify-lib verb shapes used by the trail filter.
    #[test]
    fn leading_verb_reads_the_word_before_the_colon() {
        assert_eq!(
            leading_verb("needs-decision: pick a route"),
            "needs-decision"
        );
        assert_eq!(leading_verb("resolved [key=x]: decided"), "resolved");
        assert_eq!(leading_verb("working: nothing here"), "working");
        assert_eq!(leading_verb(""), "");
    }

    // === Item 2: the keyed open-decision trail for a decision row ==============
    // decision_trail renders the raw decision lines and, when the classify-lib
    // fold owner is reachable, the still-open keyed set. The fold is shelled from
    // the real bin/fm-classify-lib.sh, so this test also proves the one-owner
    // reuse works end to end rather than reimplementing the grammar in Rust.
    #[test]
    fn a_decision_row_surfaces_the_keyed_open_trail() {
        let home = tmp_home();
        // One decision opened and never resolved, plus an unrelated working line.
        std::fs::write(
            home.join("state/dec-1.status"),
            "working: started\nneeds-decision [key=route]: pick A or B\ndone: shipped\n",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::CaptainsCall, &json!({"id":"dec-1"}));
        assert!(
            d.body.contains("decision trail"),
            "trail block missing: {}",
            d.body
        );
        assert!(
            d.body.contains("pick A or B"),
            "originating decision line missing: {}",
            d.body
        );
        // When bash + the fold owner are reachable, the still-open key is folded.
        if fold_open_decisions(&home, &status_path(&home, "dec-1")).is_some() {
            assert!(
                d.body.contains("route"),
                "open key not folded from the owner: {}",
                d.body
            );
        }
    }

    #[test]
    fn an_oversized_decision_trail_is_capped() {
        let home = tmp_home();
        // A long-stuck decision whose status log accumulates many decision lines
        // must not push an unbounded trail into the body the render re-splits every
        // frame; the appended trail stays capped like the sibling status-log block.
        let line = "needs-decision [key=k]: pick a route\n";
        let huge = line.repeat((MAX_BYTES / line.len()) + 512);
        std::fs::write(home.join("state/dec-big.status"), &huge).unwrap();
        let trail = decision_trail(&home, "dec-big").expect("trail present");
        assert!(
            trail.len() < MAX_BYTES + 1024,
            "decision trail bypassed the cap: {} bytes",
            trail.len()
        );
        assert!(
            trail.contains("truncated"),
            "truncation not marked on the capped decision trail"
        );
    }

    #[test]
    fn a_decision_row_with_no_decision_lines_adds_no_trail() {
        let home = tmp_home();
        // A plain backlog decision with only a working status has no trail block.
        std::fs::write(
            home.join("state/dec-2.status"),
            "working: nothing to decide\n",
        )
        .unwrap();
        let d = open_in(&home, SectionKind::CaptainsCall, &json!({"id":"dec-2"}));
        assert!(
            !d.body.contains("decision trail"),
            "trail should be absent with no decision lines: {}",
            d.body
        );
    }
}
