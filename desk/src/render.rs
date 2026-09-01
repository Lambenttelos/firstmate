// Painting the fm-desk.v1 model into terminal lines (WP-3 core render).
//
// This is the crate's ONLY concern here: turn the parsed model into ratatui
// Lines. It does NOT rank, cap, or re-derive state - the lib already did all of
// that (the one-owner rule). It paints at most `shown` rows and the "+N more"
// pointer for the tail, exactly like the bash board (bin/fm-desk-tui.sh).
//
// The established visual language is carried verbatim from that board:
//   - a status circle leads each row (U+25CF colored with color; a DISTINCT
//     ASCII char per class without, so shape alone conveys state - never
//     color-alone),
//   - NO forge/Bitbucket URLs (the merge section drops the ~95-char compare URL),
//   - the WIDTH GUARANTEE: no painted line exceeds the pane width, enforced by
//     clip_line - the ONE width owner every line passes through (mirrors the bash
//     board's clip_frame). Width is counted in characters (Unicode scalars), one
//     column each, matching that board's per-character measure; ratatui keeps
//     style separate from text, so the painted width is identical color on or off.

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use crate::model::{str_field, Model, Section, SectionKind};
use crate::nav::{folds_away, section_is_shown, Nav, NavItem};

pub struct Painter {
    pub cols: u16,
    pub color: bool,
    // Pane height in rows, when known (the interactive path). None on a pipe or
    // when a caller does not bound height, in which case a fixed per-section cap
    // keeps the board terse. The cached model is stored UNCAPPED (shown=total),
    // so this crate owns the display cap, mirroring the bash board's fit.
    pub rows: Option<u16>,
}

// The default per-section row cap when no pane height bounds the board. Matches
// the bash desk's DESK_CAP default so a piped board collapses identically.
const DEFAULT_CAP: usize = 6;

// The column budget every account line the MODEL composes is already within. This
// is a MIRROR of DESK_ACCOUNT_COLS in bin/fm-desk-lib.sh, which is the one owner
// of the number; tests/fm-desk-lib.test.sh asserts the two agree, so the pair
// cannot drift. It is 80 - the pane width the captain reads over SSH, and what
// clip_line cuts at - minus the WIDEST chrome any surface prepends to an account
// row: 2 for the bullet on the static board (and the bash board), 4 for the nav
// board's gutter+bullet, and 5 for the switch overlay's "  " + 3-column number
// key, which is the tightest. Kept here so this crate's own tests can prove the
// invariant on every surface it paints.
pub const ACCOUNT_LINE_COLS: usize = 75;

// Indent applied to a wrapped continuation row so a wrapped line stays visually
// distinct from the next item (a wall of flush-left wrapped text is its own
// legibility failure). Two columns, matching the board's existing row indent.
const WRAP_INDENT: usize = 2;

impl Painter {
    pub fn new(cols: u16, color: bool) -> Self {
        // Floor at 20 so even a hostile pane still lays out a status glyph plus a
        // few characters rather than collapsing to nothing.
        Painter {
            cols: cols.max(20),
            color,
            rows: None,
        }
    }

    // with_rows: bound the board to a pane height so it stays terse and does not
    // overflow (legibility over density; the main view is terse because drill-down
    // is coming). The interactive path passes the real pane height.
    pub fn with_rows(cols: u16, color: bool, rows: u16) -> Self {
        Painter {
            cols: cols.max(20),
            color,
            rows: Some(rows),
        }
    }

