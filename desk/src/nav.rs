// Navigation state for the desk (WP-4). This is the pure, testable core: it owns
// the cursor, the per-section expand/collapse flags, and the flattened list of
// selectable items. It holds NO terminal state and reads NO files - main.rs
// drives it from key events, render.rs paints from it, and detail.rs reads the
// one underlying file when an item is opened.
//
// The load-bearing invariant: the flattened item list here iterates sections and
// rows in EXACTLY the paint order (model::SectionKind::all, then each section's
// visible_rows), so the highlighted line and a keystroke's target never diverge.

use std::collections::HashMap;

use crate::model::{str_field, Model, Section, SectionKind};

// One selectable line. A header is the section title (foldable); a row is one
// item under it (openable into the drill-down).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavItem {
    Header(SectionKind),
    Row(SectionKind, usize),
}

pub struct Nav {
    // Collapsed sections. Absent = expanded (the default), so a fresh model shows
    // everything and the captain folds away what he does not want.
    collapsed: HashMap<SectionKind, bool>,
    items: Vec<NavItem>,
    cursor: usize,
}

// folds_away: the ONE fold predicate shared by nav and paint. A foldable section
// folds away when it has no content: an explicit "empty" status, or an "ok"
// section with zero rows (how an absent section defaults - the no-cache
// empty_model path emits "sections":{}, so every section defaults to ok + no
// rows). render::folded delegates here, so the interactive nav board and the
// static board fold exactly the same sections. A gap/away section is never folded.
pub fn folds_away(s: &Section) -> bool {
    s.status() == "empty" || (s.status() == "ok" && s.rows.is_empty())
}

// A section paints a header when it is one of the always-shown sections
// (captains_call, merge) or it is a foldable section that has not folded away -
// mirroring render.rs's folded()/always-shown split so nav and paint agree.
pub fn section_is_shown(kind: SectionKind, s: &Section) -> bool {
    match kind {
        SectionKind::CaptainsCall | SectionKind::Merge => true,
        _ => !folds_away(s),
    }
}

// Rows are selectable only on the ok/data path; a gap/away/empty section shows a
// header (for the always-shown two) but carries no openable rows.
fn section_has_rows(s: &Section) -> bool {
    !matches!(s.status(), "gap" | "away" | "empty")
}

impl Nav {
    pub fn new(model: &Model) -> Self {
        let mut nav = Nav {
            collapsed: HashMap::new(),
            items: Vec::new(),
            cursor: 0,
        };
        nav.rebuild(model);
        nav
    }

    pub fn is_collapsed(&self, kind: SectionKind) -> bool {
        *self.collapsed.get(&kind).unwrap_or(&false)
    }

    // Used by WP-5 file-watching to reconcile the cursor after a reload.
    #[allow(dead_code)]
    pub fn items(&self) -> &[NavItem] {
        &self.items
    }

    #[allow(dead_code)]
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn selected(&self) -> Option<NavItem> {
        self.items.get(self.cursor).copied()
    }

    // rebuild: recompute the flattened selectable list from the model and the
    // current fold flags. WP-5 will call this after a model reload; it preserves
    // the selected ITEM across the rebuild so a background update never yanks the
    // captain's place (falling back to the nearest valid index).
    pub fn rebuild(&mut self, model: &Model) {
        let previously = self.items.get(self.cursor).copied();
        let mut items = Vec::new();
        for kind in SectionKind::all() {
            let s = model.sections.get(kind);
            if !section_is_shown(kind, s) {
                continue;
            }
            items.push(NavItem::Header(kind));
            if !self.is_collapsed(kind) && section_has_rows(s) {
                for i in 0..s.visible_rows().len() {
                    items.push(NavItem::Row(kind, i));
                }
            }
        }
        self.items = items;
        self.cursor = match previously.and_then(|prev| self.items.iter().position(|it| *it == prev))
        {
            Some(idx) => idx,
            None => self.cursor.min(self.items.len().saturating_sub(1)),
        };
    }

