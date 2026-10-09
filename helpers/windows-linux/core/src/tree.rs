//! The UI tree text the model reads: numbered lines (`#12 button "Save"`),
//! element numbers that stay with the same element for the whole session, change lists
//! (M modified / A added / D deleted) and the footer.

use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};

/// One accessibility element as read by a platform layer (roles already in our words:
/// "button", "text field", "text", "link", "window", …).
#[derive(Clone, Debug, Default)]
pub struct Node {
    pub role: String,
    pub subrole: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub placeholder: Option<String>,
    pub identifier: Option<String>,
    pub value: Option<String>,
    pub url: Option<String>,
    pub focused: bool,
    pub selected: bool,
    pub disabled: bool,
    pub editable: bool,
    pub expanded: bool,
    pub checked: bool,
    pub secure: bool,
    /// Display names ("Increment", "Show Menu", …); the default press action is left out.
    pub actions: Vec<String>,
    pub children: Vec<Node>,
    /// Index into `Snapshot::elements` (the live element), if any.
    pub element: Option<usize>,
    /// Identity of the live element: equal for two reads of the same UI element.
    pub identity: Option<String>,
    /// Another window of the app: one summary line, children not read.
    pub summary_only: bool,
    /// "(rows 41–58 of 1200 shown; …)" for long lists cut to their visible rows.
    pub rows_note: Option<String>,
    pub is_window: bool,
    pub in_menu_bar: bool,
    pub is_web_area: bool,
    /// Screen frame (x, y, w, h) when known.
    pub frame: Option<(f64, f64, f64, f64)>,
}

const PURE_CONTAINERS: &[&str] = &["group", "pane", "generic", "unknown", "scroll area", "layout area", "split group", "custom", "section", "panel", "filler", "cell"];
/// Roles whose value is something to type or set: `editable` means it there.
const EDITABLE_ROLES: &[&str] = &["text field", "text area", "combo box", "slider", "spin button", "stepper", "scroll bar", "document"];
/// Rows / cells / groups that show nothing anywhere inside are left out.
const EMPTY_ROLES: &[&str] = &["row", "cell", "group", "pane", "generic", "unknown", "column", "filler", "panel", "section", "custom"];
/// Containers whose frame bounds what their children can show.
const CLIPPING_ROLES: &[&str] = &["window", "scroll area", "web area", "document"];
/// Actions every row / cell offers, which say nothing about content.
const INCIDENTAL_ACTIONS: &[&str] = &["Show Default UI", "Show Alternate UI", "Scroll to Visible", "Show Menu", "Expand or Collapse"];
/// Cell roles a compact row may contain, and the actions they may have.
const PLAIN_CELL_ROLES: &[&str] = &["cell", "text", "text field", "image", "group", "unknown", "generic"];
const PLAIN_CELL_ACTIONS: &[&str] = &["Confirm", "Open", "Show Default UI", "Show Alternate UI", "Scroll to Visible", "Show Menu", "Select"];
pub const MAX_ELEMENTS: usize = 1500;
const MAX_DEPTH: usize = 40;
const VALUE_LIMIT: usize = 160;
const TEXT_LIMIT: usize = 300;

impl Node {
    fn label(&self) -> Option<(&'static str, &str)> {
        for (kind, v) in [("title", &self.title), ("description", &self.description)] {
            if let Some(s) = v.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                return Some((kind, s));
            }
        }
        if let Some(s) = self.placeholder.as_deref().filter(|s| !s.trim().is_empty()) {
            return Some(("placeholder", s));
        }
        if let Some(s) = self.identifier.as_deref().filter(|s| !s.trim().is_empty()) {
            return Some(("id", s));
        }
        None
    }

    fn is_text(&self) -> bool {
        self.role == "text"
    }

    fn prunable(&self) -> bool {
        PURE_CONTAINERS.contains(&self.role.as_str())
            && self.label().is_none()
            && self.value.as_deref().map_or(true, |v| v.trim().is_empty())
            && self.actions.is_empty()
            && !self.focused
            && !self.is_window
    }

    /// Stable label used in the path key (identifiers cut at `?` / `#`, windows have none).
    fn stable_label(&self) -> String {
        if self.is_window {
            return String::new();
        }
        match self.label() {
            Some(("id", s)) => s.split(['?', '#']).next().unwrap_or("").to_string(),
            Some((_, s)) => s.to_string(),
            None => String::new(),
        }
    }
}

