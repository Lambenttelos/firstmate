// The fm-desk.v1 view model - parsed, never built. bin/fm-desk-lib.sh is the ONE
// owner of this model (the one-owner rule); this crate is a consumer. Anything a
// section needs that the model lacks is added to the MODEL, not derived here.
//
// Rows stay serde_json::Value so a model that gains a field never fails to load:
// each paint reads only the fields it knows by name and tolerates the rest.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct Model {
    #[serde(default)]
    pub now: String,
    // WP-1 stamps the model with when it was projected; absent on an older cache,
    // in which case the caller falls back to the cache file's mtime for staleness.
    #[serde(default)]
    pub generated_at: Option<String>,
    #[serde(default)]
    pub away: bool,
    #[serde(default)]
    pub health: Health,
    #[serde(default)]
    pub header: Header,
    #[serde(default)]
    pub gaps: Vec<String>,
    #[serde(default)]
    pub sections: Sections,
}

#[derive(Debug, Default, Deserialize)]
pub struct Health {
    // Absent (null) means "monitoring status unknown"; a large value means lapsed.
    #[serde(default)]
    pub beat_age_seconds: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Header {
    #[serde(default)]
    pub summary: String,
    // ITEM 4: the captain's Claude account usage, gathered in the MODEL (the lib)
    // so BOTH boards render the same line and this crate never shells out on its
    // interactive path. null when quota-axi could not be read (a gap line covers
    // it) or the box has no usable window. Only `line` is painted; the structured
    // session/week fields ride along for a future surface.
    #[serde(default)]
    pub usage: Option<Usage>,
    // The captain's Claude accounts (all of them) plus which credential store
    // points at which. Gathered in the MODEL (the lib) so BOTH boards paint the
    // same block and this crate never shells out. null when cswap could not be
    // read (a gap line covers it) or there are no accounts. The markers are
    // CONFIGURED store state, never proof of what a live session uses.
    #[serde(default)]
    pub accounts: Option<Accounts>,
    // The token-cost / efficiency panel (burn rate, cache-hit ratio, heaviest
    // engines, cost per landed ticket). Gathered in the MODEL (the lib) so BOTH
    // boards paint the same figures and this crate never re-costs a token or
    // shells the coster on its interactive path. null when the coster could not
    // be read (a gap line covers it). `line` is the terse header glance; `detail`
    // is the pre-rendered drill-down body. cost_if_api and cost_if_api_covered
    // ride along as SEPARATE facts, never summed.
    #[serde(default)]
    pub token_cost: Option<TokenCost>,
}

#[derive(Debug, Default, Deserialize)]
pub struct TokenCost {
    // The one terse header line the board paints: burn + the if-API/billed/
    // covered split + cache-hit, with an optional "(Nm old)" age token. Empty when
    // there is nothing to show; the header then paints no cost line.
    #[serde(default)]
    pub line: String,
    // The pre-rendered drill-down body, one string per line, built by the MODEL so
    // both boards show identical detail. Painted verbatim in the cost overlay.
    #[serde(default)]
    pub detail: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Accounts {
    #[serde(default)]
    pub caption: String,
    // One compact pre-rendered line per account, built by the lib so both boards
    // paint identical text. The structured `accounts` list rides along for the
    // interactive switch overlay and any future surface.
    #[serde(default)]
    pub lines: Vec<String>,
    // Parallel to `lines`: a usage-severity bullet class per line
    // (done/waiting/blocked/idle) the lib derived from the structured percentages,
    // so a board colours the glance without re-parsing the rendered line. A short
    // or absent list means "no class known" for the uncovered lines.
    #[serde(default)]
    pub line_classes: Vec<String>,
    // Parallel to `lines`: the exact 5h and 7d token substrings the lib baked into
    // each line and their per-window classes, so a board colours EACH window's
    // token from the model rather than re-deriving state by parsing the line. An
    // empty token means that window is unmeasured and takes no colour.
    #[serde(default)]
    pub five_hour_tokens: Vec<String>,
    #[serde(default)]
    pub five_hour_classes: Vec<String>,
    #[serde(default)]
    pub seven_day_tokens: Vec<String>,
    #[serde(default)]
    pub seven_day_classes: Vec<String>,
    #[serde(default)]
    pub accounts: Vec<Value>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Usage {
    #[serde(default)]
    pub line: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct Sections {
    #[serde(default)]
    pub captains_call: Section,
    #[serde(default)]
    pub under_way: Section,
    #[serde(default)]
    pub charted: Section,
    #[serde(default)]
    pub landed: Section,
    #[serde(default)]
    pub merge: Section,
    #[serde(default)]
    pub secondmates: Section,
}

// One shape for every section: a status, the ranked rows the lib produced, and
// the collapse counts. status is Option because the merge section is assembled
// without one; the paint treats a missing status as "ok".
//
// The cache is stored UNCAPPED (shown=0/total), so the STATIC board (render's
// vertical-fit frame()) owns its own display cap and ignores these counts. The
// INTERACTIVE nav board is fully navigable, so it walks visible_rows(), which
// with an uncapped cache (shown<=0) returns every ranked row - the cursor can
// reach anything, and drill-down reads the one underlying file on demand.
#[derive(Debug, Default, Deserialize)]
pub struct Section {
    #[serde(default)]
    pub status: Option<String>,
    // total: the ranked count the lib produced. Kept for wire-shape fidelity and
    // future surfaces; the crate paints from `rows`/`shown`, not this count.
    #[serde(default)]
    #[allow(dead_code)]
    pub total: i64,
    // full_total: the section's TRUE item count, independent of any DESK_MAX/cap
    // bound on the ranked `rows`. The section header shows it as " (N)" so the
    // captain reads the section size off a header he already scans - the same
    // presentation the shell board (bin/fm-desk-tui.sh rule()) paints. The two
    // boards must not disagree, so both read this one field.
    #[serde(default)]
    pub full_total: i64,
    #[serde(default)]
    pub shown: i64,
    #[serde(default)]
    pub more: i64,
    #[serde(default)]
    pub more_hint: String,
    // captains_call only: how many finished branches wait to merge, so an empty
    // decisions list can still point at the merge section.
    #[serde(default)]
    pub merge_count: Option<i64>,
    #[serde(default)]
    pub rows: Vec<Value>,
}

// The six sections, in paint order. Nav and render share this enum and the
// section_order helper so the flattened selectable list and the painted board
// iterate identically - the one guarantee that keeps a keystroke's target and
// the highlighted line in agreement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SectionKind {
    CaptainsCall,
    UnderWay,
    Charted,
    Landed,
    Merge,
    Secondmates,
}

impl SectionKind {
    // The row-id key used to resolve a drill-down file (all rows carry "id").
    pub fn all() -> [SectionKind; 6] {
        [
            SectionKind::CaptainsCall,
            SectionKind::UnderWay,
            SectionKind::Charted,
            SectionKind::Landed,
            SectionKind::Merge,
            SectionKind::Secondmates,
        ]
    }
}

impl Sections {
    pub fn get(&self, kind: SectionKind) -> &Section {
        match kind {
            SectionKind::CaptainsCall => &self.captains_call,
            SectionKind::UnderWay => &self.under_way,
            SectionKind::Charted => &self.charted,
            SectionKind::Landed => &self.landed,
            SectionKind::Merge => &self.merge,
            SectionKind::Secondmates => &self.secondmates,
        }
    }
}

impl Section {
    pub fn status(&self) -> &str {
        self.status.as_deref().unwrap_or("ok")
    }
    // Rows the INTERACTIVE nav board walks: the first `shown` of the ranked set
    // (never more than are present). shown<=0 means paint every row - which is the
    // uncapped-cache case, so the fully-navigable board can reach any ranked item
    // and the static board's own vertical-fit cap (render::Painter) is independent.
    pub fn visible_rows(&self) -> &[Value] {
        let n = if self.shown <= 0 {
            self.rows.len()
        } else {
            (self.shown as usize).min(self.rows.len())
        };
        &self.rows[..n]
    }
}

// str_field: read one string field from a row Value, empty when absent/null.
pub fn str_field(row: &Value, key: &str) -> String {
    row.get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

// --- loading the model (Tier 1) ---------------------------------------------
// The interactive path reads the CACHED model (the watcher's periodic desk pass
// persists state/desk-model.json). This is ~8ms versus the tens-of-seconds full
// projection the whole three-tier architecture exists to avoid, so the interactive
// path NEVER shells the projection: a missing or stale cache is rendered honestly
// ("data is N minutes old", or a "cache not available yet" notice), it does not
// silently pay the projection. The projection shell-out survives ONLY as an explicit
// non-interactive escape hatch (project_once, used by the non-tty fallback when
// no cache exists), never on the interactive path.
//
// Order for the interactive load:
//   1. FM_DESK_MODEL (a test/inspection seam) - read that file.
//   2. <state>/desk-model.json - the cache the watcher writes.
//   3. neither present -> Err, which the caller renders as an honest notice.
pub struct Loaded {
    pub model: Model,
    // How the model was obtained. Read by tests to assert the interactive path
    // never projects; kept as a labeled provenance value for later surfaces.
    #[allow(dead_code)]
    pub source: Source,
    // Age of the data in seconds, for the honest staleness note. Prefer the
    // model's own generated_at when WP-1 provides it; else the cache file mtime.
    pub age_secs: Option<i64>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Source {
    Seam,
    Cache,
}

// load: the interactive data source. Reads the cache only; never projects.
pub fn load() -> Result<Loaded, String> {
    if let Ok(p) = std::env::var("FM_DESK_MODEL") {
        if !p.is_empty() {
            let text = std::fs::read_to_string(&p).map_err(|e| format!("read {p}: {e}"))?;
            let model = parse(&text)?;
            let age = age_of(&model, Some(std::path::Path::new(&p)));
            return Ok(Loaded {
                model,
                source: Source::Seam,
                age_secs: age,
            });
        }
    }
    let path = cache_path().ok_or_else(|| "could not locate the desk model cache".to_string())?;
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("the desk model cache is not available yet ({e})"))?;
    if text.trim().is_empty() {
        return Err("the desk model cache is present but empty".to_string());
    }
    let model = parse(&text)?;
    let age = age_of(&model, Some(&path));
    Ok(Loaded {
        model,
        source: Source::Cache,
        age_secs: age,
    })
}

// cache_path: <FM_HOME|root>/state/desk-model.json.
pub fn cache_path() -> Option<PathBuf> {
    state_dir(repo_root().as_deref()).map(|s| s.join("desk-model.json"))
}

// state_dir_for_watch / repo_root_for_watch: the same resolution the interactive
// load uses, exposed so WP-5's watcher watches EXACTLY the state dir and repo the
// app reads from. A missing state dir falls back to "state" so the watcher still
// starts (its poll fallback then simply sees nothing until the dir appears).
pub fn state_dir_for_watch() -> PathBuf {
    state_dir(repo_root().as_deref()).unwrap_or_else(|| PathBuf::from("state"))
}

pub fn repo_root_for_watch() -> Option<PathBuf> {
    repo_root()
}

pub fn parse(text: &str) -> Result<Model, String> {
    serde_json::from_str(text).map_err(|e| format!("parse fm-desk.v1 model: {e}"))
}

// age_of: seconds since the model was generated. Prefer generated_at (WP-1),
// else the file mtime, else unknown.
fn age_of(model: &Model, path: Option<&Path>) -> Option<i64> {
    if let Some(ts) = model.generated_at.as_deref() {
        if let Some(secs) = age_from_iso(ts) {
            return Some(secs);
        }
    }
    let p = path?;
    let meta = std::fs::metadata(p).ok()?;
    let mtime = meta.modified().ok()?;
    let age = std::time::SystemTime::now().duration_since(mtime).ok()?;
    Some(age.as_secs() as i64)
}

// age_from_iso: seconds since a "YYYY-MM-DD HH:MM:SS UTC" (or ISO-8601 Z)
// timestamp, computed without a date crate. Returns None on any parse trouble so
// the caller falls back to the file mtime.
fn age_from_iso(ts: &str) -> Option<i64> {
    let t = ts.trim();
    let t = t.trim_end_matches(" UTC").trim_end_matches('Z');
    let (date, time) = t.split_once(['T', ' '])?;
    let mut d = date.split('-');
    let year: i64 = d.next()?.parse().ok()?;
    let month: i64 = d.next()?.parse().ok()?;
    let day: i64 = d.next()?.parse().ok()?;
    let mut tp = time.split(':');
    let hour: i64 = tp.next()?.parse().ok()?;
    let min: i64 = tp.next()?.parse().ok()?;
    let sec: i64 = tp.next().unwrap_or("0").split('.').next()?.parse().ok()?;
    let epoch = days_from_civil(year, month, day) * 86400 + hour * 3600 + min * 60 + sec;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;
    Some(now - epoch)
}

// days_from_civil: days since the Unix epoch for a civil (proleptic Gregorian)
// date, per Howard Hinnant's algorithm.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

// Locate the repo root: the dir holding bin/fm-desk-lib.sh, walking up from the
// executable (release binary lives at <root>/desk/target/release/fm-desk).
fn repo_root() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent();
    while let Some(d) = dir {
        if d.join("bin/fm-desk-lib.sh").is_file() {
            return Some(d.to_path_buf());
        }
        dir = d.parent();
    }
    None
}

// The state dir: FM_HOME/state when FM_HOME is set (the lib's own resolution),
// else <root>/state.
fn state_dir(root: Option<&Path>) -> Option<PathBuf> {
    if let Ok(home) = std::env::var("FM_HOME") {
        if !home.is_empty() {
            return Some(PathBuf::from(home).join("state"));
        }
    }
    root.map(|r| r.join("state"))
}

// base_dir: the home root that holds data/ and state/ - FM_HOME when set (the
// lib's resolution), else the repo root. Drill-down file paths are resolved
// under this so the app reads the SAME live files the fleet writes.
pub fn base_dir() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("FM_HOME") {
        if !home.is_empty() {
            return Some(PathBuf::from(home));
        }
    }
    repo_root()
}

// project_once: source the lib and run desk_project to emit the model JSON. This
// is the ONLY projection call. It is an EXPLICIT non-interactive escape hatch
// (the non-tty static fallback when no cache exists), NEVER on the interactive
// path - the tens-of-seconds cost is exactly what the cache exists to avoid.
pub fn project_once() -> Result<String, String> {
    let root = repo_root().ok_or_else(|| "could not locate the firstmate repo root".to_string())?;
    let lib = root.join("bin/fm-desk-lib.sh");
    let out = Command::new("bash")
        .arg("-c")
        .arg("set -e; . \"$1\"; desk_project")
        .arg("_")
        .arg(&lib)
        .output()
        .map_err(|e| format!("run desk_project: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "desk_project failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    if text.trim().is_empty() {
        return Err("desk_project produced an empty model".to_string());
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parse_tolerates_unknown_and_missing_fields() {
        // A model that gains a future field still parses; a section missing rows
        // defaults to empty rather than failing.
        let json = r#"{
          "schema":"fm-desk.v1","now":"2026-08-23 09:00:00 UTC",
          "future_field": {"anything": [1,2,3]},
          "header":{"summary":"s","counts":{"decisions":1}},
          "sections":{"captains_call":{"status":"ok","rows":[{"id":"x","summary":"y","bullet":"waiting","extra":"ok"}]}}
        }"#;
        let m = parse(json).unwrap();
        assert_eq!(m.header.summary, "s");
        assert_eq!(m.sections.captains_call.rows.len(), 1);
        assert_eq!(str_field(&m.sections.captains_call.rows[0], "summary"), "y");
        // A section entirely absent from the JSON defaults to empty.
        assert_eq!(m.sections.under_way.rows.len(), 0);
    }

    #[test]
    fn collapse_fields_parse_and_the_static_board_ignores_them() {
        // The cache stores collapse fields (total/shown/more/more_hint). They now
        // parse into the model (the nav board's visible_rows() reads `shown`), but
        // the STATIC board keeps every ranked row and owns its own display cap, so
        // an uncapped cache (shown=0) exposes all rows to it.
        let json = r#"{"now":"t","header":{"summary":""},
          "sections":{"captains_call":{"status":"ok","total":3,"shown":2,"more":1,
            "more_hint":"+1 more","rows":[{"id":"a"},{"id":"b"},{"id":"c"}]}}}"#;
        let m = parse(json).unwrap();
        assert_eq!(m.sections.captains_call.rows.len(), 3);
        assert_eq!(m.sections.captains_call.status(), "ok");
        assert_eq!(m.sections.captains_call.more_hint, "+1 more");
    }

    #[test]
    fn visible_rows_respects_shown_and_bounds() {
        let json = r#"{"now":"t","header":{"summary":""},
          "sections":{"captains_call":{"status":"ok","total":3,"shown":2,
            "rows":[{"id":"a"},{"id":"b"},{"id":"c"}]}}}"#;
        let m = parse(json).unwrap();
        assert_eq!(m.sections.captains_call.visible_rows().len(), 2);

        // shown greater than rows present is clamped to what exists.
        let json2 = r#"{"now":"t","header":{"summary":""},
          "sections":{"captains_call":{"status":"ok","total":9,"shown":9,
            "rows":[{"id":"a"}]}}}"#;
        let m2 = parse(json2).unwrap();
        assert_eq!(m2.sections.captains_call.visible_rows().len(), 1);

        // An uncapped cache (shown=0) exposes every ranked row to the nav board.
        let json3 = r#"{"now":"t","header":{"summary":""},
          "sections":{"captains_call":{"status":"ok","rows":[{"id":"a"},{"id":"b"}]}}}"#;
        let m3 = parse(json3).unwrap();
        assert_eq!(m3.sections.captains_call.visible_rows().len(), 2);
    }