    // reload: fold a freshly loaded model into the nav state (WP-5). Unlike a bare
    // rebuild (which preserves the selected SLOT), this preserves the captain's
    // place by the selected row's STABLE ID, so a background re-ranking that moves
    // a task in the list keeps the cursor ON that task rather than on whatever now
    // occupies its old slot. `prev_id` is the id of the row selected before the
    // reload (None when a header, or nothing, was selected). Section folds are
    // keyed by SectionKind and are untouched, so they survive the reload too.
    //
    // Resolution order after rebuilding the flattened list against the new model:
    //   1. the row carrying prev_id, if it still exists -> keep the captain on it;
    //   2. else the slot-preservation rebuild already applied (nearest valid slot),
    //      which for a header keeps section-relative place and for a vanished row
    //      clamps into range - a graceful neighbor rather than a jump to the top.
    pub fn reload(&mut self, model: &Model, prev: Option<(SectionKind, &str)>) {
        self.rebuild(model);
        let Some((prev_kind, id)) = prev else { return };
        if id.is_empty() {
            return;
        }
        // Resolve the id WITHIN its own section first. Reload's id search used to
        // scan every section and take the first hit, so a task briefly present in
        // two sections (a promotion in flight: the same id in under_way AND
        // charted) stole the cursor to whichever painted first - the captain saw
        // the cursor snap UP out of charted into under_way, and each down-arrow
        // re-triggered it, walling off landed. Section-scoping the match keeps the
        // cursor on the row the captain was actually on.
        if let Some(idx) = self.find_row(model, Some(prev_kind), id) {
            self.cursor = idx;
            return;
        }
        // The row left its section (a genuine cross-section move, e.g. a gate
        // promoted to under_way and gone from charted): follow it wherever it is.
        if let Some(idx) = self.find_row(model, None, id) {
            self.cursor = idx;
        }
    }

    // find_row: the flattened index of the first row carrying `id`, optionally
    // restricted to one section. `only = Some(kind)` is the section-scoped match
    // reload prefers; `None` is the any-section fallback for a moved row.
    fn find_row(&self, model: &Model, only: Option<SectionKind>, id: &str) -> Option<usize> {
        self.items.iter().position(|it| match it {
            NavItem::Row(kind, i) => {
                only.map_or(true, |k| k == *kind)
                    && model
                        .sections
                        .get(*kind)
                        .visible_rows()
                        .get(*i)
                        .map(|r| row_id(r) == id)
                        .unwrap_or(false)
            }
            NavItem::Header(_) => false,
        })
    }

    // selected_id: the stable id of the row under the cursor, if any - the id-only
    // handle. Reload anchors by SECTION + id via selected_place instead, so a
    // duplicate id elsewhere can't steal the cursor.
    pub fn selected_id(&self, model: &Model) -> Option<String> {
        self.selected_row(model).map(|(_, row)| row_id(row))
    }

    // selected_place: the section + stable id of the row under the cursor. Reload
    // captures this against the OLD model so it can re-find the SAME row in the
    // SAME section, so a duplicate id elsewhere never steals the cursor.
    pub fn selected_place(&self, model: &Model) -> Option<(SectionKind, String)> {
        self.selected_row(model).map(|(kind, row)| (kind, row_id(row)))
    }

    // --- movement -----------------------------------------------------------
    pub fn move_down(&mut self) {
        if self.cursor + 1 < self.items.len() {
            self.cursor += 1;
        }
    }

    pub fn move_up(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }

    pub fn move_first(&mut self) {
        self.cursor = 0;
    }

    pub fn move_last(&mut self) {
        self.cursor = self.items.len().saturating_sub(1);
    }

    // Jump to the next/previous section HEADER, so Tab and the bracket keys move
    // section-to-section rather than line-by-line. From anywhere in a section,
    // next lands on the following header (or the last item if none follows).
    pub fn next_section(&mut self) {
        let start = self.cursor;
        for i in (start + 1)..self.items.len() {
            if matches!(self.items[i], NavItem::Header(_)) {
                self.cursor = i;
                return;
            }
        }
    }

    pub fn prev_section(&mut self) {
        // The header at or before the cursor.
        let here = self.current_section_header();
        if let Some(h) = here {
            if h < self.cursor {
                // Inside a section: first jump lands on its own header.
                self.cursor = h;
                return;
            }
            // Already on a header: step to the previous one.
            for i in (0..h).rev() {
                if matches!(self.items[i], NavItem::Header(_)) {
                    self.cursor = i;
                    return;
                }
            }
        }
    }