/// One line, `"` escaped, newlines as `\n`, truncated with `…`.
pub fn escape(s: &str, limit: usize) -> String {
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i >= limit {
            out.push('…');
            break;
        }
        match ch {
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

fn inline_text(s: &str, limit: usize) -> String {
    escape(s, limit).replace("\\\"", "\"")
}

/// `https://www.example.com/a/` → `example.com/a`; long URLs shortened to 60 characters.
pub fn shorten_url(url: &str) -> String {
    let mut u = url.trim();
    for p in ["https://", "http://"] {
        if let Some(r) = u.strip_prefix(p) {
            u = r;
        }
    }
    let mut u = u.strip_prefix("www.").unwrap_or(u).to_string();
    if u.ends_with('/') && u.matches('/').count() == 1 {
        u.pop();
    }
    if u.chars().count() > 60 {
        if let Some(q) = u.find('?') {
            u = format!("{}?…", &u[..q]);
        }
        if u.chars().count() > 60 {
            u = u.chars().take(59).collect::<String>() + "…";
        }
    }
    u
}

/// The text after `#i ` for one node.
pub fn render_line(node: &Node, index: usize) -> String {
    if node.is_text() {
        let mut head = format!("#{index} text");
        if let Some(id) = node.identifier.as_deref().filter(|s| !s.is_empty()) {
            head += &format!(" id={}", escape(id, 80));
        }
        let content = node.value.as_deref().or(node.title.as_deref()).or(node.description.as_deref()).unwrap_or("");
        return if content.trim().is_empty() { head } else { format!("{head}: {}", inline_text(content, TEXT_LIMIT)) };
    }
    let mut parts = vec![format!("#{index}"), node.role.clone()];
    if let Some(sub) = node.subrole.as_deref().filter(|s| !s.is_empty() && *s != node.role) {
        parts.push(format!("({sub})"));
    }
    let label = node.label();
    if node.role == "link" {
        if let Some(url) = node.url.as_deref().filter(|u| !u.is_empty()) {
            let text = label.map(|(_, s)| s).unwrap_or("");
            parts.push(format!("[{}]({})", inline_text(text, TEXT_LIMIT).replace(']', "\\]"), shorten_url(url)));
        } else if let Some((_, s)) = label {
            parts.push(format!("\"{}\"", escape(s, VALUE_LIMIT)));
        }
    } else {
        match label {
            Some(("placeholder", s)) => parts.push(format!("placeholder=\"{}\"", escape(s, VALUE_LIMIT))),
            Some(("id", s)) => parts.push(format!("id={}", escape(s, 80))),
            Some((_, s)) => parts.push(format!("\"{}\"", escape(s, VALUE_LIMIT))),
            None => {}
        }
    }
    let editable = node.editable
        && (node.secure || EDITABLE_ROLES.contains(&node.role.as_str()) || node.value.as_deref().is_some_and(|v| !v.trim().is_empty() && v.parse::<f64>().is_err()));
    if !node.secure {
        if let Some(v) = node.value.as_deref().filter(|v| !v.is_empty()) {
            if label.map(|(_, s)| s) != Some(v) {
                parts.push(format!("value=\"{}\"", escape(v, VALUE_LIMIT)));
            }
        }
    }
    let mut flags = vec![];
    for (on, name) in [
        (node.focused, "focused"),
        (node.selected, "selected"),
        (node.disabled, "disabled"),
        (editable, "editable"),
        (node.expanded, "expanded"),
        (node.checked, "checked"),
        (node.secure, "secure"),
    ] {
        if on {
            flags.push(name);
        }
    }
    if !flags.is_empty() {
        parts.push(format!("{{{}}}", flags.join(", ")));
    }
    if let Some(rows) = &node.rows_note {
        parts.push(rows.clone());
    }
    if node.summary_only {
        parts.push("(other window; contents not shown — perform Raise to switch to it)".into());
    }
    let actions: Vec<String> = dedup(&node.actions).into_iter().map(|a| a.replace(',', ";")).collect();
    if !actions.is_empty() {
        parts.push(format!("actions={}", actions.join(",")));
    }
    parts.join(" ")
}

fn dedup(v: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    v.iter().filter(|a| !a.trim().is_empty() && seen.insert(a.to_lowercase())).cloned().collect()
}

fn hash64<T: Hash>(t: &T) -> u64 {
    // FNV-1a over the Hash stream (stable within a process run, which is all indices need).
    struct Fnv(u64);
    impl Hasher for Fnv {
        fn finish(&self) -> u64 {
            self.0
        }
        fn write(&mut self, bytes: &[u8]) {
            for b in bytes {
                self.0 ^= *b as u64;
                self.0 = self.0.wrapping_mul(0x100_0000_01b3);
            }
        }
    }
    let mut h = Fnv(0xcbf2_9ce4_8422_2325);
    t.hash(&mut h);
    h.finish()
}

/// Assigns element numbers: the same live element keeps its
/// number; a vanished element's replacement (same path key) inherits it; else a new one.
#[derive(Default)]
pub struct Indexer {
    next: usize,
    by_identity: HashMap<String, usize>,
    by_path: HashMap<u64, Vec<usize>>,
    path_of: HashMap<usize, u64>,
    /// Whether the element last given each number had a live identity.
    had_identity: HashMap<usize, bool>,
}

impl Indexer {
    pub fn assign(
        &mut self,
        path: u64,
        identity: Option<&str>,
        used: &HashSet<usize>,
        alive: &mut dyn FnMut(usize) -> bool,
    ) -> usize {
        if let Some(id) = identity {
            if let Some(&i) = self.by_identity.get(id) {
                if !used.contains(&i) {
                    self.remember(i, path, Some(id));
                    return i;
                }
            }
        }
        let candidates = self.by_path.get(&path).cloned().unwrap_or_default();
        for i in candidates {
            // Elements without a live identity can only be matched by position.
            let positional = identity.is_none() && !self.had_identity.get(&i).copied().unwrap_or(false);
            if !used.contains(&i) && (positional || !alive(i)) {
                self.remember(i, path, identity);
                return i;
            }
        }
        let i = self.next;
        self.next += 1;
        self.remember(i, path, identity);
        i
    }

    fn remember(&mut self, i: usize, path: u64, identity: Option<&str>) {
        self.had_identity.insert(i, identity.is_some());
        if let Some(old) = self.path_of.insert(i, path) {
            if old != path {
                if let Some(v) = self.by_path.get_mut(&old) {
                    v.retain(|x| *x != i);
                }
            }
        }
        let v = self.by_path.entry(path).or_default();
        if !v.contains(&i) {
            v.push(i);
        }
        if let Some(id) = identity {
            self.by_identity.insert(id.to_string(), i);
        }
    }

    pub fn knows(&self, i: usize) -> bool {
        self.path_of.contains_key(&i)
    }
}

#[derive(Clone, Debug)]
pub struct SerElem {
    pub index: usize,
    pub depth: usize,
    pub line: String,
    pub element: Option<usize>,
    pub secure: bool,
    pub focused: bool,
    pub role: String,
    pub label: Option<String>,
    pub actions: Vec<String>,
    pub in_menu_bar: bool,
    pub is_window: bool,
}

#[derive(Clone, Debug, Default)]
pub struct SerializedTree {
    pub elems: Vec<SerElem>,
    pub truncated: bool,
}

impl SerializedTree {
    pub fn baseline(&self) -> HashMap<usize, String> {
        self.elems.iter().map(|e| (e.index, e.line.clone())).collect()
    }
    pub fn full_text(&self) -> String {
        let mut out = String::new();
        for e in &self.elems {
            out += &"  ".repeat(e.depth);
            out += &e.line;
            out.push('\n');
        }
        if self.truncated {
            out += &format!("… tree truncated at {MAX_ELEMENTS} elements; act on visible elements or scroll\n");
        }
        out
    }
}

/// Icon fonts draw their glyphs from Unicode's private-use areas: such characters show
/// nothing in text and are dropped (an icon-only label is no label).
pub fn without_icon_glyphs(s: &str) -> String {
    let is_glyph = |c: char| ('\u{E000}'..='\u{F8FF}').contains(&c) || (c as u32) >= 0xF0000;
    if !s.chars().any(is_glyph) {
        return s.to_string();
    }
    s.chars().filter(|c| !is_glyph(*c)).collect::<String>().trim().to_string()
}

fn cleaned(node: &Node) -> Node {
    let fix = |v: &Option<String>| v.as_deref().map(without_icon_glyphs).filter(|t| !t.trim().is_empty());
    let mut n = node.clone();
    n.title = fix(&node.title);
    n.description = fix(&node.description);
    n.placeholder = fix(&node.placeholder);
    if !node.secure {
        n.value = node.value.as_deref().map(without_icon_glyphs);
    }
    n.children = node.children.iter().map(cleaned).collect();
    n
}

fn holds_focus(n: &Node) -> bool {
    n.focused || n.children.iter().any(holds_focus)
}

fn has_content(n: &Node) -> bool {
    if n.focused || n.selected || n.summary_only || n.rows_note.is_some() || n.secure || n.is_window {
        return true;
    }
    if n.label().is_some() || n.value.as_deref().is_some_and(|v| !v.trim().is_empty()) {
        return true;
    }
    if !EMPTY_ROLES.contains(&n.role.as_str()) {
        return true;
    }
    if n.actions.iter().any(|a| !INCIDENTAL_ACTIONS.iter().any(|i| i.eq_ignore_ascii_case(a))) {
        return true;
    }
    n.children.iter().any(has_content)
}

/// A table row of plain cells as one line of text, None when it has anything
/// else (buttons, check boxes, password fields, the keyboard focus).
pub fn row_summary(row: &Node) -> Option<String> {
    if row.role != "row" || row.children.is_empty() {
        return None;
    }
    let mut parts = vec![];
    fn walk(n: &Node, parts: &mut Vec<String>) -> bool {
        if !PLAIN_CELL_ROLES.contains(&n.role.as_str()) || n.secure || n.focused {
            return false;
        }
        if !n.actions.iter().all(|a| PLAIN_CELL_ACTIONS.iter().any(|p| p.eq_ignore_ascii_case(a))) {
            return false;
        }
        if n.role != "image" {
            let text = n.value.as_deref().filter(|v| !v.trim().is_empty()).or(n.label().map(|(_, s)| s));
            if let Some(t) = text {
                if n.children.is_empty() || n.role != "cell" {
                    parts.push(inline_text(t, 80));
                }
            }
        }
        n.children.iter().all(|c| walk(c, parts))
    }
    if !row.children.iter().all(|c| walk(c, &mut parts)) || parts.is_empty() {
        return None;
    }
    let joined = parts.join(" | ");
    Some(if joined.chars().count() > 300 { joined.chars().take(300).collect::<String>() + "…" } else { joined })
}

type Frame = (f64, f64, f64, f64);

fn has_area(f: &Frame) -> bool {
    f.2 > 0.5 && f.3 > 0.5
}

fn intersects(a: &Frame, b: &Frame) -> bool {
    a.0 < b.0 + b.2 && b.0 < a.0 + a.2 && a.1 < b.1 + b.3 && b.1 < a.1 + a.3
}

/// At least 2 × 2 points of `f` lie inside `area`: some toolkits report content scrolled out
/// of view squeezed into a 1-point strip on the edge of the visible area.
fn shows_in(f: &Frame, area: &Frame) -> bool {
    intersects(f, area) && {
        let i = intersection(f, area);
        i.2 >= 2.0 && i.3 >= 2.0
    }
}

fn intersection(a: &Frame, b: &Frame) -> Frame {
    let (x0, y0) = (a.0.max(b.0), a.1.max(b.1));
    let (x1, y1) = ((a.0 + a.2).min(b.0 + b.2), (a.1 + a.3).min(b.1 + b.3));
    (x0, y0, (x1 - x0).max(0.0), (y1 - y0).max(0.0))
}

pub fn visible_note(hidden: usize) -> String {
    format!("(… {hidden} more item{} outside the visible area; scroll to see {})", if hidden == 1 { "" } else { "s" }, if hidden == 1 { "it" } else { "them" })
}

/// Number the roots (windows first, then open menus and the menu bar) depth-first.
pub fn serialize(roots: &[Node], indexer: &mut Indexer, alive: &mut dyn FnMut(usize) -> bool) -> SerializedTree {
    let mut tree = SerializedTree::default();
    let mut used = HashSet::new();
    let mut ordinals: Vec<HashMap<u64, usize>> = vec![HashMap::new()];
    let mut hidden: HashMap<usize, usize> = HashMap::new();
    for root in roots.iter().map(cleaned) {
        let mut ctx = Walk { ordinals: &mut ordinals, tree: &mut tree, indexer, used: &mut used, alive, hidden: &mut hidden };
        walk(&root, 0, 0x9e37_79b9, None, None, &mut ctx);
    }
    for (i, n) in hidden {
        if let Some(e) = tree.elems.get_mut(i) {
            e.line = format!("{} {}", e.line, visible_note(n));
        }
    }
    tree
}

struct Walk<'a> {
    ordinals: &'a mut Vec<HashMap<u64, usize>>,
    tree: &'a mut SerializedTree,
    indexer: &'a mut Indexer,
    used: &'a mut HashSet<usize>,
    alive: &'a mut dyn FnMut(usize) -> bool,
    /// Element position → descendants left out as outside the visible area.
    hidden: &'a mut HashMap<usize, usize>,
}

fn walk(node: &Node, depth: usize, parent_path: u64, clip: Option<Frame>, note_target: Option<usize>, ctx: &mut Walk) {
    if ctx.tree.elems.len() >= MAX_ELEMENTS {
        ctx.tree.truncated = true;
        return;
    }
    // Outside the visible part of its scroll area / page / window: left out, counted on the
    // nearest listed container. What has the keyboard stays.
    if let (Some(c), Some(f)) = (clip, node.frame) {
        if has_area(&f) && !shows_in(&f, &c) && !holds_focus(node) {
            if let Some(t) = note_target {
                *ctx.hidden.entry(t).or_insert(0) += 1;
            }
            return;
        }
    }
    if EMPTY_ROLES.contains(&node.role.as_str()) && !has_content(node) {
        return;
    }
    // A text that shows nothing (an icon glyph, whitespace).
    if node.is_text() && node.children.is_empty() && !node.focused
        && [&node.value, &node.title, &node.description].iter().all(|v| v.as_deref().map_or(true, |s| s.trim().is_empty()))
    {
        return;
    }
    let child_clip = if node.in_menu_bar || node.role == "menu" || node.role == "menu bar" {
        None
    } else if CLIPPING_ROLES.contains(&node.role.as_str()) || node.is_window {
        match (clip, node.frame.filter(has_area)) {
            (Some(c), Some(f)) => Some(intersection(&c, &f)),
            (None, Some(f)) => Some(f),
            (c, None) => c,
        }
    } else {
        clip
    };
    let summary = row_summary(node);
    if summary.is_none() && node.prunable() && depth > 0 {
        for c in &node.children {
            walk(c, depth, parent_path, child_clip, note_target, ctx);
        }
        return;
    }
    let (ordinals, tree, indexer, used) = (&mut *ctx.ordinals, &mut *ctx.tree, &mut *ctx.indexer, &mut *ctx.used);
    let sig = hash64(&(node.role.as_str(), node.subrole.as_deref(), node.stable_label()));
    let level = ordinals.last_mut().unwrap();
    let ordinal = {
        let n = level.entry(sig).or_insert(0);
        *n += 1;
        *n
    };
    let path = hash64(&(parent_path, sig, ordinal));
    let identity = node.identity.as_ref().map(|id| format!("{id}|{}|{}", node.role, node.subrole.as_deref().unwrap_or("")));
    let index = indexer.assign(path, identity.as_deref(), used, &mut *ctx.alive);
    used.insert(index);
    let line = match &summary {
        Some(s) => {
            // Every row offers these: they say nothing on a one-line row.
            let mut plain = node.clone();
            plain.children.clear();
            plain.actions.retain(|a| !INCIDENTAL_ACTIONS.iter().any(|i| i.eq_ignore_ascii_case(a)));
            format!("{}: {s}", render_line(&plain, index))
        }
        None => render_line(node, index),
    };
    tree.elems.push(SerElem {
        index,
        depth,
        line,
        element: node.element,
        secure: node.secure,
        focused: node.focused,
        role: node.role.clone(),
        label: node.label().map(|(_, s)| s.to_string()),
        actions: dedup(&node.actions),
        in_menu_bar: node.in_menu_bar,
        is_window: node.is_window,
    });
    let me = tree.elems.len() - 1;
    if depth + 1 >= MAX_DEPTH || summary.is_some() {
        return;
    }
    ctx.ordinals.push(HashMap::new());
    // Hidden items are counted on the container that cuts them off, not on each card.
    let target = if CLIPPING_ROLES.contains(&node.role.as_str()) || node.is_window || note_target.is_none() { Some(me) } else { note_target };
    for c in &node.children {
        walk(c, depth + 1, path, child_clip, target, ctx);
    }
    ctx.ordinals.pop();
}

/// Change list against the previous observation: `M` modified, `A` added, `D gone: #…`.
pub fn diff_lines(tree: &SerializedTree, previous: &HashMap<usize, String>, ignore_removed: &HashSet<usize>) -> Vec<String> {
    let mut lines = vec![];
    let mut present = HashSet::new();
    for e in &tree.elems {
        present.insert(e.index);
        match previous.get(&e.index) {
            Some(old) if old != &e.line => lines.push(format!("M {}", e.line)),
            Some(_) => {}
            None => lines.push(format!("A {}", e.line)),
        }
    }
    let mut removed: Vec<usize> =
        previous.keys().copied().filter(|i| !present.contains(i) && !ignore_removed.contains(i)).collect();
    removed.sort_unstable();
    if !removed.is_empty() {
        lines.push(format!("D gone: {}", compress_ranges(&removed)));
    }
    lines
}

pub fn compress_ranges(sorted: &[usize]) -> String {
    let mut parts = vec![];
    let mut i = 0;
    while i < sorted.len() {
        let start = sorted[i];
        let mut end = start;
        while i + 1 < sorted.len() && sorted[i + 1] == end + 1 {
            i += 1;
            end = sorted[i];
        }
        parts.push(if start == end { format!("#{start}") } else { format!("#{start}-#{end}") });
        i += 1;
    }
    parts.join(", ")
}

/// Few elements outside the menu bar and nothing text-like in a big window: the app draws
/// its own UI (games, 3D tools).
pub fn is_sparse(tree: &SerializedTree, window_area: f64, has_web: bool) -> bool {
    if tree.truncated || has_web || window_area < 160_000.0 {
        return false;
    }
    let content: Vec<&SerElem> = tree.elems.iter().filter(|e| !e.in_menu_bar && !e.is_window).collect();
    content.len() <= 15
        && !content.iter().any(|e| {
            matches!(e.role.as_str(), "text field" | "text area" | "document" | "table" | "list" | "tree" | "outline" | "web area")
        })
}

pub const SELECTION_NOTE: &str = "Note: this text is selected (by the user, or by an earlier pick_text); when the user refers to \"this\" or \"the selection\", they probably mean it.";
pub const SPARSE_NOTE: &str = "Accessibility shows almost nothing for this app (it draws its own UI) — rely on the screenshot.";

pub struct Observation<'a> {
    pub header: Vec<String>,
    pub notes: Vec<String>,
    pub tree: &'a SerializedTree,
    pub previous: Option<&'a HashMap<usize, String>>,
    pub ignore_removed: HashSet<usize>,
    pub full_tree: bool,
    pub focused_index: Option<usize>,
    pub selected_text: Option<String>,
    pub sparse: bool,
    pub screenshot_change: Option<f64>,
}

