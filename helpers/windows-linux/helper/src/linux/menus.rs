//! Menu commands through AT-SPI: toolkits expose an app's
//! menu bar with every menu and item, also while no menu is open. Apps without a menu bar
//! (GTK 4 apps keep their commands in popover menus) expose them as their window's actions:
//! "win.new-tab" reads "Win.new Tab", a group per prefix.

use std::time::Instant;

use turbo_core::events::{self, Command, Located, MenuRead};

use super::atspi::{has, state, Atspi, El};

const MAX_ITEMS: usize = 4000;
const MAX_DEPTH: usize = 6;

/// The app's menu bar (bounded search of its windows, the active one first).
pub fn menu_bar(a: &Atspi, app: &El) -> Option<El> {
    let mut tops = a.children(app);
    tops.sort_by_key(|t| !has(a.states(t), state::ACTIVE));
    let mut queue: std::collections::VecDeque<(El, usize)> = tops.into_iter().map(|t| (t, 0)).collect();
    let mut seen = 0;
    while let Some((el, depth)) = queue.pop_front() {
        seen += 1;
        if seen > 600 {
            return None;
        }
        match a.role_name(&el).as_deref() {
            Some("menu bar") => return Some(el),
            // Menus and their items never contain the bar; nor does anything deeper than 8.
            Some("menu") | Some("menu item") | Some("popup menu") => continue,
            _ => {}
        }
        if depth < 8 {
            queue.extend(a.children(&el).into_iter().map(|c| (c, depth + 1)));
        }
    }
    None
}

fn is_item(role: &str) -> bool {
    matches!(role, "menu item" | "check menu item" | "radio menu item" | "menu")
}

fn title(a: &Atspi, el: &El) -> Option<String> {
    a.name(el).map(|n| events::display_title(&n)).filter(|t| !t.trim().is_empty())
}

fn enabled(a: &Atspi, el: &El) -> bool {
    let st = a.states(el);
    has(st, state::SENSITIVE) || has(st, state::ENABLED)
}

/// "<Primary><Shift>s" (the accelerator part of a key binding) → "ctrl+shift+s".
pub fn accelerator(binding: &str) -> Option<String> {
    let accel = binding.split(';').nth(2)?.trim();
    if accel.is_empty() {
        return None;
    }
    let mut mods = vec![];
    let mut rest = accel;
    while let Some(stripped) = rest.strip_prefix('<') {
        let end = stripped.find('>')?;
        let m = stripped[..end].to_lowercase();
        rest = &stripped[end + 1..];
        match m.as_str() {
            "primary" | "control" | "ctrl" => mods.push("Ctrl"),
            "shift" => mods.push("Shift"),
            "alt" | "mod1" => mods.push("Alt"),
            "super" | "meta" | "mod4" => mods.push("Super"),
            _ => {}
        }
    }
    if rest.is_empty() {
        return None;
    }
    mods.push(rest);
    events::shortcut_text(&mods.join("+"))
}

fn shortcut(a: &Atspi, el: &El) -> Option<String> {
    a.actions_with_keys(el).into_iter().find_map(|(_, k)| accelerator(&k))
}