    // Jump the cursor directly to a section's header, used by the single-key
    // section shortcuts. A no-op if that section is not currently shown.
    pub fn jump_to(&mut self, kind: SectionKind) -> bool {
        if let Some(i) = self
            .items
            .iter()
            .position(|it| matches!(it, NavItem::Header(k) if *k == kind))
        {
            self.cursor = i;
            true
        } else {
            false
        }
    }

    fn current_section_header(&self) -> Option<usize> {
        (0..=self.cursor.min(self.items.len().saturating_sub(1)))
            .rev()
            .find(|&i| matches!(self.items[i], NavItem::Header(_)))
    }

    // --- expand / collapse --------------------------------------------------
    // Toggle the fold of the section the cursor is in (from a header or any of
    // its rows). Collapsing keeps the cursor on the header so the captain sees
    // what he just folded; expanding leaves the cursor where it is.
    pub fn toggle_fold(&mut self, model: &Model) {
        let Some(item) = self.selected() else { return };
        let kind = match item {
            NavItem::Header(k) => k,
            NavItem::Row(k, _) => k,
        };
        let now = self.is_collapsed(kind);
        self.collapsed.insert(kind, !now);
        // Collapsing: park on the header before it stops existing as a row line.
        if !now {
            self.jump_to(kind);
        }
        self.rebuild(model);
    }

    // Direct fold control (used by tests and reserved for a WP-5 restore path).
    #[allow(dead_code)]
    pub fn set_collapsed(&mut self, kind: SectionKind, collapsed: bool, model: &Model) {
        self.collapsed.insert(kind, collapsed);
        self.rebuild(model);
    }

    // The row id at the cursor, if the cursor is on an openable row. This is the
    // handle detail.rs turns into an on-demand file read.
    pub fn selected_row<'a>(
        &self,
        model: &'a Model,
    ) -> Option<(SectionKind, &'a serde_json::Value)> {
        match self.selected()? {
            NavItem::Row(kind, i) => model
                .sections
                .get(kind)
                .visible_rows()
                .get(i)
                .map(|v| (kind, v)),
            NavItem::Header(_) => None,
        }
    }
}