    // frame: the whole board, in paint order, every line already width-clipped.
    // `note` is an optional honest data-source footnote (staleness, or a fallback
    // notice) painted dim right under the header summary.
    pub fn frame(&self, model: &Model, note: Option<&str>) -> Vec<Line<'static>> {
        let cap = self.section_cap(model, note);
        let mut out: Vec<Line<'static>> = Vec::new();
        self.header(model, &mut out);
        if let Some(n) = note {
            if !n.is_empty() {
                out.push(Line::from(Span::styled(clean(n), self.dim())));
            }
        }
        self.gaps(model, self.cols as usize, &mut out);
        self.captains_call(model, cap, &mut out);
        self.under_way(model, cap, &mut out);
        self.charted(model, cap, &mut out);
        self.landed(model, cap, &mut out);
        self.merge(model, cap, &mut out);
        self.secondmates(model, cap, &mut out);
        self.health(model, &mut out);
        out.into_iter().map(|l| self.clip_line(l)).collect()
    }

    // --- vertical fit (this crate owns the static-board display cap) --------
    // The cached model is stored UNCAPPED (shown=total, cap=0), so the static
    // board must cap rows itself or it would dump 20+ rows per section and
    // overflow the pane (legibility over density; the terse main view is terse
    // because drill-down is one keystroke away). This mirrors the bash board's
    // desk_fit: fixed chrome is subtracted,
    // then rows are filled round-robin in priority order against the pane's line
    // budget, so a shorter pane shows fewer rows and no section is silently cut off
    // the bottom. Without a known pane height a fixed per-section cap keeps it terse.
    //
    // Returns the number of rows to SHOW for each section, in paint order:
    // [captains_call, under_way, charted, landed, merge, secondmates].
    fn section_cap(&self, model: &Model, note: Option<&str>) -> [usize; 6] {
        let secs = self.ordered_sections(model);
        // No pane height: a fixed cap per section (matches the bash DESK_CAP=6).
        let budget = match self.rows {
            None => {
                let mut caps = [0usize; 6];
                for (i, s) in secs.iter().enumerate() {
                    caps[i] = DEFAULT_CAP.min(s.rows.len());
                }
                return caps;
            }
            Some(h) => h as i64,
        };

        // Fixed chrome the board always pays: title + summary, plus the note and
        // the usage line when header() paints them.
        let note_lines = note.map(|n| !n.is_empty() as i64).unwrap_or(0);
        let usage = model
            .header
            .usage
            .as_ref()
            .map_or(0, |u| !u.line.is_empty() as i64);
        // The accounts block is fixed chrome the fill loop must reserve: a caption
        // line plus one line per account, exactly what header() paints. Without
        // reserving it the loop seats rows the accounts then push off the pane.
        let accounts = model.header.accounts.as_ref().map_or(0, |a| {
            if a.lines.is_empty() {
                0
            } else {
                a.lines.len() as i64 + (!a.caption.is_empty() as i64)
            }
        });
        // The token-cost glance is one chrome line the static header paints (the
        // interactive "press $" hint is not painted on the static board, so only
        // the line itself is reserved here). Without reserving it the fill loop
        // would seat a row the cost line then pushes off the pane.
        let token_cost = model
            .header
            .token_cost
            .as_ref()
            .map_or(0, |t| !t.line.is_empty() as i64);
        let header = 2 + note_lines + usage + accounts + token_cost;
        let gaps = if model.gaps.is_empty() {
            0
        } else {
            3 + model.gaps.len() as i64
        };
        let health = if self.health_line(model).is_some() {
            1
        } else {
            0
        };
        let mut avail = budget - header - gaps - health;

        // captains_call (idx 0) and merge (idx 4) always render: reserve their rule
        // (3) plus one trailing line (an empty message or a "+N more" pointer).
        const ALWAYS: [usize; 2] = [0, 4];
        let mut shown = [0usize; 6];
        for (i, s) in secs.iter().enumerate() {
            let st = s.status();
            if st == "gap" || st == "away" {
                avail -= 4; // rule + one gap line; always rendered
            } else if ALWAYS.contains(&i) {
                avail -= 4; // rule + one trailing (empty or "+N more")
            }
            // foldable empty sections and foldable ok sections pay their rule only
            // when they seat a row, handled in the fill below.
        }

        // Round-robin: walk the sections in priority order, adding one row wherever
        // the marginal cost fits, until a whole pass adds nothing. Balances the
        // glance across the fleet rather than letting one section eat the budget.
        loop {
            let mut advanced = false;
            for (i, s) in secs.iter().enumerate() {
                if s.status() != "ok" {
                    continue;
                }
                let total = s.rows.len();
                if shown[i] >= total {
                    continue;
                }
                // Marginal cost of the next row: its own line cost, plus this
                // section's rule (3) the first time it seats a row (foldable
                // sections only - always sections already reserved their rule).
                let (this_rows, this_lines) = self.rowcost_prefix(i, s, shown[i] + 1);
                let (prev_rows, prev_lines) = self.rowcost_prefix(i, s, shown[i]);
                debug_assert_eq!(this_rows, shown[i] + 1);
                debug_assert_eq!(prev_rows, shown[i]);
                let mut delta = this_lines as i64 - prev_lines as i64;
                if shown[i] == 0 && !ALWAYS.contains(&i) {
                    // A foldable section appearing now costs its rule (3) plus one
                    // trailing "+N more" line. Reserving the more-line up front can
                    // over-budget by 1 only when the section ends up showing ALL its
                    // rows (no tail); that wastes a line, never overflows the pane.
                    delta += 3 + 1;
                }
                if delta <= avail {
                    avail -= delta;
                    shown[i] += 1;
                    advanced = true;
                }
            }
            if !advanced {
                break;
            }
        }
        shown
    }

    // ordered_sections: the six sections in paint order.
    fn ordered_sections<'a>(&self, m: &'a Model) -> [&'a Section; 6] {
        [
            &m.sections.captains_call,
            &m.sections.under_way,
            &m.sections.charted,
            &m.sections.landed,
            &m.sections.merge,
            &m.sections.secondmates,
        ]
    }

    // rowcost_prefix: (rows, physical lines) for the first `n` rows of section idx.
    // Line cost mirrors what each section paints: a lead line (1) plus a detail
    // body line for charted (a why) and landed (an artifact) when present.
    fn rowcost_prefix(&self, idx: usize, s: &Section, n: usize) -> (usize, usize) {
        let n = n.min(s.rows.len());
        let mut lines = 0usize;
        for r in &s.rows[..n] {
            lines += 1; // the lead line
            match idx {
                2 => {
                    // charted: a why body line when blocked_by or reason is present
                    let blocked_by = str_field(r, "blocked_by");
                    let reason = str_field(r, "reason");
                    let has_why = (!blocked_by.is_empty() && blocked_by != "-")
                        || (!reason.is_empty() && reason != "-");
                    if has_why {
                        lines += 1;
                    }
                }
                3 => {
                    // landed: an artifact body line when present
                    let artifact = str_field(r, "artifact");
                    if !artifact.is_empty() && artifact != "-" {
                        lines += 1;
                    }
                }
                _ => {}
            }
        }
        (n, lines)
    }

    // === WP-4: nav-aware board ==============================================
    // nav_frame paints the SAME board as frame(), but selection-aware: every line
    // carries a 2-col gutter ("> " on the selected item, "  " otherwise) so the
    // cursor is visible even without color, the selected line is reverse-video'd
    // when color is on, and a collapsed section hides its rows behind a dim
    // "(N hidden)" marker. Sections and rows are walked in EXACTLY nav's flattened
    // order, so the highlighted line and nav.selected() are always the same item.
    pub fn nav_frame(&self, model: &Model, nav: &Nav, note: Option<&str>) -> Vec<Line<'static>> {
        let selected = nav.selected();
        let mut tagged: Vec<(Line<'static>, Option<NavItem>)> = Vec::new();

        // Chrome (untagged): title + summary + optional note. The interactive
        // header adds the "press w to switch" hint under the accounts block.
        let mut chrome: Vec<Line<'static>> = Vec::new();
        self.header_ext(model, true, &mut chrome);
        if let Some(n) = note {
            if !n.is_empty() {
                chrome.push(Line::from(Span::styled(clean(n), self.dim())));
            }
        }
        self.gaps(model, (self.cols as usize).saturating_sub(2), &mut chrome);
        for l in chrome {
            tagged.push((l, None));
        }

        for kind in SectionKind::all() {
            let s = model.sections.get(kind);
            if !section_is_shown(kind, s) {
                continue;
            }
            self.nav_section(kind, s, nav, &mut tagged);
        }

        // Health footer (untagged).
        let mut footer: Vec<Line<'static>> = Vec::new();
        self.health(model, &mut footer);
        for l in footer {
            tagged.push((l, None));
        }

        // Apply the gutter + selection highlight, then the width guarantee. The
        // SELECTED row wraps instead of clipping so the captain can read the full
        // focused item in place; unselected rows stay one terse line (drill-down
        // holds their full text). Wrapping only the focused row keeps the board
        // compact and leaves the static-board height budget (fm-desk-lib.sh phys())
        // untouched, since that budget governs the --once path, not this viewport.
        tagged
            .into_iter()
            .flat_map(|(line, tag)| {
                let is_sel = tag.is_some() && tag == selected;
                let gutted = self.with_gutter(line, is_sel);
                if is_sel {
                    // Wrap first (continuation rows indented past the gutter), then
                    // clip each as the width backstop.
                    wrap_line(&gutted, self.cols as usize, WRAP_INDENT + 2)
                        .into_iter()
                        .map(|l| self.clip_line(l))
                        .collect::<Vec<_>>()
                } else {
                    vec![self.clip_line(gutted)]
                }
            })
            .collect()
    }

    // nav_section: a section's header (tagged, with a fold marker) followed by its
    // rows (each tagged) when expanded, or a dim "(N hidden)" line when collapsed.
    fn nav_section(
        &self,
        kind: SectionKind,
        s: &Section,
        nav: &Nav,
        out: &mut Vec<(Line<'static>, Option<NavItem>)>,
    ) {
        let collapsed = nav.is_collapsed(kind);
        // Spacer + title (tagged Header) + rule. The title carries a fold marker
        // only when the section actually has rows to fold.
        out.push((Line::from(""), None));
        let has_rows = !matches!(s.status(), "gap" | "away" | "empty") && !s.rows.is_empty();
        let marker = if !has_rows {
            ""
        } else if collapsed {
            " [+]"
        } else {
            " [-]"
        };
        // Fold the section's TRUE item count into the title, the same " (N)" the
        // shell board and the static board (rule_counted) paint, so no two boards
        // disagree on a section's size. Only a populated (ok) section is counted.
        let title = if s.status() == "ok" && s.full_total > 0 {
            format!("{} ({})", section_title(kind), s.full_total)
        } else {
            section_title(kind).to_string()
        };
        out.push((
            Line::from(vec![
                Span::styled(title, self.head_style()),
                Span::styled(marker.to_string(), self.dim()),
            ]),
            Some(NavItem::Header(kind)),
        ));
        let dashes: String = "-".repeat((self.cols as usize).saturating_sub(2));
        out.push((
            Line::from(Span::styled(
                dashes,
                self.st(Style::default().fg(Color::Blue)),
            )),
            None,
        ));

        match s.status() {
            "gap" | "away" => {
                out.push((self.plain_gap_line(gap_text(s)), None));
                return;
            }
            "empty" => {
                out.push((self.plain_empty_line(&empty_sentence(kind, s)), None));
                return;
            }
            _ => {}
        }
        if s.visible_rows().is_empty() {
            out.push((self.plain_empty_line(&empty_sentence(kind, s)), None));
            return;
        }
        if collapsed {
            let n = s.visible_rows().len();
            out.push((
                self.plain_empty_line(&format!("({n} hidden - space to expand)")),
                None,
            ));
            return;
        }
        for (i, r) in s.visible_rows().iter().enumerate() {
            let (head, id, meta, bullet, body) = row_fields(kind, r);
            out.push((
                self.nav_row_line(&head, &id, &meta, &bullet),
                Some(NavItem::Row(kind, i)),
            ));
            if !body.is_empty() {
                out.push((Line::from(format!("        {}", clean(&body))), None));
            }
        }
        if s.more > 0 && !s.more_hint.is_empty() {
            out.push((
                Line::from(vec![
                    Span::raw("  "),
                    Span::styled(clean(&s.more_hint), self.dim()),
                ]),
                None,
            ));
        }
    }

    // nav_row_line: a single headline for a row (never multi-line), styled like
    // lead_line but always exactly one Line so selection highlight is 1:1.
    fn nav_row_line(&self, head: &str, id: &str, meta: &str, bull: &str) -> Line<'static> {
        let mut spans: Vec<Span<'static>> = if bull.is_empty() {
            vec![Span::raw("  ")]
        } else {
            self.bullet_spans(bull)
        };
        if !head.is_empty() {
            spans.push(Span::styled(clean(head), self.bold()));
            spans.push(Span::raw("  "));
            spans.push(Span::styled(clean(id), self.dim()));
        } else {
            spans.push(Span::styled(
                clean(id),
                self.st(Style::default().fg(Color::Cyan)),
            ));
        }
        if !meta.is_empty() {
            spans.push(Span::raw("  "));
            spans.push(Span::styled(clean(meta), self.dim()));
        }
        Line::from(spans)
    }

    fn plain_gap_line(&self, text: &str) -> Line<'static> {
        Line::from(vec![
            Span::raw("  "),
            Span::styled(clean(text), self.st(Style::default().fg(Color::Yellow))),
        ])
    }
    fn plain_empty_line(&self, text: &str) -> Line<'static> {
        Line::from(vec![Span::raw("  "), Span::styled(clean(text), self.dim())])
    }

    // with_gutter: prepend the 2-col selection gutter and, when selected and color
    // is on, reverse-video the whole line so the cursor is unmistakable. Without
    // color the "> " gutter alone carries selection (never color-alone).
    fn with_gutter(&self, line: Line<'static>, selected: bool) -> Line<'static> {
        let gutter = if selected { "> " } else { "  " };
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
        let gutter_style = if selected {
            self.bold()
        } else {
            Style::default()
        };
        spans.push(Span::styled(gutter.to_string(), gutter_style));
        for s in line.spans.into_iter() {
            let style = if selected && self.color {
                s.style.add_modifier(Modifier::REVERSED)
            } else {
                s.style
            };
            spans.push(Span::styled(s.content.into_owned(), style));
        }
        Line::from(spans)
    }

    // === WP-4: detail (drill-down) overlay =================================
    // detail_frame paints the on-demand-read file body for the opened item: a
    // title, a rule, then the raw file content scrolled to `scroll`. This is the
    // "read the full thing" surface, so its body WRAPS rather than truncating: a
    // line wider than the pane continues on the next row (indented) instead of
    // vanishing off the right edge. `scroll` counts WRAPPED rows, so the scroll
    // math must use wrapped_body (detail_wrapped_len) as its total.
    pub fn detail_frame(
        &self,
        title: &str,
        body: &str,
        scroll: usize,
        height: u16,
    ) -> Vec<Line<'static>> {
        let mut out: Vec<Line<'static>> = Vec::new();
        out.push(Line::from(vec![
            Span::styled("Detail  ".to_string(), self.bold()),
            Span::styled(clean(title), self.dim()),
        ]));
        out.push(Line::from(Span::styled(
            "-".repeat(self.cols as usize),
            self.st(Style::default().fg(Color::Blue)),
        )));
        let body_rows = (height as usize).saturating_sub(3).max(1);
        let wrapped = self.wrap_body(body);
        let total = wrapped.len();
        let start = scroll.min(total.saturating_sub(1));
        for l in wrapped.into_iter().skip(start).take(body_rows) {
            out.push(l);
        }
        // A dim footer showing scroll position and the keys that always work here.
        let shown_end = (start + body_rows).min(total);
        out.push(Line::from(Span::styled(
            format!(
                "lines {}-{} of {}  -  j/k or arrows scroll, Esc/h back, q quit, ? help",
                start + 1,
                shown_end,
                total
            ),
            self.dim(),
        )));
        out.into_iter().map(|l| self.clip_line(l)).collect()
    }

    // wrap_body: turn a raw multi-line body into the wrapped rows the detail/cost
    // overlays paint, so no line is lost off the right edge. Each source line is
    // cleaned then wrapped to the pane width; a continuation row is indented so it
    // reads as a wrap rather than a new line. Empty in -> one empty row (never a
    // zero-height body the scroll math would divide against).
    fn wrap_body(&self, body: &str) -> Vec<Line<'static>> {
        let mut out: Vec<Line<'static>> = Vec::new();
        for raw in body.lines() {
            let line = Line::from(clean(raw));
            for w in wrap_line(&line, self.cols as usize, WRAP_INDENT) {
                out.push(w);
            }
        }
        if out.is_empty() {
            out.push(Line::from(String::new()));
        }
        out
    }

    // detail_wrapped_len: how many WRAPPED rows the detail body occupies at this
    // pane width. The interactive scroll clamp (main.rs) needs this so j/k can
    // reach the tail of a body that wrapping made taller than its source lines.
    pub fn detail_wrapped_len(&self, body: &str) -> usize {
        self.wrap_body(body).len()
    }

    // === cost overlay: the spend and efficiency drill-down =================
    // The main board carries only the one terse cost glance line; this overlay
    // holds the full breakdown (burn, cache-hit ratio, heaviest engines, and cost
    // per landed ticket) the captain reaches with $. The body is PRE-RENDERED by
    // the MODEL (the lib), so both boards show identical detail and this crate
    // never re-costs a token - it lays out the lines the model already built.
    // Mirrors detail_frame's scroll + footer so the two overlays feel the same,
    // wrapping included: `scroll` counts WRAPPED rows (cost_wrapped_len).
    pub fn cost_frame(&self, detail: &[String], scroll: usize, height: u16) -> Vec<Line<'static>> {
        let mut out: Vec<Line<'static>> = Vec::new();
        out.push(Line::from(vec![
            Span::styled("Spend  ".to_string(), self.bold()),
            Span::styled("token cost and efficiency".to_string(), self.dim()),
        ]));
        out.push(Line::from(Span::styled(
            "-".repeat(self.cols as usize),
            self.st(Style::default().fg(Color::Blue)),
        )));
        // When the model carried no detail (should not happen when a line exists),
        // say so honestly rather than painting a blank pane.
        let body = if detail.is_empty() {
            "no cost detail available".to_string()
        } else {
            detail.join("\n")
        };
        let body_rows = (height as usize).saturating_sub(3).max(1);
        let wrapped = self.wrap_body(&body);
        let total = wrapped.len();
        let start = scroll.min(total.saturating_sub(1));
        for l in wrapped.into_iter().skip(start).take(body_rows) {
            out.push(l);
        }
        let shown_end = (start + body_rows).min(total);
        out.push(Line::from(Span::styled(
            format!(
                "lines {}-{} of {}  -  j/k or arrows scroll, Esc/$ back, q quit, ? help",
                start + 1,
                shown_end,
                total
            ),
            self.dim(),
        )));
        out.into_iter().map(|l| self.clip_line(l)).collect()
    }

    // cost_wrapped_len: wrapped-row count for the cost body, so the interactive
    // scroll clamp reaches the tail after wrapping. Mirrors detail_wrapped_len.
    pub fn cost_wrapped_len(&self, detail: &[String]) -> usize {
        let body = if detail.is_empty() {
            "no cost detail available".to_string()
        } else {
            detail.join("\n")
        };
        self.wrap_body(&body).len()
    }

    // === WP-4: help overlay ===============================================
    pub fn help_frame(&self) -> Vec<Line<'static>> {
        let mut out: Vec<Line<'static>> = Vec::new();
        out.push(Line::from(Span::styled(
            "Captain's desk - keys".to_string(),
            self.bold(),
        )));
        out.push(Line::from(Span::styled(
            "-".repeat(self.cols as usize),
            self.st(Style::default().fg(Color::Blue)),
        )));
        for (k, d) in HELP_KEYS {
            out.push(Line::from(vec![
                Span::styled(format!("  {k:<12}"), self.bold()),
                Span::raw(clean(d)),
            ]));
        }
        out.push(Line::from(""));
        out.push(Line::from(Span::styled(
            "  press ? or Esc to close".to_string(),
            self.dim(),
        )));
        out.into_iter().map(|l| self.clip_line(l)).collect()
    }

    // === switch overlay: pick a Claude account, then confirm ================
    // Three phases share this frame. In Pick, one row per account is listed with
    // a number key; the caption restates the honesty caveat and the GLOBAL scope.
    // In Confirm, the chosen account and the exact consequence are shown with a
    // y/n prompt. In Applied, the switch has landed on the jcode plane and the
    // frame states plainly that running sessions keep their old account until
    // they are restarted, so the captain is never left to assume it took effect
    // live. The whole overlay is keyboard-driven; main.rs owns the keys.
    // `entries` is (key label, account line); `confirm` is Some(email) in the
    // confirm phase; `applied` is Some(email) in the applied phase and wins over
    // `confirm`. `status` carries an in-progress or result message.
    pub fn switch_frame(
        &self,
        entries: &[(String, String)],
        confirm: Option<&str>,
        applied: Option<&str>,
        status: Option<&str>,
    ) -> Vec<Line<'static>> {
        let mut out: Vec<Line<'static>> = vec![
            Line::from(Span::styled(
                "Switch the global Claude account (jcode plane)".to_string(),
                self.bold(),
            )),
            Line::from(Span::styled(
                "-".repeat(self.cols as usize),
                self.st(Style::default().fg(Color::Blue)),
            )),
            // The honest scope caveat: this is a GLOBAL config change, and it
            // does not move an already-running session.
            Line::from(Span::styled(
                "Global switch. A running session keeps its account until it restarts.".to_string(),
                self.dim(),
            )),
            Line::from(""),
        ];
        if let Some(email) = applied {
            // The switch already edited ~/.jcode/auth.json. A live jcode caches
            // its token in process and reads auth only at start, so the ONLY
            // honest thing to say here is that a restart is required.
            out.push(Line::from(format!(
                "Switched the jcode plane to {}.",
                clean(email)
            )));
            out.push(Line::from(""));
            out.push(Line::from(Span::styled(
                "  Restart to apply: running jcode sessions keep the old account until restarted."
                    .to_string(),
                self.st(Style::default().fg(Color::Yellow)),
            )));
            out.push(Line::from(""));
            out.push(Line::from(Span::styled(
                "  press Esc to close".to_string(),
                self.dim(),
            )));
        } else if let Some(email) = confirm {
            out.push(Line::from(format!(
                "Switch the jcode plane (~/.jcode/auth.json) to {}?",
                clean(email)
            )));
            out.push(Line::from(Span::styled(
                "  This is the plane the fleet runs on. It takes effect on restart, not live."
                    .to_string(),
                self.dim(),
            )));
            out.push(Line::from(""));
            out.push(Line::from(Span::styled(
                "  y confirm    n / Esc cancel".to_string(),
                self.dim(),
            )));
        } else if entries.is_empty() {
            // The overlay always opens (main.rs `w`), even with no accounts, so
            // say so plainly instead of a pick prompt with nothing to pick.
            out.push(Line::from(Span::styled(
                "  no accounts to switch".to_string(),
                self.dim(),
            )));
            out.push(Line::from(""));
            out.push(Line::from(Span::styled(
                "  press Esc to close".to_string(),
                self.dim(),
            )));
        } else {
            for (k, line) in entries {
                out.push(Line::from(vec![
                    Span::styled(format!("  {k:<3}"), self.bold()),
                    Span::raw(clean(line)),
                ]));
            }
            out.push(Line::from(""));
            out.push(Line::from(Span::styled(
                "  press a number to pick, Esc to cancel".to_string(),
                self.dim(),
            )));
        }
        if let Some(s) = status {
            if !s.is_empty() {
                out.push(Line::from(""));
                out.push(Line::from(Span::styled(
                    format!("  {}", clean(s)),
                    self.st(Style::default().fg(Color::Yellow)),
                )));
            }
        }
        out.into_iter().map(|l| self.clip_line(l)).collect()
    }

    fn st(&self, base: Style) -> Style {
        if self.color {
            base
        } else {
            Style::default()
        }
    }
    fn bold(&self) -> Style {
        // Bold is a shape cue, not color, so keep it even without color.
        Style::default().add_modifier(Modifier::BOLD)
    }
    fn dim(&self) -> Style {
        Style::default().add_modifier(Modifier::DIM)
    }
    fn head_style(&self) -> Style {
        self.st(Style::default().fg(Color::Blue))
            .add_modifier(Modifier::BOLD)
    }

    // --- chrome -------------------------------------------------------------
    // rule: a blank spacer, the bold blue title, then a full-width dash rule.
    fn rule(&self, title: &str, out: &mut Vec<Line<'static>>) {
        self.rule_w(title, self.cols as usize, out);
    }

    // rule_counted: a section header that folds the section's TRUE item count into
    // the title as " (N)", matching the shell board (bin/fm-desk-tui.sh rule()).
    // The captain reads the section size off a header he already scans. The count
    // is painted only for a populated (ok) section; an empty/gap/away section says
    // its own thing and gets no "(0)". full_total (not the ranked rows.len()) is
    // the honest total, so a DESK_MAX/cap bound never makes the header lie.
    fn rule_counted(&self, title: &str, s: &Section, out: &mut Vec<Line<'static>>) {
        if s.status() == "ok" && s.full_total > 0 {
            self.rule(&format!("{title} ({})", s.full_total), out);
        } else {
            self.rule(title, out);
        }
    }

    // rule_w: like rule but with an explicit dash width, so the nav frame can
    // reserve its 2-col selection gutter and still keep the rule within cols.
    fn rule_w(&self, title: &str, width: usize, out: &mut Vec<Line<'static>>) {
        out.push(Line::from(""));
        out.push(Line::from(Span::styled(
            title.to_string(),
            self.head_style(),
        )));
        let dashes: String = "-".repeat(width);
        out.push(Line::from(Span::styled(
            dashes,
            self.st(Style::default().fg(Color::Blue)),
        )));
    }

    // header: title, summary, the optional usage line, and the accounts block.
    // `interactive` gates the "press w to switch" hint: the w key only does
    // anything on the interactive nav board, so the static/piped board (--once,
    // where no key can be pressed) must not claim it can (legibility + honesty).
    fn header(&self, m: &Model, out: &mut Vec<Line<'static>>) {
        self.header_ext(m, false, out);
    }

    fn header_ext(&self, m: &Model, interactive: bool, out: &mut Vec<Line<'static>>) {
        out.push(Line::from(vec![
            Span::styled("Captain's desk".to_string(), self.bold()),
            Span::raw("  "),
            Span::styled(format!("as of {}", clean(&m.now)), self.dim()),
        ]));
        out.push(Line::from(clean(&m.header.summary)));
        // ITEM 4: the captain's Claude usage, one dim line, only when present.
        if let Some(u) = &m.header.usage {
            if !u.line.is_empty() {
                out.push(Line::from(Span::styled(clean(&u.line), self.dim())));
            }
        }
        // The captain's Claude accounts: a dim caption then one line per account,
        // each pre-rendered by the MODEL so both boards paint identical text. The
        // caption states the honesty caveat (configured store, not the live token).
        // Each line leads with a usage-severity bullet (same vocabulary as row
        // bullets: green headroom, yellow tight, red spent) so which account has
        // room is clear at a glance; the bullet carries a distinct ascii shape
        // without color, so a NO_COLOR or colour-blind reader still reads state.
        if let Some(a) = &m.header.accounts {
            if !a.lines.is_empty() {
                if !a.caption.is_empty() {
                    out.push(Line::from(Span::styled(clean(&a.caption), self.dim())));
                }
                for (i, l) in a.lines.iter().enumerate() {
                    let class = a.line_classes.get(i).map(String::as_str).unwrap_or("idle");
                    let mut spans = self.bullet_spans(class);
                    // Colour each window's token (5h and 7d) from its OWN class the
                    // model computed, splitting the pre-rendered line on the exact
                    // token substrings the lib baked in. The token already carries
                    // its ascii shape glyph, so a NO_COLOR reader still reads state.
                    let ft = a.five_hour_tokens.get(i).map(String::as_str).unwrap_or("");
                    let fc = a.five_hour_classes.get(i).map(String::as_str).unwrap_or("idle");
                    let st = a.seven_day_tokens.get(i).map(String::as_str).unwrap_or("");
                    let sc = a.seven_day_classes.get(i).map(String::as_str).unwrap_or("idle");
                    self.account_line_spans(l, ft, fc, st, sc, &mut spans);
                    out.push(Line::from(spans));
                }
                // The switch key is otherwise only discoverable in the ? help
                // overlay, which is why the captain never found it. Name it right
                // under the block he already reads - but only on the interactive
                // board, since the key does nothing on a static/piped render.
                if interactive {
                    out.push(Line::from(Span::styled(
                        "  press w to switch the global Claude account".to_string(),
                        self.dim(),
                    )));
                }
            }
        }
        // The token-cost glance: one dim line (burn + the if-API/billed/covered
        // split + cache-hit), only when present. The heaviest engines and the
        // cost-per-landed-ticket breakdown live in the drill-down (the $ overlay),
        // keeping the main view terse (legibility over density). On the interactive
        // board a hint names the key; on a static/piped render the key does nothing
        // so no hint is claimed.
        if let Some(t) = &m.header.token_cost {
            if !t.line.is_empty() {
                out.push(Line::from(Span::styled(clean(&t.line), self.dim())));
                if interactive {
                    out.push(Line::from(Span::styled(
                        "  press $ for the spend and efficiency breakdown".to_string(),
                        self.dim(),
                    )));
                }
            }
        }
    }

    fn gaps(&self, m: &Model, rule_width: usize, out: &mut Vec<Line<'static>>) {
        if m.gaps.is_empty() {
            return;
        }
        self.rule_w("Some of this board is missing", rule_width, out);
        for g in &m.gaps {
            self.gap_line(g, out);
        }
    }

    // gap_line / empty_line: the explicit degraded markers, 2-col indent.
    fn gap_line(&self, text: &str, out: &mut Vec<Line<'static>>) {
        out.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(clean(text), self.st(Style::default().fg(Color::Yellow))),
        ]));
    }
    fn empty_line(&self, text: &str, out: &mut Vec<Line<'static>>) {
        out.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(clean(text), self.dim()),
        ]));
    }
    // body_line: an indented (6-col) plain content line.
    fn body_line(&self, text: &str, out: &mut Vec<Line<'static>>) {
        if text.is_empty() {
            return;
        }
        out.push(Line::from(format!("      {}", clean(text))));
    }

    // bullet: lead a row with a status glyph for a bullet CLASS. With color a
    // single-width colored circle; without color a DISTINCT ascii char so shape
    // carries state. Always two columns (glyph + space).
    fn bullet_spans(&self, class: &str) -> Vec<Span<'static>> {
        let (color, ch) = match class {
            "blocked" => (Color::Red, 'x'),
            "waiting" => (Color::Yellow, '?'),
            "running" => (Color::Cyan, '>'),
            "done" => (Color::Green, '+'),
            _ => (Color::Reset, '.'),
        };
        if self.color {
            let style = if color == Color::Reset {
                self.dim()
            } else {
                Style::default().fg(color)
            };
            vec![Span::styled("\u{25cf}".to_string(), style), Span::raw(" ")]
        } else {
            vec![Span::raw(format!("{ch} "))]
        }
    }

    // class_usage_style: the STYLE for a usage CLASS, same vocabulary as
    // bullet_spans and the bash board's class_color (so no second colour
    // language). idle reads dim - matching bash's C_DIM and bullet_spans' own
    // self.dim() - so a disabled/unmeasured window looks identical on both
    // boards; the token still reads by its ascii glyph too.
    fn class_usage_style(&self, class: &str) -> Style {
        match class {
            "blocked" => Style::default().fg(Color::Red),
            "waiting" => Style::default().fg(Color::Yellow),
            "done" => Style::default().fg(Color::Green),
            _ => self.dim(),
        }
    }

    // account_line_spans: split the pre-rendered account line on the 5h and 7d
    // token substrings and colour each from its OWN window class. The tokens are
    // literal substrings the lib baked in and already carry an ascii shape glyph,
    // so without colour the line reads verbatim and state still survives. When
    // colour is off, or a token is empty/absent, that stretch stays plain.
    fn account_line_spans(
        &self,
        line: &str,
        ft: &str,
        fc: &str,
        st: &str,
        sc: &str,
        out: &mut Vec<Span<'static>>,
    ) {
        let cleaned = clean(line);
        // Windows to colour, in first-occurrence order, each with its class style.
        let mut marks: Vec<(usize, usize, Style)> = Vec::new();
        if self.color {
            for (tok, cls) in [(ft, fc), (st, sc)] {
                if tok.is_empty() {
                    continue;
                }
                let style = self.class_usage_style(cls);
                if let Some(pos) = cleaned.find(tok) {
                    marks.push((pos, pos + tok.len(), style));
                }
            }
        }
        if marks.is_empty() {
            out.push(Span::raw(cleaned));
            return;
        }
        marks.sort_by_key(|m| m.0);
        let mut cur = 0usize;
        for (start, end, style) in marks {
            if start < cur {
                continue; // overlapping/degenerate match: skip to stay in order
            }
            if start > cur {
                out.push(Span::raw(cleaned[cur..start].to_string()));
            }
            out.push(Span::styled(cleaned[start..end].to_string(), style));
            cur = end;
        }
        if cur < cleaned.len() {
            out.push(Span::raw(cleaned[cur..].to_string()));
        }
    }

    // lead_line: a row's headline. With a head: "<glyph> <bold head>  <dim id>[
    //   <dim meta>]". Without a head: "<glyph|2sp><cyan id>[  <dim meta>]".
    fn lead_line(
        &self,
        head: &str,
        id: &str,
        meta: &str,
        bull: &str,
        out: &mut Vec<Line<'static>>,
    ) {
        let mut spans: Vec<Span<'static>> = if bull.is_empty() {
            vec![Span::raw("  ")]
        } else {
            self.bullet_spans(bull)
        };
        if !head.is_empty() {
            spans.push(Span::styled(clean(head), self.bold()));
            spans.push(Span::raw("  "));
            spans.push(Span::styled(clean(id), self.dim()));
            if !meta.is_empty() {
                spans.push(Span::raw("  "));
                spans.push(Span::styled(clean(meta), self.dim()));
            }
        } else {
            spans.push(Span::styled(
                clean(id),
                self.st(Style::default().fg(Color::Cyan)),
            ));
            if !meta.is_empty() {
                spans.push(Span::raw("  "));
                spans.push(Span::styled(clean(meta), self.dim()));
            }
        }
        out.push(Line::from(spans));
    }

    // capped_rows: the first `n` rows to paint for a section (n from the fit).
    fn capped_rows<'a>(&self, s: &'a Section, n: usize) -> &'a [serde_json::Value] {
        &s.rows[..n.min(s.rows.len())]
    }

    // dropped: a foldable "ok" section whose fit seated zero rows is dropped
    // entirely (header included) rather than paying its rule + "+N more" for no
    // content - so a short pane shows fewer sections, never a bare collapse notice
    // that overflows. Only meaningful with a pane-height fit; without one the fixed
    // cap always seats rows for a non-empty section.
    fn dropped(&self, s: &Section, n: usize) -> bool {
        self.rows.is_some() && s.status() == "ok" && n == 0 && !s.rows.is_empty()
    }

    // capped_more_line: the "+N more" pointer for a section capped to `n` rows.
    // The model is stored uncapped, so this crate computes the collapse count.
    fn capped_more_line(&self, s: &Section, n: usize, out: &mut Vec<Line<'static>>) {
        let more = s.rows.len().saturating_sub(n);
        if more > 0 {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(format!("+{more} more - open the full desk"), self.dim()),
            ]));
        }
    }

    // --- sections -----------------------------------------------------------
    // captains_call and merge are ALWAYS shown; the other four fold away when
    // empty (their count already lives in the top summary). `cap` gives the fitted
    // row count per section, in paint order.
    fn captains_call(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.captains_call;
        if hidden(s) {
            return;
        }
        self.rule_counted("Captain's Call", s, out);
        match s.status() {
            "gap" | "away" => self.gap_line(gap_text(s), out),
            "empty" => {
                if s.merge_count.unwrap_or(0) > 0 {
                    self.empty_line(
                        "No open decisions. Finished branches are waiting to merge (see below).",
                        out,
                    );
                } else {
                    self.empty_line("Nothing needs your action right now.", out);
                }
            }
            _ => {
                let n = cap[0];
                for r in self.capped_rows(s, n) {
                    self.lead_line(
                        &str_field(r, "summary"),
                        &str_field(r, "id"),
                        "",
                        &str_field(r, "bullet"),
                        out,
                    );
                }
                self.capped_more_line(s, n, out);
            }
        }
    }

    fn under_way(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.under_way;
        if folds_away(s) || hidden(s) || self.dropped(s, cap[1]) {
            return;
        }
        self.rule_counted("Under Way", s, out);
        match s.status() {
            "gap" | "away" => self.gap_line(gap_text(s), out),
            "empty" => self.empty_line("No work is under way.", out),
            _ => {
                let n = cap[1];
                for r in self.capped_rows(s, n) {
                    // The bullet carries state, so the state WORD is cut; kind
                    // trails as dim meta.
                    self.lead_line(
                        &str_field(r, "doing"),
                        &str_field(r, "id"),
                        &str_field(r, "kind"),
                        &str_field(r, "bullet"),
                        out,
                    );
                }
                self.capped_more_line(s, n, out);
            }
        }
    }

    fn charted(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.charted;
        if folds_away(s) || hidden(s) || self.dropped(s, cap[2]) {
            return;
        }
        self.rule_counted("Charted / Queued next", s, out);
        match s.status() {
            "gap" | "away" => self.gap_line(gap_text(s), out),
            "empty" => self.empty_line("Nothing is charted or queued.", out),
            _ => {
                let n = cap[2];
                for r in self.capped_rows(s, n) {
                    self.lead_line(
                        &str_field(r, "title"),
                        &str_field(r, "id"),
                        "",
                        &str_field(r, "bullet"),
                        out,
                    );
                    let blocked_by = str_field(r, "blocked_by");
                    let reason = str_field(r, "reason");
                    let mut why = String::new();
                    if !blocked_by.is_empty() && blocked_by != "-" {
                        why = format!("waits on {blocked_by}");
                    }
                    if !reason.is_empty() && reason != "-" {
                        why = if why.is_empty() {
                            reason
                        } else {
                            format!("{why} - {reason}")
                        };
                    }
                    self.body_line(&why, out);
                }
                self.capped_more_line(s, n, out);
            }
        }
    }

    fn landed(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.landed;
        if folds_away(s) || hidden(s) || self.dropped(s, cap[3]) {
            return;
        }
        self.rule_counted("Recently Landed", s, out);
        match s.status() {
            "gap" | "away" => self.gap_line(gap_text(s), out),
            "empty" => self.empty_line("Nothing landed recently.", out),
            _ => {
                let n = cap[3];
                for r in self.capped_rows(s, n) {
                    self.lead_line(
                        &str_field(r, "what"),
                        &str_field(r, "id"),
                        "",
                        &str_field(r, "bullet"),
                        out,
                    );
                    let artifact = str_field(r, "artifact");
                    if !artifact.is_empty() && artifact != "-" {
                        self.body_line(&artifact, out);
                    }
                }
                self.capped_more_line(s, n, out);
            }
        }
    }

    // merge: finished-but-unmerged branches. The id already carries the branch, so
    // only the id shows; the compare URL is CUT (unusable terminal text). dest
    // varies (dev vs main) so it stays as trailing meta.
    fn merge(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.merge;
        if hidden(s) {
            return;
        }
        self.rule_counted("Ready to merge (finished, not yet landed)", s, out);
        if s.rows.is_empty() {
            self.empty_line("No finished branches waiting to merge.", out);
            return;
        }
        let n = cap[4];
        for r in self.capped_rows(s, n) {
            let dest = str_field(r, "dest");
            self.lead_line("", &str_field(r, "id"), &format!("-> {dest}"), "done", out);
        }
        self.capped_more_line(s, n, out);
    }

    fn secondmates(&self, m: &Model, cap: [usize; 6], out: &mut Vec<Line<'static>>) {
        let s = &m.sections.secondmates;
        if folds_away(s) || hidden(s) || self.dropped(s, cap[5]) {
            return;
        }
        self.rule_counted("Second mates", s, out);
        match s.status() {
            "gap" | "away" => self.gap_line(gap_text(s), out),
            "empty" => self.empty_line("No second mates registered.", out),
            _ => {
                let n = cap[5];
                for r in self.capped_rows(s, n) {
                    self.lead_line(
                        &str_field(r, "doing"),
                        &str_field(r, "id"),
                        &str_field(r, "freshness"),
                        &str_field(r, "bullet"),
                        out,
                    );
                }
                self.capped_more_line(s, n, out);
            }
        }
    }

    // health_line: the single dim line shown ONLY when monitoring may have lapsed
    // or the captain is away; a healthy present fleet has none. One owner, read by
    // both the fit (to reserve a line) and the paint.
    fn health_line(&self, m: &Model) -> Option<String> {
        let mut line = String::new();
        match m.health.beat_age_seconds {
            None => {
                line = "Monitoring status is unknown; no recent check was recorded.".to_string()
            }
            Some(age) if age > 1800 => {
                line = format!("Monitoring may have lapsed (last check about {age}s ago).")
            }
            _ => {}
        }
        if m.away {
            if line.is_empty() {
                line = "You are marked away.".to_string();
            } else {
                line.push_str(" You are marked away.");
            }
        }
        if line.is_empty() {
            None
        } else {
            Some(line)
        }
    }

    fn health(&self, m: &Model, out: &mut Vec<Line<'static>>) {
        if let Some(line) = self.health_line(m) {
            self.gap_line(&line, out);
        }
    }

    // clip_line: the ONE width owner. No line exceeds `cols` visible columns, so
    // nothing wraps. Width is counted in characters (one column each), matching
    // the bash board. A fitting line passes verbatim; an over-wide line keeps its
    // leading columns and drops the tail, marking the cut with a single-column
    // ellipsis (reserving one column, exactly like clip_frame).
    pub fn clip_line(&self, line: Line<'static>) -> Line<'static> {
        let cols = self.cols as usize;
        let total: usize = line.spans.iter().map(|s| s.content.chars().count()).sum();
        if total <= cols {
            return line;
        }
        let limit = cols.saturating_sub(1); // reserve one column for the ellipsis
        let mut used = 0usize;
        let mut kept: Vec<Span<'static>> = Vec::new();
        for span in line.spans.into_iter() {
            let w = span.content.chars().count();
            if used + w <= limit {
                used += w;
                kept.push(span);
                continue;
            }
            // This span overflows: keep as many of its chars as fit.
            let remaining = limit - used;
            if remaining > 0 {
                let truncated: String = span.content.chars().take(remaining).collect();
                kept.push(Span::styled(truncated, span.style));
            }
            break;
        }
        kept.push(Span::raw("\u{2026}"));
        Line::from(kept)
    }
}

