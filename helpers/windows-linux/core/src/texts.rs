//! User-facing strings of the overlay, the password-manager card and action notes. `agent` is the
//! driving agent's display name (never a built-in name).

pub fn overlay_using(agent: &str, app: &str) -> String {
    format!("{agent} is working in {app}")
}
pub const OVERLAY_STOPPED: &str = "Stopped";

pub fn approval_title(agent: &str, app: &str) -> String {
    format!("Let {agent} control {app}?")
}
pub const APPROVAL_SUBTITLE: &str = "Requested for this task";
pub fn approval_intro(agent: &str) -> String {
    format!("{agent} will be able to:")
}
pub fn approval_bullets(app: &str) -> [String; 2] {
    [format!("See {app}'s window and what it shows"), "Click, type and scroll in it, without taking over your screen".into()]
}
pub fn approval_sensitive(agent: &str, app: &str) -> String {
    format!("{app} holds passwords or other credentials. {agent} could see secrets shown in it, and text inside it could try to steer {agent} (prompt injection). Continue only if you started this task and trust it.")
}
pub const APPROVAL_STOP_HINT: &str = "Stop anytime with the Stop button or Esc.";
pub const BUTTON_SESSION: &str = "For this task";
pub const BUTTON_ONCE: &str = "Just this once";
pub const BUTTON_DENY: &str = "Not now";

pub fn background_note(app: &str) -> String {
    format!("{app} is not in front; working in the background (the user can keep using their computer meanwhile).")
}

pub fn borrowed_note(app: &str, previous: Option<&str>) -> String {
    format!(
        "{app} was brought to the front for this action only (it cannot be done while the app is in the background; the user was idle){}.",
        previous.map(|p| format!(" and the front was handed back to {p}")).unwrap_or_default()
    )
}

pub fn borrow_busy(app: &str, what: &str) -> String {
    format!("{} needs {app} in front for a moment, but the user is typing or using the mouse right now. Nothing was sent. Retry in a few seconds.", capitalize(what))
}

pub fn borrow_off(app: &str, what: &str) -> String {
    format!("{} cannot be done while {app} is in the background, and bringing apps forward is turned off (focus.borrowFront). Nothing was sent.", capitalize(what))
}

pub fn real_pointer_note(app: &str) -> String {
    format!("The real mouse pointer was moved over {app} for this action and put back.")
}

pub fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// Typing stopped because another window took the front: the rest would have gone there.
pub fn lost_front(app: &str, n: usize) -> String {
    format!("Typing stopped after {n} character(s): {app} is no longer the front window (another window or the user took it), so nothing more was sent. Observe {app} and retry the rest.")
}

/// write_text sent key presses to something that does not take text (writeText).
pub fn keys_to_non_text(n: usize, what: &str, app: &str) -> String {
    format!("Sent {n} character(s) as key presses, but the keyboard focus was on {what}, which does not take text: they may have done nothing, or triggered keyboard shortcuts of {app}. Check with observe_app; to type into a field, click it first (or pass its element).")
}
