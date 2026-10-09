//! The password-manager card on Windows: the system's own dialog (TaskDialog), which needs
//! no graphics driver. Same question and choices as the drawn card elsewhere; "Not now" is
//! the default button.

use serde_json::Value;
use turbo_core::texts;
use windows::core::PCWSTR;
use windows::Win32::UI::Controls::{TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOG_BUTTON, TDF_ALLOW_DIALOG_CANCELLATION, TDF_USE_COMMAND_LINKS};

const ONCE: i32 = 101;
const SESSION: i32 = 102;
const DENY: i32 = 104;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Ask; the answer is what the drawn card prints ("once", "session", "deny").
/// None when the dialog could not be shown either.
pub fn approval(req: &Value) -> Option<&'static str> {
    let s = |k: &str| req.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let (agent, app) = (s("agent"), s("appName"));
    let [b1, b2] = texts::approval_bullets(&app);
    let mut content = format!("{}\n•  {b1}\n•  {b2}", texts::approval_intro(&agent));
    content.push_str(&format!("\n\n⚠  {}", texts::approval_sensitive(&agent, &app)));
    content.push_str(&format!("\n\n{}  ·  {}", texts::APPROVAL_STOP_HINT, s("appId")));

    let choices = [(SESSION, texts::BUTTON_SESSION), (ONCE, texts::BUTTON_ONCE), (DENY, texts::BUTTON_DENY)];
    let labels: Vec<Vec<u16>> = choices.iter().map(|(_, t)| wide(t)).collect();
    let buttons: Vec<TASKDIALOG_BUTTON> = choices.iter().zip(&labels).map(|((id, _), l)| TASKDIALOG_BUTTON { nButtonID: *id, pszButtonText: PCWSTR(l.as_ptr()) }).collect();
    let (window_title, instruction, body) = (wide(texts::APPROVAL_SUBTITLE), wide(&texts::approval_title(&agent, &app)), wide(&content));
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_USE_COMMAND_LINKS,
        pszWindowTitle: PCWSTR(window_title.as_ptr()),
        pszMainInstruction: PCWSTR(instruction.as_ptr()),
        pszContent: PCWSTR(body.as_ptr()),
        cButtons: buttons.len() as u32,
        pButtons: buttons.as_ptr(),
        nDefaultButton: DENY,
        ..Default::default()
    };
    let mut pressed = 0i32;
    unsafe { TaskDialogIndirect(&config, Some(&mut pressed), None, None) }.ok()?;
    Some(match pressed {
        ONCE => "once",
        SESSION => "session",
        _ => "deny",
    })
}