// gap_text: the section-level gap sentence the lib produced (empty when none).
fn gap_text(s: &Section) -> &str {
    // Section struct does not model it (it is only shown on the gap/away path),
    // so fall back to a generic notice. Kept minimal: a real gap is rare and the
    // model still names it in the top-level gaps banner.
    let _ = s;
    "This section could not be read right now."
}

// --- WP-4 shared helpers: section titles, per-section row fields, empties ----
// section_title: the header text per section, matching the WP-3 rule() titles so
// the nav board and the static board read identically.
fn section_title(kind: SectionKind) -> &'static str {
    match kind {
        SectionKind::CaptainsCall => "Captain's Call",
        SectionKind::UnderWay => "Under Way",
        SectionKind::Charted => "Charted / Queued next",
        SectionKind::Landed => "Recently Landed",
        SectionKind::Merge => "Ready to merge (finished, not yet landed)",
        SectionKind::Secondmates => "Second mates",
    }
}

// empty_sentence: the same empty-state text the WP-3 board uses per section.
fn empty_sentence(kind: SectionKind, s: &Section) -> String {
    match kind {
        SectionKind::CaptainsCall => {
            if s.merge_count.unwrap_or(0) > 0 {
                "No open decisions. Finished branches are waiting to merge (see below).".to_string()
            } else {
                "Nothing needs your action right now.".to_string()
            }
        }
        SectionKind::UnderWay => "No work is under way.".to_string(),
        SectionKind::Charted => "Nothing is charted or queued.".to_string(),
        SectionKind::Landed => "Nothing landed recently.".to_string(),
        SectionKind::Merge => "No finished branches waiting to merge.".to_string(),
        SectionKind::Secondmates => "No second mates registered.".to_string(),
    }
}