pub struct Rendered {
    pub text: String,
    pub is_diff: bool,
}

pub fn render(o: &Observation) -> Rendered {
    let mut body = o.header.join("\n") + "\n";
    for n in &o.notes {
        body += n;
        body.push('\n');
    }
    let full = o.tree.full_text();
    let mut is_diff = false;
    let mut tree_text = full.clone();
    if let (Some(prev), false) = (o.previous, o.full_tree) {
        let changes = diff_lines(o.tree, prev, &o.ignore_removed);
        if changes.is_empty() {
            tree_text = if o.sparse {
                format!("{}; no accessibility changes.\n", SPARSE_NOTE.trim_end_matches('.'))
            } else {
                "No changes since the last observe_app.\n".into()
            };
            is_diff = true;
        } else {
            let diff = format!("Changes since the last observe_app (M modified, A added, D deleted):\n{}\n", changes.join("\n"));
            if diff.len() * 10 <= full.len() * 6 && changes.len() <= 400 {
                tree_text = diff;
                is_diff = true;
            }
        }
    }
    if o.sparse && !(is_diff && tree_text.contains("no accessibility changes")) {
        body += SPARSE_NOTE;
        body.push('\n');
    }
    body += &tree_text;
    if let Some(change) = o.screenshot_change {
        body += &screenshot_change_line(change);
        body.push('\n');
    }
    // Footer.
    if let Some(fi) = o.focused_index.or_else(|| o.tree.elems.iter().rev().find(|e| e.focused && !e.is_window).map(|e| e.index)) {
        if let Some(e) = o.tree.elems.iter().find(|e| e.index == fi) {
            let label = e.label.as_deref().map(|l| format!(" \"{}\"", escape(l, 80))).unwrap_or_default();
            body += &format!("Keyboard focus: #{} {}{}\n", e.index, e.role, label);
            if !e.actions.is_empty() {
                body += &format!("More actions on #{}: {}\n", e.index, e.actions.join(", "));
            }
        }
    }
    if let Some(sel) = o.selected_text.as_deref().filter(|s| !s.trim().is_empty()) {
        body += &format!("Selection: \"{}\"\n{SELECTION_NOTE}\n", escape(sel, 300));
    }
    Rendered { text: body.trim_end().to_string(), is_diff }
}