    #[test]
    fn load_reads_the_cache_via_seam_and_never_projects() {
        // Point FM_DESK_MODEL at a temp file; load must read it and report Seam.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("fm-desk-model-test-{}.json", std::process::id()));
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(br#"{"now":"t","generated_at":"2026-08-23 09:00:00 UTC","header":{"summary":"hi"},"sections":{}}"#).unwrap();
        std::env::set_var("FM_DESK_MODEL", &path);
        let loaded = load().unwrap();
        std::env::remove_var("FM_DESK_MODEL");
        let _ = std::fs::remove_file(&path);
        assert_eq!(loaded.source, Source::Seam);
        assert_eq!(loaded.model.header.summary, "hi");
        // generated_at was in the past, so age is a non-negative number.
        assert!(loaded.age_secs.unwrap() >= 0);
    }

    #[test]
    fn age_follows_generated_at_not_the_file_mtime() {
        // The desk's "data is N old" note must report how old the DATA is (the
        // last successful persist), not when the file was last touched. The two
        // signals diverge whenever the persist's atomic write is killed mid-run:
        // the prior good cache keeps its OLD generated_at while its mtime could be
        // fresh from an unrelated touch. Drive them apart here - a just-created
        // file (mtime ~now) carrying a generated_at ~2 days in the past - and
        // assert the age tracks generated_at, so a stalled refresh reads as stale
        // rather than falsely fresh.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("fm-desk-age-test-{}.json", std::process::id()));
        let mut f = std::fs::File::create(&path).unwrap();
        // A generated_at fixed far in the past (~days), rendered from a known
        // epoch so the age assertion is exact.
        let gen_iso = "2026-08-23 09:00:00 UTC";
        let gen_epoch = 20_688 * 86_400 + 9 * 3600; // days_from_civil(2026,8,23)*86400 + 09:00
        let expected = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
            - gen_epoch;
        write!(
            f,
            r#"{{"now":"t","generated_at":"{gen_iso}","header":{{"summary":"hi"}},"sections":{{}}}}"#
        )
        .unwrap();
        let model = parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let age = age_of(&model, Some(&path)).unwrap();
        let _ = std::fs::remove_file(&path);
        // The file was created moments ago, so an mtime-based age would be tiny.
        // A generated_at-based age is many days. Assert we got the latter.
        assert!(
            age > 86_400,
            "age must follow generated_at (expected ~{expected}s, days old), got {age}s - it read the fresh file mtime instead"
        );
        assert!((age - expected).abs() < 120, "age {age}s should match generated_at age {expected}s");
    }

    #[test]
    fn age_falls_back_to_file_mtime_when_generated_at_is_absent() {
        // Older caches carry no generated_at. The age must then fall back to the
        // file mtime rather than going unknown, so the note still tells the truth.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("fm-desk-nomtime-test-{}.json", std::process::id()));
        std::fs::write(
            &path,
            br#"{"now":"t","header":{"summary":"hi"},"sections":{}}"#,
        )
        .unwrap();
        let model = parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let age = age_of(&model, Some(&path));
        let _ = std::fs::remove_file(&path);
        assert!(age.is_some(), "with no generated_at, age must fall back to the file mtime");
        assert!(age.unwrap() >= 0);
    }

    #[test]
    fn days_from_civil_matches_known_epochs() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 1, 1), 10957);
        assert_eq!(days_from_civil(2026, 8, 23), 20688);
    }
}