// row_fields: extract (head, id, meta, bullet, body) for a row per section,
// mirroring the WP-3 lead_line/body_line field choices so the nav board shows the
// same terse summary the static board does - internal vocabulary never leaks into
// these summary lines; the raw detail lives in the drill-down only.
fn row_fields(
    kind: SectionKind,
    r: &serde_json::Value,
) -> (String, String, String, String, String) {
    let id = str_field(r, "id");
    let bullet = str_field(r, "bullet");
    match kind {
        SectionKind::CaptainsCall => (
            str_field(r, "summary"),
            id,
            String::new(),
            bullet,
            String::new(),
        ),
        SectionKind::UnderWay => (
            str_field(r, "doing"),
            id,
            str_field(r, "kind"),
            bullet,
            String::new(),
        ),
        SectionKind::Charted => {
            let blocked_by = str_field(r, "blocked_by");
            let reason = str_field(r, "reason");
            let mut why = String::new();
            if !blocked_by.is_empty() && blocked_by != "-" {
                why = format!("waits on {blocked_by}");
            }
            if !reason.is_empty() && reason != "-" {
                why = if why.is_empty() {
                    reason
                } else {
                    format!("{why} - {reason}")
                };
            }
            (str_field(r, "title"), id, String::new(), bullet, why)
        }
        SectionKind::Landed => {
            let artifact = str_field(r, "artifact");
            let body = if !artifact.is_empty() && artifact != "-" {
                artifact
            } else {
                String::new()
            };
            (str_field(r, "what"), id, String::new(), bullet, body)
        }
        SectionKind::Merge => {
            let dest = str_field(r, "dest");
            (
                String::new(),
                id,
                format!("-> {dest}"),
                "done".to_string(),
                String::new(),
            )
        }
        SectionKind::Secondmates => (
            str_field(r, "doing"),
            id,
            str_field(r, "freshness"),
            bullet,
            String::new(),
        ),
    }
}

// HELP_KEYS: the single owner of the key bindings shown in the ? overlay. main.rs
// dispatches these exact keys; keep the two in sync.
const HELP_KEYS: &[(&str, &str)] = &[
    ("up / k", "move up"),
    ("down / j", "move down"),
    ("Tab / ]", "next section"),
    ("Shift-Tab / [", "previous section"),
    ("g / G", "first / last item"),
    ("Enter / l", "open the item's underlying file"),
    ("space / h", "expand or collapse the section"),
    ("c u a d m s", "jump straight to a section"),
    ("w", "switch the global Claude account (jcode plane)"),
    ("$", "spend and efficiency breakdown"),
    ("?", "toggle this help"),
    ("q / Ctrl-C", "quit (always works)"),
];

// hidden: honor a desk_fit render:false marker when present; absent = show.
fn hidden(s: &Section) -> bool {
    let _ = s;
    false
}

// clean: strip control characters for terminal safety (the lib already
// translated the text; ids/urls are carried verbatim upstream).
fn clean(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).collect()
}