pub fn screenshot_change_line(fraction: f64) -> String {
    if fraction <= 0.0 {
        return "Screenshot changed: no large change (small edits such as text in a field may not register; look at the image)".into();
    }
    let pct = fraction * 100.0;
    let amount = if pct < 1.0 { "<1%".to_string() } else { format!("≈{}%", pct.round() as i64) };
    format!("Screenshot changed: yes ({amount} of the image)")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(role: &str, title: &str) -> Node {
        Node { role: role.into(), title: Some(title.into()), ..Default::default() }
    }

    #[test]
    fn lines_and_numbers() {
        let mut w = node("window", "Doc");
        w.is_window = true;
        let mut field = Node { role: "text field".into(), placeholder: Some("Name".into()), value: Some("Ada".into()), focused: true, editable: true, ..Default::default() };
        field.identity = Some("f1".into());
        let mut group = Node { role: "group".into(), ..Default::default() };
        group.children = vec![field.clone(), node("button", "Greet")];
        w.children = vec![group];
        let mut ix = Indexer::default();
        let t = serialize(&[w.clone()], &mut ix, &mut |_| true);
        assert_eq!(t.elems[0].line, "#0 window \"Doc\"");
        assert_eq!(t.elems[1].line, "#1 text field placeholder=\"Name\" value=\"Ada\" {focused, editable}");
        assert_eq!(t.elems[1].depth, 1); // group hoisted
        // Same identity keeps its number although the value changed.
        w.children[0].children[0].value = Some("Bob".into());
        let t2 = serialize(&[w], &mut ix, &mut |_| true);
        assert_eq!(t2.elems[1].index, 1);
        let d = diff_lines(&t2, &t.baseline(), &HashSet::new());
        assert_eq!(d, vec!["M #1 text field placeholder=\"Name\" value=\"Bob\" {focused, editable}"]);
    }

    #[test]
    fn ranges_and_urls() {
        assert_eq!(compress_ranges(&[1, 2, 3, 9, 10, 12]), "#1-#3, #9-#10, #12");
        assert_eq!(shorten_url("https://www.example.com/"), "example.com");
        let mut l = node("link", "Example");
        l.url = Some("https://example.com/a".into());
        assert_eq!(render_line(&l, 7), "#7 link [Example](example.com/a)");
        let t = Node { role: "text".into(), value: Some("Hello".into()), ..Default::default() };
        assert_eq!(render_line(&t, 5), "#5 text: Hello");
    }
}