// row_id: the id string carried by every row, the stable handle for drill-down.
pub fn row_id(row: &serde_json::Value) -> String {
    str_field(row, "id")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::parse;

    fn model() -> Model {
        // captains_call (2 rows), under_way empty (folds away), charted (2 rows),
        // landed (1), merge (2, always shown), secondmates (1).
        parse(
            r#"{
              "now":"t","header":{"summary":"s"},"gaps":[],
              "health":{"beat_age_seconds":30},
              "sections":{
                "captains_call":{"status":"ok","total":2,"shown":2,
                  "rows":[{"id":"cc-a","summary":"a"},{"id":"cc-b","summary":"b"}]},
                "under_way":{"status":"empty","total":0,"shown":0,"rows":[]},
                "charted":{"status":"ok","total":2,"shown":2,
                  "rows":[{"id":"ch-a","title":"a"},{"id":"ch-b","title":"b"}]},
                "landed":{"status":"ok","total":1,"shown":1,
                  "rows":[{"id":"la-a","what":"x"}]},
                "merge":{"total":2,"shown":2,
                  "rows":[{"id":"fm/one","branch":"fm/one","dest":"main"},
                          {"id":"fm/two","branch":"fm/two","dest":"dev"}]},
                "secondmates":{"status":"ok","total":1,"shown":1,
                  "rows":[{"id":"builder","doing":"y"}]}
              }
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn flattened_list_skips_empty_foldable_sections_and_keeps_paint_order() {
        let m = model();
        let nav = Nav::new(&m);
        // under_way is empty and foldable, so it never appears; the rest do, in
        // paint order, header then rows.
        let expected = vec![
            NavItem::Header(SectionKind::CaptainsCall),
            NavItem::Row(SectionKind::CaptainsCall, 0),
            NavItem::Row(SectionKind::CaptainsCall, 1),
            NavItem::Header(SectionKind::Charted),
            NavItem::Row(SectionKind::Charted, 0),
            NavItem::Row(SectionKind::Charted, 1),
            NavItem::Header(SectionKind::Landed),
            NavItem::Row(SectionKind::Landed, 0),
            NavItem::Header(SectionKind::Merge),
            NavItem::Row(SectionKind::Merge, 0),
            NavItem::Row(SectionKind::Merge, 1),
            NavItem::Header(SectionKind::Secondmates),
            NavItem::Row(SectionKind::Secondmates, 0),
        ];
        assert_eq!(nav.items(), expected.as_slice());
    }

    #[test]
    fn empty_ok_sections_fold_like_the_static_board() {
        // The no-cache empty_model path emits "sections":{}, so every section
        // defaults to status "ok" with zero rows. The four foldable sections must
        // fold away exactly like the static board's folded(); only the always-shown
        // captains_call and merge headers remain (each with no openable row).
        let m = parse(
            r#"{"now":"","header":{"summary":""},
              "health":{"beat_age_seconds":null},"sections":{}}"#,
        )
        .unwrap();
        let nav = Nav::new(&m);
        assert_eq!(
            nav.items(),
            [
                NavItem::Header(SectionKind::CaptainsCall),
                NavItem::Header(SectionKind::Merge),
            ]
            .as_slice()
        );
    }

    #[test]
    fn down_and_up_move_within_bounds() {
        let m = model();
        let mut nav = Nav::new(&m);
        assert_eq!(nav.cursor(), 0);
        nav.move_up(); // already at top: stays
        assert_eq!(nav.cursor(), 0);
        for _ in 0..100 {
            nav.move_down();
        }
        assert_eq!(nav.cursor(), nav.items().len() - 1); // clamped at the end
        nav.move_up();
        assert_eq!(nav.cursor(), nav.items().len() - 2);
        nav.move_first();
        assert_eq!(nav.cursor(), 0);
        nav.move_last();
        assert_eq!(nav.cursor(), nav.items().len() - 1);
    }

    // A model where the SAME id lives in both under_way and charted - a promotion
    // in flight (a gate becoming running work shows in both sections for one
    // projection). under_way x, charted [dup, ch-b], landed la, so charted's rows
    // are reachable only if the cursor does not snap up to under_way's copy.
    fn dup_id_model() -> Model {
        parse(
            r#"{"now":"t","header":{"summary":""},"health":{"beat_age_seconds":30},"sections":{
              "under_way":{"status":"ok","rows":[{"id":"dup","doing":"running now"}]},
              "charted":{"status":"ok","rows":[{"id":"dup","title":"still charted"},{"id":"ch-b","title":"b"}]},
              "landed":{"status":"ok","rows":[{"id":"la","what":"x"}]}
            }}"#,
        )
        .unwrap()
    }

    #[test]
    fn reload_keeps_the_cursor_in_charted_when_a_dup_id_sits_in_under_way() {
        // BUG: arrowing DOWN into charted snapped the cursor back UP into under_way,
        // walling off landed. Cause: reload resolved the selected id by scanning
        // every section and taking the first hit, so a promotion-in-flight dup id
        // (present in under_way AND charted) stole the cursor to under_way's copy.
        // A reload while the cursor sits on charted's "dup" row must keep it there,
        // and move_down must then reach landed - never jump back to under_way.
        let m = dup_id_model();
        let mut nav = Nav::new(&m);
        // Flattened: [UW hdr, UW dup, Charted hdr, Charted dup, Charted ch-b,
        // Landed hdr, Landed la]. Land the cursor on CHARTED's dup row (index 3).
        nav.jump_to(SectionKind::Charted);
        nav.move_down(); // charted "dup"
        assert!(
            matches!(nav.selected(), Some(NavItem::Row(SectionKind::Charted, 0))),
            "precondition: cursor on charted's dup row, got {:?}",
            nav.selected()
        );
        let prev = nav.selected_place(&m);

        // A background reload fires (same model shape). The cursor must stay on the
        // CHARTED dup row, not snap up to under_way's dup row.
        nav.reload(&m, prev.as_ref().map(|(k, id)| (*k, id.as_str())));
        assert!(
            matches!(nav.selected(), Some(NavItem::Row(SectionKind::Charted, 0))),
            "cursor must stay in charted after a reload, not snap up to under_way: {:?}",
            nav.selected()
        );

        // And landed stays reachable: down through ch-b, the Landed header, to la.
        nav.move_down();
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Row(SectionKind::Charted, 1))
        ));
        nav.move_down(); // Landed header
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Header(SectionKind::Landed))
        ));
        nav.move_down(); // landed row
        assert!(
            matches!(nav.selected(), Some(NavItem::Row(SectionKind::Landed, 0))),
            "landed must be reachable, got {:?}",
            nav.selected()
        );
    }

    #[test]
    fn reload_follows_a_row_that_actually_left_its_section() {
        // The section-scoped match must not trap the cursor: when the selected row
        // genuinely leaves its section (a gate promoted to under_way and gone from
        // charted), reload falls back to the any-section match and follows it.
        let before = dup_id_model();
        let mut nav = Nav::new(&before);
        nav.jump_to(SectionKind::Charted);
        nav.move_down(); // charted "dup"
        let prev = nav.selected_place(&before);
        // "dup" is now ONLY in under_way (the gate landed as running work).
        let after = parse(
            r#"{"now":"t","header":{"summary":""},"health":{"beat_age_seconds":30},"sections":{
              "under_way":{"status":"ok","rows":[{"id":"dup","doing":"running now"}]},
              "charted":{"status":"ok","rows":[{"id":"ch-b","title":"b"}]},
              "landed":{"status":"ok","rows":[{"id":"la","what":"x"}]}
            }}"#,
        )
        .unwrap();
        nav.reload(&after, prev.as_ref().map(|(k, id)| (*k, id.as_str())));
        assert!(
            matches!(nav.selected(), Some(NavItem::Row(SectionKind::UnderWay, 0))),
            "cursor should follow the row into under_way, got {:?}",
            nav.selected()
        );
    }

    #[test]
    fn collapsing_a_section_hides_its_rows_and_parks_on_the_header() {
        let m = model();
        let mut nav = Nav::new(&m);
        // Move onto a captains_call row, then fold: cursor returns to the header
        // and the two rows vanish from the list.
        nav.move_down(); // cc row 0
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Row(SectionKind::CaptainsCall, 0))
        ));
        nav.toggle_fold(&m);
        assert!(nav.is_collapsed(SectionKind::CaptainsCall));
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Header(SectionKind::CaptainsCall))
        ));
        assert!(!nav
            .items()
            .iter()
            .any(|it| matches!(it, NavItem::Row(SectionKind::CaptainsCall, _))));
        // Expanding restores them.
        nav.toggle_fold(&m);
        assert!(!nav.is_collapsed(SectionKind::CaptainsCall));
        assert_eq!(
            nav.items()
                .iter()
                .filter(|it| matches!(it, NavItem::Row(SectionKind::CaptainsCall, _)))
                .count(),
            2
        );
    }

    #[test]
    fn jump_and_section_hops_land_on_headers() {
        let m = model();
        let mut nav = Nav::new(&m);
        assert!(nav.jump_to(SectionKind::Merge));
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Header(SectionKind::Merge))
        ));
        // under_way is not shown, so a jump to it is a no-op that reports false.
        assert!(!nav.jump_to(SectionKind::UnderWay));
        nav.move_first();
        nav.next_section();
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Header(SectionKind::Charted))
        ));
        nav.prev_section();
        assert!(matches!(
            nav.selected(),
            Some(NavItem::Header(SectionKind::CaptainsCall))
        ));
    }

    #[test]
    fn rebuild_preserves_the_selected_item_across_a_model_reload() {
        let m = model();
        let mut nav = Nav::new(&m);
        nav.jump_to(SectionKind::Landed); // header
        nav.move_down(); // landed row 0
        let before = nav.selected();
        // A fresh model with the same shape must keep the cursor on the same item.
        nav.rebuild(&m);
        assert_eq!(nav.selected(), before);
    }

    #[test]
    fn selected_row_exposes_the_underlying_row_for_drilldown() {
        let m = model();
        let mut nav = Nav::new(&m);
        nav.jump_to(SectionKind::Merge);
        nav.move_down();
        let (kind, row) = nav.selected_row(&m).unwrap();
        assert_eq!(kind, SectionKind::Merge);
        assert_eq!(row_id(row), "fm/one");
        // A header has no openable row.
        nav.jump_to(SectionKind::Merge);
        assert!(nav.selected_row(&m).is_none());
    }

    // === WP-5 place preservation across a background reload =================
    // The hardest WP-5 requirement: a reload (a file-watch update) must not move
    // the captain's place. Cursor preservation is by STABLE ID, not slot, because
    // rows re-rank the moment a task changes state, so a slot-keyed cursor would
    // silently point at a different task after any update.

    // A model whose captains_call rows can be reordered, to prove id-stable
    // preservation. cc rows a,b,c; under_way x,y.
    fn abc_xy() -> Model {
        parse(
            r#"{"now":"t","header":{"summary":""},"health":{"beat_age_seconds":30},"sections":{
              "captains_call":{"status":"ok","rows":[{"id":"a","summary":"a"},{"id":"b","summary":"b"},{"id":"c","summary":"c"}]},
              "under_way":{"status":"ok","rows":[{"id":"x","doing":"x"},{"id":"y","doing":"y"}]}
            }}"#,
        )
        .unwrap()
    }

    #[test]
    fn reload_keeps_the_cursor_on_its_task_across_a_reorder() {
        let m = abc_xy();
        let mut nav = Nav::new(&m);
        // Select cc row "b" (header at 0, rows a,b,c at 1,2,3).
        nav.jump_to(SectionKind::CaptainsCall);
        nav.move_down();
        nav.move_down(); // row "b"
        assert_eq!(nav.selected_id(&m).as_deref(), Some("b"));
        let prev = nav.selected_place(&m);

        // A reload REORDERS captains_call (b now first) but still contains b.
        let reordered = parse(
            r#"{"now":"t","header":{"summary":""},"health":{"beat_age_seconds":30},"sections":{
              "captains_call":{"status":"ok","rows":[{"id":"b","summary":"b"},{"id":"a","summary":"a"},{"id":"c","summary":"c"}]},
              "under_way":{"status":"ok","rows":[{"id":"x","doing":"x"},{"id":"y","doing":"y"}]}
            }}"#,
        )
        .unwrap();
        nav.reload(&reordered, prev.as_ref().map(|(k, id)| (*k, id.as_str())));
        assert_eq!(
            nav.selected_id(&reordered).as_deref(),
            Some("b"),
            "cursor must stay on its task across a re-ranking reload"
        );
    }

    #[test]
    fn reload_preserves_section_folds() {
        let m = abc_xy();
        let mut nav = Nav::new(&m);
        nav.set_collapsed(SectionKind::CaptainsCall, true, &m);
        assert!(nav.is_collapsed(SectionKind::CaptainsCall));
        let prev = nav.selected_place(&m);
        nav.reload(&m, prev.as_ref().map(|(k, id)| (*k, id.as_str())));
        assert!(
            nav.is_collapsed(SectionKind::CaptainsCall),
            "a reload must not reopen a section the captain folded"
        );
        assert!(!nav
            .items()
            .iter()
            .any(|it| matches!(it, NavItem::Row(SectionKind::CaptainsCall, _))));
    }

    #[test]
    fn reload_slides_to_a_neighbor_when_the_selected_task_vanishes() {
        let m = abc_xy();
        let mut nav = Nav::new(&m);
        nav.jump_to(SectionKind::CaptainsCall);
        nav.move_down();
        nav.move_down(); // row "b"
        let prev = nav.selected_place(&m);
        // b vanishes; a and c remain. The cursor must not jump to the top; it
        // stays in range on a graceful neighbor.
        let no_b = parse(
            r#"{"now":"t","header":{"summary":""},"health":{"beat_age_seconds":30},"sections":{
              "captains_call":{"status":"ok","rows":[{"id":"a","summary":"a"},{"id":"c","summary":"c"}]},
              "under_way":{"status":"ok","rows":[{"id":"x","doing":"x"},{"id":"y","doing":"y"}]}
            }}"#,
        )
        .unwrap();
        nav.reload(&no_b, prev.as_ref().map(|(k, id)| (*k, id.as_str())));
        // The selection is still a real, openable row (not lost, not a header),
        // and it is NOT the vanished task.
        let sel = nav.selected_id(&no_b);
        assert!(sel.is_some(), "cursor should land on a surviving row");
        assert_ne!(
            sel.as_deref(),
            Some("b"),
            "must not point at the vanished task"
        );
    }
}