// wrap_line: break one styled Line into as many rows as needed so no row exceeds
// `width` visible columns, preserving span styles across the break. A
// continuation row is prefixed with `indent` spaces so it reads as a wrap, not a
// new item. Prefers to break on a space near the width (word wrap); falls back to
// a hard character break for an unbroken run (a long URL/path) so a single token
// still never overflows. This is the wrap counterpart to clip_line: clip_line
// still runs last as the width backstop, so a bug here degrades to a clip, never
// an overflow.
//
// Width is counted in Unicode scalars (one column each), matching clip_line and
// the bash board. The indent is bounded below the width so a tiny pane still
// makes forward progress rather than emitting empty continuation rows forever.
fn wrap_line(line: &Line<'static>, width: usize, indent: usize) -> Vec<Line<'static>> {
    let width = width.max(1);
    let total: usize = line.spans.iter().map(|s| s.content.chars().count()).sum();
    if total <= width {
        return vec![line.clone()];
    }
    // The continuation indent must leave room to advance; cap it well under width.
    let cont_indent = indent.min(width.saturating_sub(1));

    // Flatten to (char, style) so a break can land mid-span; the emitter rebuilds
    // contiguous same-style runs into spans, so styling survives the wrap.
    let chars: Vec<(char, Style)> = line
        .spans
        .iter()
        .flat_map(|s| s.content.chars().map(move |c| (c, s.style)))
        .collect();

    let mut rows: Vec<Line<'static>> = Vec::new();
    let mut pos = 0usize;
    let n = chars.len();
    while pos < n {
        let first = rows.is_empty();
        let lead = if first { 0 } else { cont_indent };
        let budget = width.saturating_sub(lead).max(1);
        let remaining = n - pos;
        let take = if remaining <= budget {
            remaining
        } else {
            // Look for the last space within [pos, pos+budget] to break on a word
            // boundary; skip the leading position so we never make zero progress.
            let mut brk = None;
            for i in (pos + 1..=pos + budget).rev() {
                if chars[i - 1].0 == ' ' {
                    brk = Some(i - pos);
                    break;
                }
            }
            brk.unwrap_or(budget) // no space: hard break so a long token still fits
        };
        let end = pos + take;
        let mut spans: Vec<Span<'static>> = Vec::new();
        if lead > 0 {
            spans.push(Span::raw(" ".repeat(lead)));
        }
        // Coalesce contiguous same-style chars into spans.
        let mut run = String::new();
        let mut run_style = chars[pos].1;
        for &(c, st) in &chars[pos..end] {
            if st == run_style {
                run.push(c);
            } else {
                spans.push(Span::styled(std::mem::take(&mut run), run_style));
                run.push(c);
                run_style = st;
            }
        }
        if !run.is_empty() {
            spans.push(Span::styled(run, run_style));
        }
        rows.push(Line::from(spans));
        pos = end;
        // Trim a single leading space on the next continuation so a word-wrapped
        // break does not start the next row with the break space.
        if pos < n && chars[pos].0 == ' ' {
            pos += 1;
        }
    }
    if rows.is_empty() {
        rows.push(Line::from(String::new()));
    }
    rows
}

// A tiny helper so main can reuse the same conversion in the non-tty text path.
pub fn line_plain_text(line: &Line) -> String {
    line.spans.iter().map(|s| s.content.as_ref()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::parse;

    fn line_width(l: &Line) -> usize {
        l.spans.iter().map(|s| s.content.chars().count()).sum()
    }

    // flatten: join a frame into text, concatenating spans WITHIN each line and
    // joining lines with newlines - so a within-line sequence like "> doing" is
    // preserved rather than split by a span boundary.
    fn flatten(lines: &[Line]) -> String {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    // A model exercising every section and every status branch.
    fn full_model_json() -> &'static str {
        r#"{
          "schema": "fm-desk.v1",
          "now": "2026-08-23 09:00:00 UTC",
          "away": false,
          "health": { "beat_age_seconds": 30 },
          "header": { "summary": "2 things need your word. One job is running.",
                      "usage": { "line": "session 1% (resets 4h) · week 69% (resets 1d)",
                                 "session": {"percent_used":1,"resets_in":"4h"},
                                 "week": {"percent_used":69,"resets_in":"1d"} } },
          "gaps": [],
          "sections": {
            "captains_call": { "status": "ok", "total": 2, "full_total": 20, "shown": 2, "more": 0, "more_hint": "", "merge_count": 3,
              "rows": [
                {"id":"decide-a","summary":"a very long decision summary that will certainly exceed a narrow pane width by a wide margin indeed","bullet":"waiting"},
                {"id":"decide-b","summary":"short one","bullet":"waiting"}
              ] },
            "under_way": { "status": "ok", "total": 1, "full_total": 1, "shown": 1, "more": 0, "more_hint": "",
              "rows": [ {"id":"task-x","kind":"ship","doing":"implementing the thing","bullet":"running"} ] },
            "charted": { "status": "ok", "total": 3, "full_total": 3, "shown": 2, "more": 1, "more_hint": "+1 more - open the full desk",
              "rows": [
                {"id":"g1","title":"gate one","blocked_by":"task-x","reason":"needs the API","bullet":"idle"},
                {"id":"g2","title":"gate two","blocked_by":"-","reason":"-","bullet":"idle"}
              ] },
            "landed": { "status": "ok", "total": 1, "full_total": 1, "shown": 1, "more": 0, "more_hint": "",
              "rows": [ {"id":"done-1","what":"shipped a fix","artifact":"data/done-1/report.md","bullet":"done"} ] },
            "merge": { "total": 2, "full_total": 2, "shown": 2, "more": 0, "more_hint": "",
              "rows": [
                {"id":"fm/branch-one","branch":"fm/branch-one","dest":"main","url":"https://example.com/very/long/compare/url/that/should/never/be/painted","bullet":"done"},
                {"id":"fm/branch-two","branch":"fm/branch-two","dest":"dev","url":"https://example.com/another","bullet":"done"}
              ] },
            "secondmates": { "status": "ok", "total": 1, "full_total": 2, "shown": 1, "more": 0, "more_hint": "",
              "rows": [ {"id":"builder","state":"active_child_work","doing":"working","freshness":"310k ctx · idle 41m","bullet":"running","context_tokens":309721,"idle_seconds":2506,"child_running":1} ] }
          }
        }"#
    }

    #[test]
    fn width_guarantee_holds_at_every_column_color_on_and_off() {
        let m = parse(full_model_json()).unwrap();
        for &cols in &[40u16, 62, 80, 120] {
            for &color in &[true, false] {
                let p = Painter::new(cols, color);
                for line in p.frame(&m, None) {
                    assert!(
                        line_width(&line) <= cols as usize,
                        "line exceeds {cols} cols (color={color}): width={} text={:?}",
                        line_width(&line),
                        line.spans
                            .iter()
                            .map(|s| s.content.as_ref())
                            .collect::<String>()
                    );
                }
            }
        }
    }

    // Live-fleet width guarantee: point FM_DESK_MODEL at the real cached model and
    // assert the same guarantee against real data, color ON and OFF, at every
    // width. Gated on the env var so ordinary CI (no live fleet) skips it; the
    // brief requires verifying against the live fleet, not a fixture.
    #[test]
    fn width_guarantee_holds_on_the_live_fleet() {
        let path = match std::env::var("FM_DESK_MODEL") {
            Ok(p) if !p.is_empty() => p,
            _ => return, // no live model wired: skip
        };
        let text = std::fs::read_to_string(&path).expect("read live model");
        let m = parse(&text).expect("parse live model");
        for &cols in &[40u16, 62, 80, 120] {
            for &color in &[true, false] {
                let p = Painter::new(cols, color);
                let mut widest = 0usize;
                for line in p.frame(&m, None) {
                    let w = line_width(&line);
                    widest = widest.max(w);
                    assert!(
                        w <= cols as usize,
                        "LIVE line exceeds {cols} cols (color={color}): width={w} text={:?}",
                        line.spans
                            .iter()
                            .map(|s| s.content.as_ref())
                            .collect::<String>()
                    );
                }
                eprintln!("live width check: cols={cols} color={color} widest={widest}");
            }
        }
    }

    #[test]
    fn secondmates_paint_context_and_idle_never_a_diagnostic() {
        // WP-6: each secondmate entry shows a terse status headline plus the
        // context-usage + time-idle meta the captain asked for. The model owns
        // those clean fields; the render paints doing (status) + freshness (the
        // ctx/idle line) and must never surface an internal diagnostic string.
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(
            text.contains("Second mates"),
            "secondmates section should render:\n{text}"
        );
        assert!(
            text.contains("310k ctx"),
            "context usage should paint:\n{text}"
        );
        assert!(text.contains("idle 41m"), "time idle should paint:\n{text}");
        assert!(
            text.contains("> working"),
            "a working mate leads with the running bullet:\n{text}"
        );
        // No internal diagnostic vocabulary may reach the board.
        for leak in [
            "structured home",
            "snapshot",
            "in-flight backlog",
            "invalid",
        ] {
            assert!(
                !text.contains(leak),
                "internal string '{leak}' leaked into the board:\n{text}"
            );
        }
    }

    #[test]
    fn merge_section_never_paints_a_url() {
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(200, false); // wide enough that clipping cannot hide a url
        let text = flatten(&p.frame(&m, None));
        assert!(
            !text.contains("http"),
            "a forge URL leaked into the board:\n{text}"
        );
        assert!(text.contains("fm/branch-one"), "merge id missing");
        assert!(text.contains("-> main"), "merge dest missing");
    }

    #[test]
    fn section_headers_carry_the_full_total_count_like_the_shell_board() {
        // ITEM 3: the compiled board was missing the section counts the header-
        // counts work (commit 1c5946e) gave the shell board. Both the static frame
        // and the nav frame must fold the section's TRUE count (full_total) into
        // the title as " (N)", so the two boards agree with each other and with
        // bin/fm-desk-tui.sh. A wide pane avoids any clip hiding the count.
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(200, false);
        let static_text = flatten(&p.frame(&m, None));
        // captains_call full_total=20 (ranked rows capped to 2), so the header must
        // show the honest 20, never the 2 seated rows.
        assert!(
            static_text.contains("Captain's Call (20)"),
            "static board must show the captains_call full_total (20):\n{static_text}"
        );
        assert!(
            static_text.contains("Charted / Queued next (3)"),
            "static board must count the charted section:\n{static_text}"
        );
        assert!(
            static_text.contains("Ready to merge (finished, not yet landed) (2)"),
            "static board must count the merge section:\n{static_text}"
        );
        assert!(
            static_text.contains("Second mates (2)"),
            "static board must count the secondmates section:\n{static_text}"
        );
        // The nav (interactive) board folds the same count into its title.
        let nav = Nav::new(&m);
        let nav_text: String = p
            .nav_frame(&m, &nav, None)
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            nav_text.contains("Captain's Call (20)"),
            "nav board must show the captains_call full_total (20):\n{nav_text}"
        );
        assert!(
            nav_text.contains("Second mates (2)"),
            "nav board must count the secondmates section:\n{nav_text}"
        );
    }

    #[test]
    fn a_zero_or_non_ok_section_gets_no_count_in_the_header() {
        // Only a populated (ok) section is counted; an empty/gap/away section keeps
        // its bare title and never a silly "(0)".
        let json = r#"{"now":"t","header":{"summary":""},
          "sections":{
            "captains_call":{"status":"empty","full_total":0,"merge_count":0,"rows":[]},
            "under_way":{"status":"gap","full_total":0,"rows":[]}
          }}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(
            text.contains("Captain's Call\n") || text.contains("Captain's Call "),
            "an empty section keeps its bare title:\n{text}"
        );
        assert!(
            !text.contains("Captain's Call (0)"),
            "an empty section must not paint a (0) count:\n{text}"
        );
    }

    #[test]
    fn header_paints_the_claude_usage_line_when_present() {
        // ITEM 4: the captain's Claude usage rides in the model header and both
        // boards paint it, once, as a compact line. The crate never shells out for
        // it (the file-driven design point).
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(120, false);
        let static_text = flatten(&p.frame(&m, None));
        assert!(
            static_text.contains("session 1% (resets 4h) · week 69% (resets 1d)"),
            "static header must paint the usage line:\n{static_text}"
        );
        // The nav board reuses the same header, so it shows the same one line.
        let nav = Nav::new(&m);
        let nav_text: String = p
            .nav_frame(&m, &nav, None)
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            nav_text.contains("session 1%"),
            "nav header must paint the usage line:\n{nav_text}"
        );
    }

    #[test]
    fn header_omits_the_usage_line_when_absent() {
        // No usage in the model (quota-axi unread or no window) -> no usage row and
        // never a blank line pretending to be one.
        let json = r#"{"now":"t","header":{"summary":"hi"},"sections":{}}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(text.contains("hi"), "summary still paints");
        assert!(
            !text.contains("session ") && !text.contains("resets"),
            "no usage line when the model carries none:\n{text}"
        );
    }

    #[test]
    fn header_paints_the_claude_accounts_block_when_present() {
        // The captain asked to see ALL accounts on the board plus which store
        // uses which. The lib pre-renders one compact line per account; both
        // boards paint the caption then those lines, verbatim (no translation of
        // emails or store names), and the caption states the honesty caveat.
        let json = r#"{"now":"t","header":{"summary":"hi",
          "accounts":{"caption":"Claude accounts (configured stores, a running session may differ)",
            "lines":["1 a@x  5h 100% · 7d 78% (21h)",
                     "2 b@y  5h 0% · 7d 100% (1d)  (disabled)",
                     "3 c@z  5h 20% · 7d 4% (6d)  <- Claude Code + jcode"],
            "accounts":[{"email":"a@x"},{"email":"b@y"},{"email":"c@z"}]}},
          "sections":{}}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        let static_text = flatten(&p.frame(&m, None));
        assert!(
            static_text.contains("configured stores, a running session may differ"),
            "the honesty caption must paint:\n{static_text}"
        );
        for want in [
            "1 a@x",
            "2 b@y  5h 0% · 7d 100% (1d)  (disabled)",
            "3 c@z  5h 20% · 7d 4% (6d)  <- Claude Code + jcode",
        ] {
            assert!(
                static_text.contains(want),
                "account line missing: {want}\n{static_text}"
            );
        }
        // The nav board reuses the same header, so it paints the same block.
        let nav = Nav::new(&m);
        let nav_text: String = p
            .nav_frame(&m, &nav, None)
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            nav_text.contains("3 c@z") && nav_text.contains("Claude Code + jcode"),
            "nav header must paint the accounts block:\n{nav_text}"
        );
    }

    #[test]
    fn header_omits_the_accounts_block_when_absent() {
        // No accounts (cswap unread or none) -> no caption and no account lines,
        // never a blank block pretending to be one.
        let json = r#"{"now":"t","header":{"summary":"hi"},"sections":{}}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(
            !text.contains("configured stores") && !text.contains("Claude Code"),
            "no accounts block when the model carries none:\n{text}"
        );
    }

    #[test]
    fn account_lines_carry_a_usage_bullet_from_line_classes() {
        // The captain asked to see usage at a glance. Each account line leads with
        // the lib's usage-severity bullet (parallel line_classes), so headroom vs
        // spent is a shape/color the captain reads without parsing percentages.
        // Without color the bullet is a DISTINCT ascii char (never color alone),
        // and with color it is the shared status circle.
        let json = r#"{"now":"t","header":{"summary":"hi",
          "accounts":{"caption":"Claude accounts (configured stores, a running session may differ)",
            "lines":["1 a@x  5h 95%","2 b@y  5h 75%","3 c@z  5h 10%"],
            "line_classes":["blocked","waiting","done"],
            "accounts":[{"email":"a@x"},{"email":"b@y"},{"email":"c@z"}]}},
          "sections":{}}"#;
        let m = parse(json).unwrap();
        // No color: each account line gets its distinct ascii shape.
        let plain = Painter::new(120, false);
        let text = flatten(&plain.frame(&m, None));
        assert!(text.contains("x 1 a@x"), "spent account needs 'x':\n{text}");
        assert!(text.contains("? 2 b@y"), "tight account needs '?':\n{text}");
        assert!(
            text.contains("+ 3 c@z"),
            "headroom account needs '+':\n{text}"
        );
        // With color: the account lines lead with the shared status circle.
        let colored = Painter::new(120, true);
        let circles = colored
            .frame(&m, None)
            .iter()
            .filter(|l| {
                let joined: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                joined.contains('\u{25cf}') && joined.contains("@")
            })
            .count();
        assert_eq!(circles, 3, "each of the three account lines needs a bullet");
    }

    #[test]
    fn account_lines_color_each_usage_window_independently() {
        // The captain wants the 5h and 7d windows each coloured on its own, so a
        // spent 5h and a fresh 7d differ at a glance. The model carries the exact
        // token substrings + per-window classes; the board colours each token
        // from its OWN class. Each token also carries an ascii shape glyph, so a
        // NO_COLOR reader still reads each window's state.
        let json = r#"{"now":"t","header":{"summary":"hi",
          "accounts":{"caption":"Claude accounts (configured stores, a running session may differ)",
            "lines":["1 claude-panda a@x  5h 95%x · 7d 10%+ (2d)"],
            "line_classes":["blocked"],
            "five_hour_tokens":["5h 95%x"],"five_hour_classes":["blocked"],
            "seven_day_tokens":["7d 10%+"],"seven_day_classes":["done"],
            "accounts":[{"email":"a@x","jcode_label":"claude-panda"}]}},
          "sections":{}}"#;
        let m = parse(json).unwrap();
        // NO_COLOR: the animal label and both ascii-carried tokens read verbatim.
        let plain = Painter::new(120, false);
        let text = flatten(&plain.frame(&m, None));
        assert!(text.contains("claude-panda"), "animal label must show:\n{text}");
        assert!(text.contains("5h 95%x"), "5h token keeps its spent 'x' glyph:\n{text}");
        assert!(text.contains("7d 10%+"), "7d token keeps its headroom '+' glyph:\n{text}");
        // With colour: the 5h token is red (blocked) and the 7d token is green
        // (done), each as its OWN styled span, proving the windows colour apart.
        let colored = Painter::new(120, true);
        let line = colored
            .frame(&m, None)
            .into_iter()
            .find(|l| {
                let joined: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                joined.contains("a@x")
            })
            .expect("the account line must be painted");
        let five_red = line.spans.iter().any(|s| {
            s.content.as_ref() == "5h 95%x" && s.style.fg == Some(Color::Red)
        });
        let seven_green = line.spans.iter().any(|s| {
            s.content.as_ref() == "7d 10%+" && s.style.fg == Some(Color::Green)
        });
        assert!(five_red, "the spent 5h token must be red:\n{line:?}");
        assert!(seven_green, "the fresh 7d token must be green:\n{line:?}");
    }

    #[test]
    fn an_account_line_at_the_budget_survives_whole_on_every_surface() {
        // The lib composes every account line to ACCOUNT_LINE_COLS precisely so
        // that EVERY surface painting one - each prepending its own chrome and
        // then clipping at the pane width - can show it whole. A marker cut to
        // "<- cc…" names no store and a cut email names no account, so this drives
        // a line of exactly that width through ALL of them at the 80-column pane
        // the captain reads over SSH: the static board, the interactive nav board
        // (which adds a gutter on top of the bullet), and the switch overlay the
        // 'w' key opens (which reuses these same pre-rendered lines behind its own
        // number-key column, and is the tightest of the three).
        //
        // The fixture is built FROM the constant rather than hard-coding a width,
        // so lowering the budget cannot leave this test silently passing on a
        // narrower line than the lib actually emits.
        let prefix = "1 claude-panda ";
        let suffix = "  5h 100%x (59m) · 7d 100%x (23h)  <- cc+jcode";
        let email_cols = ACCOUNT_LINE_COLS - prefix.chars().count() - suffix.chars().count();
        let email = format!("{}@x.test", "a".repeat(email_cols - "@x.test".chars().count()));
        let line = format!("{prefix}{email}{suffix}");
        assert_eq!(
            line.chars().count(),
            ACCOUNT_LINE_COLS,
            "the fixture line must be exactly the budget:\n{line}"
        );
        let json = format!(
            r#"{{"now":"t","header":{{"summary":"hi",
              "accounts":{{"caption":"Claude accounts (configured stores, a running session may differ)",
                "lines":["{line}"],"line_classes":["blocked"],
                "five_hour_tokens":["5h 100%x"],"five_hour_classes":["blocked"],
                "seven_day_tokens":["7d 100%x"],"seven_day_classes":["blocked"],
                "accounts":[{{"email":"{email}","jcode_label":"claude-panda"}}]}}}},
              "sections":{{}}}}"#
        );
        let m = parse(&json).unwrap();
        let nav = Nav::new(&m);
        // The pane the captain actually gets over SSH, colour on and off (ratatui
        // keeps style separate from text, but the bullet differs by one glyph).
        for &color in &[true, false] {
            let p = Painter::new(80, color);
            let surfaces: Vec<(&str, Vec<Line>)> = vec![
                ("static frame", p.frame(&m, None)),
                ("nav board", p.nav_frame(&m, &nav, None)),
                (
                    "switch overlay",
                    p.switch_frame(&[("1".to_string(), line.clone())], None, None, None),
                ),
            ];
            for (surface, painted) in surfaces {
                let row = painted
                    .iter()
                    .find(|l| {
                        let joined: String =
                            l.spans.iter().map(|s| s.content.as_ref()).collect();
                        joined.contains(&email)
                    })
                    .unwrap_or_else(|| panic!("{surface} must paint the account row"));
                let text: String = row.spans.iter().map(|s| s.content.as_ref()).collect();
                assert!(
                    !text.contains('\u{2026}'),
                    "{surface} (color={color}) clipped the account row: {text}"
                );
                assert!(
                    text.contains(&line),
                    "{surface} (color={color}) must carry the composed line whole: {text}"
                );
                assert!(
                    line_width(row) <= 80,
                    "{surface} (color={color}) row is {} cols, over the 80-col pane: {text}",
                    line_width(row)
                );
            }
        }
    }

    #[test]
    fn disabled_account_idle_tokens_render_dim() {
        // A disabled account reads idle for both windows. The bash board dims its
        // baked tokens via class_color -> C_DIM, so the Rust board must dim them
        // too (Modifier::DIM), or the same account would look different across the
        // two boards. Without colour the tokens still read by their '.' glyph.
        let json = r#"{"now":"t","header":{"summary":"hi",
          "accounts":{"caption":"Claude accounts (configured stores, a running session may differ)",
            "lines":["1 claude-otter a@x  5h 0%. · 7d 100%. (2d)  (disabled)"],
            "line_classes":["idle"],
            "five_hour_tokens":["5h 0%."],"five_hour_classes":["idle"],
            "seven_day_tokens":["7d 100%."],"seven_day_classes":["idle"],
            "accounts":[{"email":"a@x","jcode_label":"claude-otter","disabled":true}]}},
          "sections":{}}"#;
        let m = parse(json).unwrap();
        let colored = Painter::new(120, true);
        let line = colored
            .frame(&m, None)
            .into_iter()
            .find(|l| {
                let joined: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                joined.contains("a@x")
            })
            .expect("the account line must be painted");
        let five_dim = line.spans.iter().any(|s| {
            s.content.as_ref() == "5h 0%." && s.style.add_modifier.contains(Modifier::DIM)
        });
        let seven_dim = line.spans.iter().any(|s| {
            s.content.as_ref() == "7d 100%." && s.style.add_modifier.contains(Modifier::DIM)
        });
        assert!(five_dim, "the idle 5h token must be dim:\n{line:?}");
        assert!(seven_dim, "the idle 7d token must be dim:\n{line:?}");
    }

    #[test]
    fn switch_hint_is_interactive_only() {
        // The 'w' key only works on the interactive nav board, so the hint that
        // names it appears there and NEVER on the static/piped board where no key
        // can be pressed (the hint must not lie).
        let json = r#"{"now":"t","header":{"summary":"hi",
          "accounts":{"caption":"Claude accounts (configured stores, a running session may differ)",
            "lines":["1 a@x  5h 10%"],"line_classes":["done"],
            "accounts":[{"email":"a@x"}]}},
          "sections":{}}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        // Static board: no hint (no key can be pressed there).
        let static_text = flatten(&p.frame(&m, None));
        assert!(
            !static_text.contains("press w to switch"),
            "static board must not claim the w key:\n{static_text}"
        );
        // Interactive nav board: the hint appears under the accounts block.
        let nav = Nav::new(&m);
        let nav_text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            nav_text.contains("press w to switch the global Claude account"),
            "nav board must name the switch key:\n{nav_text}"
        );
    }

    #[test]
    fn accounts_block_never_overflows_the_pane_height() {
        // The accounts block is fixed chrome the vertical-fit fill loop must
        // reserve. A model carrying it must still fit its pane at the block's own
        // chrome floor and above, exactly like the usage line.
        let with_accounts = many_rows_json().replace(
            r#""header":{"summary":"lots"}"#,
            r#""header":{"summary":"lots","accounts":{"caption":"Claude accounts (configured stores, a running session may differ)","lines":["1 a@x  5h 1%","2 b@y  5h 2%","3 c@z  5h 3%"],"accounts":[{"email":"a@x"},{"email":"b@y"},{"email":"c@z"}]}}"#,
        );
        assert!(with_accounts.contains("accounts"), "accounts not injected");
        let m = parse(&with_accounts).unwrap();
        // Floor: base mandatory chrome (10) + caption + 3 account lines = 14.
        for &h in &[14u16, 16, 24, 49] {
            let p = Painter::with_rows(80, false, h);
            let lines = p.frame(&m, None);
            assert!(
                lines.len() <= h as usize,
                "board painted {} lines into a {h}-row pane",
                lines.len()
            );
        }
    }

    #[test]
    fn switch_frame_pick_lists_accounts_then_confirm_states_scope() {
        // The switch overlay's pick and confirm phases: the pick list shows a
        // number key per account and the honest GLOBAL-scope caveat; confirm
        // names the exact target, the jcode plane it acts on, and the y/n
        // prompt. Neither phase asserts a live-session claim.
        let p = Painter::new(80, false);
        let entries = vec![
            ("1".to_string(), "1 a@x  5h 100%".to_string()),
            ("2".to_string(), "2 b@y  5h 0%".to_string()),
        ];
        let pick = flatten(&p.switch_frame(&entries, None, None, None));
        assert!(
            pick.contains("Switch the global Claude account"),
            "title:\n{pick}"
        );
        assert!(
            pick.contains("jcode plane"),
            "the pick phase must name the plane it acts on:\n{pick}"
        );
        assert!(
            pick.contains("A running session keeps its account until it restarts"),
            "pick phase must state the honesty/scope caveat:\n{pick}"
        );
        assert!(
            pick.contains("1  1 a@x") || pick.contains("1"),
            "number key:\n{pick}"
        );
        assert!(
            pick.contains("a@x") && pick.contains("b@y"),
            "accounts listed:\n{pick}"
        );

        let confirm = flatten(&p.switch_frame(&entries, Some("a@x"), None, None));
        assert!(
            confirm.contains("Switch the jcode plane (~/.jcode/auth.json) to a@x?"),
            "confirm names the exact target:\n{confirm}"
        );
        assert!(
            !confirm.contains("both stores"),
            "confirm must NOT claim it switches both stores:\n{confirm}"
        );
        assert!(
            confirm.contains("y confirm") && confirm.contains("cancel"),
            "y/n prompt:\n{confirm}"
        );

        let err = flatten(&p.switch_frame(&entries, None, None, Some("switch failed: boom")));
        assert!(
            err.contains("switch failed: boom"),
            "status message shows:\n{err}"
        );
    }

    #[test]
    fn switch_frame_applied_phase_demands_a_restart() {
        // The CRITICAL UX requirement: a jcode-plane switch edits
        // ~/.jcode/auth.json and cannot reach an already-live session, so the
        // applied phase must tell the captain to restart and must not imply the
        // switch took effect on running sessions.
        let p = Painter::new(100, false);
        let entries = vec![("1".to_string(), "1 a@x  5h 100%".to_string())];
        let applied = flatten(&p.switch_frame(&entries, None, Some("a@x"), None));
        assert!(
            applied.contains("Switched the jcode plane to a@x."),
            "applied phase names what actually changed:\n{applied}"
        );
        assert!(
            applied.contains("Restart to apply"),
            "applied phase must surface the restart-to-apply affordance:\n{applied}"
        );
        assert!(
            applied.contains("running jcode sessions keep the old account until restarted"),
            "applied phase must state the live-session consequence:\n{applied}"
        );
        assert!(
            !applied.contains("press a number to pick"),
            "applied phase is not the pick list:\n{applied}"
        );
        // `applied` wins over a stale `confirm`, so a completed switch never
        // paints the y/n prompt again.
        let both = flatten(&p.switch_frame(&entries, Some("a@x"), Some("a@x"), None));
        assert!(
            both.contains("Restart to apply") && !both.contains("y confirm"),
            "applied must take precedence over confirm:\n{both}"
        );
    }

    #[test]
    fn switch_frame_empty_shows_no_accounts_note() {
        // With no accounts the overlay still opens (main.rs `w` always opens it),
        // so the pick phase shows an honest empty-state note instead of a "press a
        // number to pick" prompt with nothing to pick.
        let p = Painter::new(80, false);
        let empty: Vec<(String, String)> = Vec::new();
        let out = flatten(&p.switch_frame(&empty, None, None, None));
        assert!(
            out.contains("no accounts to switch"),
            "empty pick phase must state there is nothing to switch:\n{out}"
        );
        assert!(
            !out.contains("press a number to pick"),
            "empty pick phase must not prompt to pick a number:\n{out}"
        );
    }

    #[test]
    fn ascii_bullets_without_color_distinguish_state() {
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        // Distinct shapes: running '>', waiting '?', done '+', idle '.'.
        assert!(
            text.contains("> implementing the thing"),
            "running bullet missing:\n{text}"
        );
        assert!(text.contains("? "), "waiting bullet missing");
        assert!(text.contains("+ shipped a fix"), "done bullet missing");
    }

    #[test]
    fn colored_bullets_use_the_circle_glyph() {
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(120, true);
        let has_circle = p
            .frame(&m, None)
            .iter()
            .any(|l| l.spans.iter().any(|s| s.content.contains('\u{25cf}')));
        assert!(
            has_circle,
            "colored board should lead rows with the status circle"
        );
    }

    #[test]
    fn empty_foldable_section_is_skipped_but_always_sections_show() {
        let json = r#"{
          "now":"t","away":false,"health":{"beat_age_seconds":30},
          "header":{"summary":"s"},"gaps":[],
          "sections":{
            "captains_call":{"status":"empty","total":0,"shown":0,"merge_count":0,"rows":[]},
            "under_way":{"status":"empty","total":0,"shown":0,"rows":[]},
            "charted":{"status":"empty","total":0,"shown":0,"rows":[]},
            "landed":{"status":"empty","total":0,"shown":0,"rows":[]},
            "merge":{"total":0,"shown":0,"rows":[]},
            "secondmates":{"status":"empty","total":0,"shown":0,"rows":[]}
          }
        }"#;
        let m = parse(json).unwrap();
        let p = Painter::new(80, false);
        let joined = flatten(&p.frame(&m, None));
        // Always-shown sections render their header even when empty.
        assert!(
            joined.contains("Captain's Call"),
            "captains_call must always show"
        );
        assert!(joined.contains("Ready to merge"), "merge must always show");
        // Foldable empty sections are skipped entirely.
        assert!(
            !joined.contains("Under Way"),
            "empty under_way should fold away"
        );
        assert!(
            !joined.contains("Charted"),
            "empty charted should fold away"
        );
        assert!(
            !joined.contains("Second mates"),
            "empty secondmates should fold away"
        );
    }

    #[test]
    fn all_empty_ok_sections_never_paint_a_bare_rule() {
        // Mirrors empty_model() on the interactive no-cache path: `"sections":{}`
        // means every section defaults to status "ok" with zero rows. The four
        // foldable sections must fold away (no contentless bare rule); the two
        // always-shown sections keep their header; and the board must FIT the pane
        // so the honest note under the header is never clipped off the bottom.
        let json = r#"{"now":"","header":{"summary":"Fleet data is not available yet."},
            "health":{"beat_age_seconds":null},"sections":{}}"#;
        let m = parse(json).unwrap();

        // With a pane height (the interactive draw path).
        let h = 20u16;
        let p = Painter::with_rows(80, false, h);
        let lines = p.frame(&m, Some("live data not available: cache missing"));
        let joined = flatten(&lines);
        for title in ["Under Way", "Charted", "Recently Landed", "Second mates"] {
            assert!(
                !joined.contains(title),
                "empty-ok {title} must fold, not paint a bare rule:\n{joined}"
            );
        }
        assert!(
            joined.contains("Captain's Call"),
            "captains_call must always show"
        );
        assert!(joined.contains("Ready to merge"), "merge must always show");
        assert!(
            lines.len() <= h as usize,
            "degraded board overflowed the {h}-row pane: {} lines",
            lines.len()
        );
        assert!(
            joined.contains("Monitoring status is unknown"),
            "the honest health note was clipped off the bottom:\n{joined}"
        );

        // Same guarantee without a pane height (the static/piped degraded path):
        // an ok section with no rows still folds rather than painting a bare rule.
        let piped = flatten(&Painter::new(80, false).frame(&m, None));
        for title in ["Under Way", "Charted", "Recently Landed", "Second mates"] {
            assert!(
                !piped.contains(title),
                "empty-ok {title} must fold on the piped path:\n{piped}"
            );
        }
        assert!(
            piped.contains("Captain's Call"),
            "captains_call must always show (piped)"
        );
        assert!(
            piped.contains("Ready to merge"),
            "merge must always show (piped)"
        );
    }

    #[test]
    fn health_line_appears_only_when_lapsed_or_away() {
        // Healthy + present: no health line.
        let m = parse(full_model_json()).unwrap();
        let p = Painter::new(80, false);
        let joined = flatten(&p.frame(&m, None));
        assert!(
            !joined.contains("Monitoring"),
            "healthy fleet should paint no health line"
        );
        assert!(
            !joined.contains("marked away"),
            "present captain should paint no away line"
        );

        // Lapsed beat: a health line appears.
        let lapsed =
            full_model_json().replace("\"beat_age_seconds\": 30", "\"beat_age_seconds\": 4000");
        let m2 = parse(&lapsed).unwrap();
        let joined2 = flatten(&p.frame(&m2, None));
        assert!(
            joined2.contains("Monitoring may have lapsed"),
            "lapsed beat should surface"
        );
    }

    // === WP-4 nav-aware rendering =========================================
    use crate::nav::Nav;

    #[test]
    fn nav_frame_holds_the_width_guarantee_at_every_column_color_on_and_off() {
        let m = parse(full_model_json()).unwrap();
        let nav = Nav::new(&m);
        for &cols in &[40u16, 62, 80, 120] {
            for &color in &[true, false] {
                let p = Painter::new(cols, color);
                for line in p.nav_frame(&m, &nav, None) {
                    assert!(
                        line_width(&line) <= cols as usize,
                        "nav line exceeds {cols} cols (color={color}): width={}",
                        line_width(&line)
                    );
                }
            }
        }
    }

    #[test]
    fn nav_frame_marks_the_selected_item_with_the_gutter() {
        let m = parse(full_model_json()).unwrap();
        let mut nav = Nav::new(&m);
        nav.move_down(); // first row under captains_call
        let p = Painter::new(120, false);
        let lines = p.nav_frame(&m, &nav, None);
        // Exactly one line carries the selection gutter "> ".
        let selected: Vec<String> = lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .filter(|t| t.starts_with("> "))
            .collect();
        assert_eq!(
            selected.len(),
            1,
            "exactly one selected gutter, got {selected:?}"
        );
        assert!(
            selected[0].contains("decide-a"),
            "gutter should mark the selected row: {selected:?}"
        );
    }

    #[test]
    fn nav_frame_never_leaks_a_url_and_keeps_merge_terse() {
        let m = parse(full_model_json()).unwrap();
        let nav = Nav::new(&m);
        let p = Painter::new(200, false);
        let text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            !text.contains("http"),
            "a forge URL leaked into the nav board:\n{text}"
        );
        assert!(text.contains("fm/branch-one"), "merge id missing");
    }

    #[test]
    fn nav_frame_collapsed_section_hides_rows_behind_a_marker() {
        let m = parse(full_model_json()).unwrap();
        let mut nav = Nav::new(&m);
        nav.set_collapsed(SectionKind::CaptainsCall, true, &m);
        let p = Painter::new(120, false);
        let text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            text.contains("Captain's Call"),
            "collapsed section still shows its header"
        );
        assert!(text.contains("[+]"), "collapsed marker missing:\n{text}");
        assert!(text.contains("hidden"), "hidden-count marker missing");
        assert!(
            !text.contains("decide-a"),
            "collapsed rows must not paint:\n{text}"
        );
    }

    #[test]
    fn nav_frame_paints_the_empty_sentence_for_a_merge_with_no_rows() {
        let json = r#"{
          "now":"t","away":false,"health":{"beat_age_seconds":30},
          "header":{"summary":"s"},"gaps":[],
          "sections":{
            "captains_call":{"status":"ok","total":1,"shown":1,"merge_count":0,
              "rows":[{"id":"decide-a","summary":"a","bullet":"waiting"}]},
            "under_way":{"status":"empty","total":0,"shown":0,"rows":[]},
            "charted":{"status":"empty","total":0,"shown":0,"rows":[]},
            "landed":{"status":"empty","total":0,"shown":0,"rows":[]},
            "merge":{"total":0,"shown":0,"rows":[]},
            "secondmates":{"status":"empty","total":0,"shown":0,"rows":[]}
          }
        }"#;
        let m = parse(json).unwrap();
        let nav = Nav::new(&m);
        let p = Painter::new(80, false);
        let text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            text.contains("Ready to merge"),
            "merge header must always show:\n{text}"
        );
        assert!(
            text.contains("No finished branches waiting to merge."),
            "empty merge sentence missing (parity with the static board):\n{text}"
        );
    }

    #[test]
    fn nav_frame_folds_empty_ok_sections_like_the_static_board() {
        // The no-cache interactive path (empty_model) emits "sections":{}, so every
        // section defaults to status "ok" with zero rows. The nav board must fold
        // the four foldable sections exactly like the static board's folded():
        // neither their header nor an empty sentence paints, while the two
        // always-shown sections keep their header (parity with frame()).
        let json = r#"{"now":"","header":{"summary":"Fleet data is not available yet."},
            "health":{"beat_age_seconds":null},"sections":{}}"#;
        let m = parse(json).unwrap();
        let nav = Nav::new(&m);
        let p = Painter::new(80, false);
        let text = flatten(&p.nav_frame(&m, &nav, None));
        for title in ["Under Way", "Charted", "Recently Landed", "Second mates"] {
            assert!(
                !text.contains(title),
                "empty-ok {title} must fold on the nav board:\n{text}"
            );
        }
        assert!(
            text.contains("Captain's Call"),
            "captains_call must always show:\n{text}"
        );
        assert!(
            text.contains("Ready to merge"),
            "merge must always show:\n{text}"
        );
    }

    #[test]
    fn nav_frame_dividers_are_clean_full_width_rules() {
        let m = parse(full_model_json()).unwrap();
        let nav = Nav::new(&m);
        for &cols in &[40u16, 62, 80, 120] {
            let p = Painter::new(cols, false);
            for line in p.nav_frame(&m, &nav, None) {
                let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
                // A dash rule (after its 2-col gutter) must fill exactly cols with
                // no truncation ellipsis.
                if text.trim_start().starts_with("---") {
                    assert!(
                        !text.contains('\u{2026}'),
                        "divider clipped to an ellipsis at {cols} cols: {text:?}"
                    );
                    assert_eq!(
                        text.chars().count(),
                        cols as usize,
                        "divider should fill exactly {cols} cols: {text:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn detail_frame_shows_raw_body_and_scrolls() {
        let p = Painter::new(80, false);
        let body = (1..=50)
            .map(|i| format!("line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let lines = p.detail_frame("task-x - status log", &body, 10, 12);
        let text = lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(text.contains("Detail"), "detail title missing");
        assert!(
            text.contains("task-x - status log"),
            "detail subject missing"
        );
        // Scrolled to line 11 (0-based 10): the earlier lines are not shown.
        assert!(
            text.contains("line 11"),
            "scrolled body line missing:\n{text}"
        );
        assert!(
            !text.contains("\nline 1\n"),
            "pre-scroll line should be hidden"
        );
        // Every detail line still obeys the width guarantee.
        for l in &lines {
            assert!(
                line_width(l) <= 80,
                "detail line too wide: {}",
                line_width(l)
            );
        }
    }

    #[test]
    fn help_frame_lists_the_core_keys() {
        let p = Painter::new(80, false);
        let text = p
            .help_frame()
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(text.contains("quit"), "help should document quit");
        assert!(
            text.contains("open"),
            "help should document opening the drill-down"
        );
        assert!(
            text.contains("expand"),
            "help should document expand/collapse"
        );
    }

    // An uncapped model (as the cache stores it) with many rows per section, to
    // exercise the crate-owned vertical fit.
    fn many_rows_json() -> String {
        let mut call = String::new();
        let mut charted = String::new();
        let mut merge = String::new();
        for i in 0..20 {
            if i > 0 {
                call.push(',');
                charted.push(',');
                merge.push(',');
            }
            call.push_str(&format!(
                r#"{{"id":"c{i}","summary":"decision number {i}","bullet":"waiting"}}"#
            ));
            charted.push_str(&format!(
                r#"{{"id":"g{i}","title":"gate {i}","blocked_by":"-","reason":"-","bullet":"idle"}}"#
            ));
            merge.push_str(&format!(
                r#"{{"id":"fm/br{i}","branch":"fm/br{i}","dest":"main","url":"http://x/{i}","bullet":"done"}}"#
            ));
        }
        format!(
            r#"{{"now":"t","away":false,"health":{{"beat_age_seconds":30}},
              "header":{{"summary":"lots"}},"gaps":[],
              "sections":{{
                "captains_call":{{"status":"ok","rows":[{call}]}},
                "under_way":{{"status":"empty","rows":[]}},
                "charted":{{"status":"ok","rows":[{charted}]}},
                "landed":{{"status":"empty","rows":[]}},
                "merge":{{"rows":[{merge}]}},
                "secondmates":{{"status":"empty","rows":[]}}
              }}}}"#
        )
    }

    #[test]
    fn uncapped_model_without_pane_height_collapses_to_a_terse_board() {
        // No pane height: a fixed per-section cap keeps the board terse and shows a
        // "+N more" pointer rather than dumping all 20 rows.
        let m = parse(&many_rows_json()).unwrap();
        let p = Painter::new(80, false); // rows = None
        let joined = flatten(&p.frame(&m, None));
        // Only the first DEFAULT_CAP (6) decision rows appear.
        assert!(joined.contains("decision number 5"), "row 5 should show");
        assert!(
            !joined.contains("decision number 6"),
            "row 6 should be collapsed"
        );
        assert!(
            joined.contains("+14 more"),
            "collapse pointer missing:\n{joined}"
        );
    }

    #[test]
    fn short_pane_shows_fewer_rows_than_a_tall_one() {
        let m = parse(&many_rows_json()).unwrap();
        let count_rows = |h: u16| {
            let p = Painter::with_rows(80, false, h);
            flatten(&p.frame(&m, None))
                .lines()
                .filter(|l| l.contains("decision number"))
                .count()
        };
        let short = count_rows(16);
        let tall = count_rows(60);
        assert!(
            short < tall,
            "short pane {short} should show fewer than tall {tall}"
        );
        assert!(short >= 1, "even a short pane shows at least one decision");
    }

    #[test]
    fn vertical_fit_never_overflows_the_pane_height() {
        // A plain header (2 lines) and a header carrying the ITEM 4 usage line (3
        // lines): both must fit their budget. The usage line is fixed chrome the
        // fill loop has to reserve; without it the loop seats one row too many and
        // paints budget+1. Each variant is exercised from its mandatory-chrome
        // floor up (plain 10, usage 11 - the header, always-section rules, and
        // trailing lines the board always pays), the smallest pane it can occupy.
        let with_usage = many_rows_json().replace(
            r#""header":{"summary":"lots"}"#,
            r#""header":{"summary":"lots","usage":{"line":"5h 42% resets 14:00 · 7d 30% resets Mon"}}"#,
        );
        assert!(with_usage.contains("usage"), "usage line not injected");
        for (json, floor) in [(many_rows_json(), 10u16), (with_usage, 11u16)] {
            let m = parse(&json).unwrap();
            for &h in &[floor, 16, 24, 49] {
                let p = Painter::with_rows(80, false, h);
                let lines = p.frame(&m, None);
                assert!(
                    lines.len() <= h as usize,
                    "board painted {} lines into a {h}-row pane",
                    lines.len()
                );
            }
        }
    }

    #[test]
    fn always_sections_survive_a_short_pane() {
        // Even when the pane is tiny, the two sections the captain acts on
        // (open decisions, ready-to-merge) still render their header.
        let m = parse(&many_rows_json()).unwrap();
        let p = Painter::with_rows(80, false, 12);
        let joined = flatten(&p.frame(&m, None));
        assert!(
            joined.contains("Captain's Call"),
            "captains_call must survive a short pane"
        );
        assert!(
            joined.contains("Ready to merge"),
            "merge must survive a short pane"
        );
    }

    // A model header carrying a populated token-cost panel: burn + the if-API/
    // billed/covered split + cache-hit as the glance line, and a full drill-down
    // detail with heaviest engines and cost-per-landed-ticket.
    fn cost_model_json() -> &'static str {
        r#"{"now":"t","header":{"summary":"hi",
          "token_cost":{
            "line":"spend 7d: if-API $4.9k (billed $2.5k / covered $2.4k) · cache 98%",
            "detail":[
              "Fleet spend and efficiency",
              "",
              "Burn (last 7d): if-API $4.9k  billed $2.5k  covered $2.4k  (304 sessions)",
              "Cache hit ratio: 98%  (cache reads vs fresh input)",
              "",
              "Heaviest engines (last 7d):",
              "  claude-opus-4-8  if-API $3.5k / covered $2.3k  (198 sessions)",
              "",
              "Cost per landed ticket:",
              "  thin ledger: all 513 landed tickets are unattributable (no ledger rows yet).",
              "  This fills in as new work spawns; it is not $0 and not an error."]}},
          "sections":{}}"#
    }

    #[test]
    fn header_paints_the_token_cost_glance_line_when_present() {
        // The token-cost panel rides in the model header and both boards paint the
        // one terse glance line, once. The crate never re-costs a token (the
        // file-driven design point): it paints the line the lib pre-rendered.
        let m = parse(cost_model_json()).unwrap();
        let p = Painter::new(120, false);
        let static_text = flatten(&p.frame(&m, None));
        assert!(
            static_text.contains("spend 7d: if-API $4.9k (billed $2.5k / covered $2.4k)"),
            "static header must paint the cost glance line:\n{static_text}"
        );
        // The nav board reuses the same header, so it shows the same one line.
        let nav = Nav::new(&m);
        let nav_text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            nav_text.contains("if-API $4.9k"),
            "nav header must paint the cost glance line:\n{nav_text}"
        );
    }

    #[test]
    fn cost_glance_keeps_if_api_and_covered_separate() {
        // Captain ruling: cost_if_api and subscription-covered are SEPARATE facts,
        // never summed. The glance line must show both figures distinctly.
        let m = parse(cost_model_json()).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(
            text.contains("if-API $4.9k") && text.contains("covered $2.4k"),
            "if-API and covered must both appear as distinct figures:\n{text}"
        );
        // They are never merged into one combined total.
        assert!(
            !text.contains("total $7.3k") && !text.contains("$7.3k"),
            "the two facts must never be summed into one number:\n{text}"
        );
    }

    #[test]
    fn header_omits_the_token_cost_line_when_absent() {
        // No token_cost in the model (coster unread) -> no cost row and never a
        // blank line pretending to be one.
        let json = r#"{"now":"t","header":{"summary":"hi"},"sections":{}}"#;
        let m = parse(json).unwrap();
        let p = Painter::new(120, false);
        let text = flatten(&p.frame(&m, None));
        assert!(text.contains("hi"), "summary still paints");
        assert!(
            !text.contains("spend ") && !text.contains("if-API"),
            "no cost line when the model carries none:\n{text}"
        );
    }

    #[test]
    fn cost_hint_is_interactive_only() {
        // The "press $" hint names a key that only does something on the nav board,
        // so the static/piped board (no key can be pressed) must not claim it.
        let m = parse(cost_model_json()).unwrap();
        let p = Painter::new(120, false);
        let static_text = flatten(&p.frame(&m, None));
        assert!(
            !static_text.contains("press $"),
            "the static board must not claim the $ key:\n{static_text}"
        );
        let nav = Nav::new(&m);
        let nav_text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            nav_text.contains("press $"),
            "the nav board names the $ key under the cost line:\n{nav_text}"
        );
    }

    #[test]
    fn cost_frame_paints_the_drilldown_detail_verbatim() {
        // The $ overlay paints the model's pre-rendered detail lines, so the
        // heaviest engines and the honest thin-ledger cost-per-ticket note reach
        // the captain one keystroke away from the terse main view.
        let m = parse(cost_model_json()).unwrap();
        let detail = &m.header.token_cost.as_ref().unwrap().detail;
        let p = Painter::new(120, false);
        let text = flatten(&p.cost_frame(detail, 0, 40));
        assert!(text.contains("Spend"), "the overlay carries a title");
        assert!(
            text.contains("Heaviest engines (last 7d):")
                && text.contains("claude-opus-4-8  if-API $3.5k / covered $2.3k"),
            "the overlay shows the heaviest engines with if-API and covered kept apart:\n{text}"
        );
        assert!(
            text.contains("thin ledger: all 513 landed tickets are unattributable")
                && text.contains("not $0 and not an error"),
            "the thin-ledger cost-per-ticket note renders honestly, never as $0:\n{text}"
        );
    }

    #[test]
    fn cost_frame_is_honest_when_detail_is_empty() {
        // An empty detail slice must never paint a blank pane; it says so plainly.
        let p = Painter::new(80, false);
        let text = flatten(&p.cost_frame(&[], 0, 20));
        assert!(
            text.contains("no cost detail available"),
            "an empty cost overlay says so honestly:\n{text}"
        );
    }

    // === wrap: no text is lost off the right edge =============================

    // wrap_line breaks a long line into multiple rows, none over width, and the
    // concatenation (dropping continuation indent) recovers every non-space glyph.
    #[test]
    fn wrap_line_breaks_to_width_and_loses_no_glyph() {
        let long = "the quick brown fox jumps over the lazy dog and keeps running well past the edge";
        for &width in &[20usize, 24, 40] {
            let rows = wrap_line(&Line::from(long.to_string()), width, 2);
            assert!(rows.len() > 1, "long line did not wrap at width {width}");
            for r in &rows {
                let w: usize = r.spans.iter().map(|s| s.content.chars().count()).sum();
                assert!(w <= width, "wrapped row exceeds width {width}: {w}");
            }
            // Rejoin, strip the indent spaces and the wrap-collapsed spaces, and
            // confirm every alphabetic glyph of the source survives.
            let joined: String = rows
                .iter()
                .flat_map(|r| r.spans.iter().map(|s| s.content.as_ref()))
                .collect();
            let src_alpha: String = long.chars().filter(|c| c.is_alphabetic()).collect();
            let got_alpha: String = joined.chars().filter(|c| c.is_alphabetic()).collect();
            assert_eq!(
                src_alpha, got_alpha,
                "wrap dropped or reordered text at width {width}: {joined:?}"
            );
        }
    }

    // A single unbroken token wider than the pane (a long URL/path) must still be
    // fully recoverable: it hard-breaks across rows rather than being truncated.
    #[test]
    fn wrap_line_hard_breaks_an_unbroken_token() {
        let url = "https://example.com/a/very/long/compare/url/that/has/no/spaces/at/all/anywhere";
        let width = 24;
        let rows = wrap_line(&Line::from(url.to_string()), width, 2);
        assert!(rows.len() > 1, "long token did not hard-break");
        for r in &rows {
            let w: usize = r.spans.iter().map(|s| s.content.chars().count()).sum();
            assert!(w <= width, "hard-broken row too wide: {w}");
        }
        let joined: String = rows
            .iter()
            .enumerate()
            .flat_map(|(i, r)| {
                r.spans.iter().map(move |s| (i, s.content.as_ref()))
            })
            // Drop the 2-space continuation indent on rows after the first.
            .map(|(i, s)| if i == 0 { s.to_string() } else { s.trim_start_matches(' ').to_string() })
            .collect();
        assert!(
            joined.contains(url),
            "the full URL is not recoverable from the wrapped rows: {joined:?}"
        );
    }

    // The drill-down detail overlay is the "read the full thing" surface: a body
    // line far wider than the pane must be READABLE IN FULL (wrapped), never cut to
    // an ellipsis. This is the invariant that fails against the pre-wrap
    // clip-only detail_frame.
    #[test]
    fn detail_frame_wraps_long_body_lines_readable_in_full() {
        let p = Painter::new(40, false);
        let long = "This is a single very long detail line that must not be cut with an ellipsis but wrapped so the captain can read every word of it over ssh.";
        let lines = p.detail_frame("subject", long, 0, 40);
        for l in &lines {
            let w: usize = l.spans.iter().map(|s| s.content.chars().count()).sum();
            assert!(w <= 40, "detail line exceeds pane width: {w}");
        }
        let text = flatten(&lines);
        // Every word of the source body is present in the painted body: it wrapped
        // rather than being cut to an ellipsis. (The dim scroll footer is chrome and
        // may itself clip; the body invariant is what matters.)
        for word in long.split_whitespace() {
            assert!(
                text.contains(word),
                "detail body lost the word {word:?} instead of wrapping:\n{text}"
            );
        }
        // A wrapped detail body must not carry the truncation ellipsis on any body
        // row (rows before the footer).
        let body_only = &lines[2..lines.len().saturating_sub(1)];
        for l in body_only {
            let t: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
            assert!(
                !t.contains('\u{2026}'),
                "detail body row clipped instead of wrapping: {t:?}"
            );
        }
    }

    // detail_wrapped_len must exceed the raw line count for a wrapped body, so the
    // interactive scroll clamp can reach the wrapped tail.
    #[test]
    fn detail_wrapped_len_counts_wrapped_rows() {
        let p = Painter::new(30, false);
        let body = "one short\nnow a much much longer line that certainly wraps several times at thirty columns wide\nlast";
        let raw = body.lines().count();
        let wrapped = p.detail_wrapped_len(body);
        assert!(
            wrapped > raw,
            "wrapped-row count ({wrapped}) should exceed raw lines ({raw})"
        );
    }

    // The cost overlay wraps its pre-rendered body the same way, losing nothing.
    #[test]
    fn cost_frame_wraps_long_detail_lines() {
        let p = Painter::new(40, false);
        let detail = vec![
            "burn: a very long spend breakdown line that runs well past forty columns and must wrap".to_string(),
        ];
        let lines = p.cost_frame(&detail, 0, 40);
        for l in &lines {
            let w: usize = l.spans.iter().map(|s| s.content.chars().count()).sum();
            assert!(w <= 40, "cost line exceeds pane width: {w}");
        }
        let text = flatten(&lines);
        // Every word of the pre-rendered detail survives the wrap.
        for word in detail[0].split_whitespace() {
            assert!(text.contains(word), "cost body lost {word:?}:\n{text}");
        }
        // Body rows (before the dim footer) carry no truncation ellipsis.
        for l in &lines[2..lines.len().saturating_sub(1)] {
            let t: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
            assert!(!t.contains('\u{2026}'), "cost body row clipped: {t:?}");
        }
    }

    // The interactive board wraps the SELECTED row so its full headline is
    // readable in place, while still holding the width guarantee. The first
    // Captain's Call row (the long summary) is reached with one move_down from the
    // section header Nav::new selects.
    #[test]
    fn nav_frame_wraps_the_selected_row_readable_in_full() {
        let m = parse(full_model_json()).unwrap();
        for &cols in &[40u16, 62] {
            let mut nav = Nav::new(&m);
            nav.move_down(); // header -> first Captain's Call row (the long one)
            let p = Painter::new(cols, false);
            let lines = p.nav_frame(&m, &nav, None);
            // Width guarantee still holds on every line.
            for l in &lines {
                let w: usize = l.spans.iter().map(|s| s.content.chars().count()).sum();
                assert!(w <= cols as usize, "nav line exceeds {cols} cols: {w}");
            }
            // Locate the selected row's wrapped rows: the "> " gutter row plus its
            // indented continuations, up to the next non-continuation line.
            let flat: Vec<String> = lines
                .iter()
                .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
                .collect();
            let joined = flat.join("\n");
            // Word-wrap keeps each word whole, so every word of the long summary
            // appears even though it now spans several rows.
            for word in ["exceed", "narrow", "margin", "indeed"] {
                assert!(
                    joined.contains(word),
                    "selected row lost the word {word:?} at {cols} cols:\n{joined}"
                );
            }
            // The selected row itself must not carry a truncation ellipsis.
            let sel = flat
                .iter()
                .find(|t| t.starts_with("> ") && t.contains("very long decision"))
                .expect("selected long row present");
            assert!(
                !sel.contains('\u{2026}'),
                "selected row clipped instead of wrapping at {cols} cols: {sel:?}"
            );
        }
    }

    // Wrapping is scoped to the focused row: an UNSELECTED long row stays a single
    // clipped line (density preserved, full text one keystroke away). At Nav::new
    // the section header is selected, so the long first row is unselected.
    #[test]
    fn nav_frame_leaves_unselected_long_rows_terse() {
        let m = parse(full_model_json()).unwrap();
        let nav = Nav::new(&m); // header selected; the long row is NOT selected
        let p = Painter::new(40, false);
        let text = flatten(&p.nav_frame(&m, &nav, None));
        assert!(
            text.contains('\u{2026}'),
            "an unselected over-wide row should stay clipped (terse):\n{text}"
        );
    }
}