/// "save-as" → "Save as", "win" → "Win".
fn readable(name: &str) -> String {
    let spaced = name.replace(['-', '_'], " ");
    let mut c = spaced.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

/// A window's own actions as commands: (window, action index, [group, title], shortcut).
/// Left out: the default-widget action and names the toolkit could not make readable.
fn window_actions(a: &Atspi, app: &El) -> Vec<(El, i32, Vec<String>, Option<String>)> {
    let mut tops = a.children(app);
    tops.sort_by_key(|t| !has(a.states(t), state::ACTIVE));
    let mut out: Vec<(El, i32, Vec<String>, Option<String>)> = vec![];
    for w in tops.iter().filter(|t| has(a.states(t), state::SHOWING)) {
        for (i, (name, keys)) in a.actions_with_keys(w).into_iter().enumerate() {
            let Some((group, action)) = name.split_once('.') else { continue };
            if group.is_empty() || action.is_empty() || action.contains('%') || group.eq_ignore_ascii_case("default") {
                continue;
            }
            let path = vec![readable(group), readable(action)];
            if !out.iter().any(|(_, _, p, _)| *p == path) {
                out.push((w.clone(), i as i32, path, accelerator(&keys)));
            }
        }
    }
    out
}

pub fn read(a: &Atspi, app: &El, deadline: Instant) -> MenuRead {
    let mut out = MenuRead::default();
    let Some(bar) = menu_bar(a, app) else {
        for (_, _, path, shortcut) in window_actions(a, app).into_iter().take(MAX_ITEMS) {
            out.commands.push(Command { shortcut, enabled: None, path });
        }
        return out;
    };
    fn walk(a: &Atspi, menu: &El, path: &[String], depth: usize, deadline: Instant, out: &mut MenuRead) {
        if depth > MAX_DEPTH {
            return;
        }
        for item in a.children(menu) {
            if out.commands.len() >= MAX_ITEMS || Instant::now() > deadline {
                out.truncated = true;
                return;
            }
            let Some(role) = a.role_name(&item) else { continue };
            if !is_item(&role) {
                continue;
            }
            let Some(t) = title(a, &item) else { continue };
            if events::looks_app_filled(&t) {
                continue;
            }
            let mut p = path.to_vec();
            p.push(t);
            if role == "menu" {
                walk(a, &item, &p, depth + 1, deadline, out);
            } else {
                out.commands.push(Command { shortcut: shortcut(a, &item), enabled: Some(enabled(a, &item)), path: p });
            }
        }
    }
    walk(a, &bar, &[], 1, deadline, &mut out);
    out
}

/// App build (executable time stamp) plus each top menu's title and item count.
pub fn signature(a: &Atspi, app: &El, exe: &str) -> String {
    let mut parts = vec![std::fs::metadata(exe).and_then(|m| m.modified()).map(|t| format!("{t:?}")).unwrap_or_default()];
    if let Some(bar) = menu_bar(a, app) {
        for m in a.children(&bar) {
            parts.push(format!("{}#{}", title(a, &m).unwrap_or_default(), a.children(&m).len()));
        }
    } else {
        // (v2: readable titles)
        parts.push(format!("actions2#{}", window_actions(a, app).len()));
    }
    parts.join("|")
}

/// The live command at `path`: (element, what was found, the action to run on it — None
/// for a menu item, which is clicked).
pub fn locate(a: &Atspi, app: &El, path: &[String]) -> Option<(El, Located, Option<i32>)> {
    if let Some(found) = locate_in_bar(a, app, path) {
        return Some((found.0, found.1, None));
    }
    let (w, i, actual, _) = window_actions(a, app)
        .into_iter()
        .find(|(_, _, p, _)| p.len() == path.len() && p.iter().zip(path).all(|(x, y)| events::same_title(x, y)))?;
    Some((w, Located { path: actual, enabled: true, has_submenu: false }, Some(i)))
}

fn locate_in_bar(a: &Atspi, app: &El, path: &[String]) -> Option<(El, Located)> {
    let bar = menu_bar(a, app)?;
    let mut owner = bar;
    let mut actual = vec![];
    for wanted in path {
        let next = a.children(&owner).into_iter().find(|c| {
            a.role_name(c).is_some_and(|r| is_item(&r)) && title(a, c).is_some_and(|t| events::same_title(&t, wanted))
        })?;
        actual.push(title(a, &next).unwrap_or_else(|| wanted.clone()));
        owner = next;
    }
    let has_submenu = a.role_name(&owner).as_deref() == Some("menu");
    let en = enabled(a, &owner);
    Some((owner, Located { path: actual, enabled: en, has_submenu }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn accelerators() {
        assert_eq!(super::accelerator("s;<Alt>f:s;<Primary>s").as_deref(), Some("ctrl+s"));
        assert_eq!(super::accelerator("n;;<Control><Shift>n").as_deref(), Some("ctrl+shift+n"));
        assert_eq!(super::accelerator("q;<Alt>f:q;").as_deref(), None);
        assert_eq!(super::accelerator("").as_deref(), None);
        assert_eq!(super::accelerator(";;F5").as_deref(), Some("F5"));
    }
}