#[cfg(test)]
mod visible_tests {
    use super::*;

    fn node(role: &str, title: Option<&str>, frame: Option<(f64, f64, f64, f64)>, children: Vec<Node>) -> Node {
        Node { role: role.into(), title: title.map(str::to_string), frame, children, ..Default::default() }
    }

    #[test]
    fn rows_compact_offscreen_hidden_glyphs_dropped() {
        let cell = |t: &str| Node { role: "text".into(), value: Some(t.into()), ..Default::default() };
        let row = |y: f64, a: &str| Node { role: "row".into(), frame: Some((0.0, y, 100.0, 20.0)), children: vec![cell(a), cell("1.5")], ..Default::default() };
        let list = Node {
            role: "scroll area".into(),
            frame: Some((0.0, 0.0, 100.0, 50.0)),
            children: vec![row(0.0, "Siri"), row(20.0, "tccd"), row(500.0, "far"), row(600.0, "farther")],
            ..Default::default()
        };
        let win = Node { is_window: true, role: "window".into(), title: Some("W".into()), frame: Some((0.0, 0.0, 100.0, 100.0)), children: vec![
            list,
            node("button", Some("\u{E000}"), None, vec![]),
            node("button", Some("\u{E001} Open"), None, vec![]),
            node("row", None, None, vec![node("cell", None, None, vec![])]),
        ], ..Default::default() };
        let mut ix = Indexer::default();
        let t = serialize(&[win], &mut ix, &mut |_| true);
        let text = t.full_text();
        assert!(text.contains("row: Siri | 1.5"), "{text}");
        assert!(!text.contains("far"), "{text}");
        assert!(text.contains("2 more items outside the visible area"), "{text}");
        assert!(text.contains("button \"Open\""), "{text}");
        assert!(!text.contains('\u{E000}'), "{text}");
        assert_eq!(text.matches(" row").count(), 2, "{text}");
    }
}
