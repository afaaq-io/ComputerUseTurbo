//! The `act` steps, parsed from the wire.

use serde_json::{Map, Value};

use crate::errors::{ErrorCode, TurboError};

#[derive(Clone, Debug, PartialEq)]
pub enum Target {
    Element(usize),
    Point(f64, f64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
    Middle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caret {
    Select,
    Before,
    After,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PasteFormat {
    Text,
    Markdown,
    Html,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    Click { target: Target, button: Button, times: u8 },
    Scroll { target: Target, direction: Direction, pages: f64 },
    Drag { from: (f64, f64), to: (f64, f64) },
    WriteText { text: String, element: Option<usize> },
    SendKeys { key: String },
    FillValue { element: usize, value: String },
    PickText { element: usize, text: String, prefix: Option<String>, suffix: Option<String>, mode: Caret },
    InvokeAction { element: usize, name: String },
    PasteText { text: String, format: PasteFormat },
    /// A menu command by its path of titles.
    RunCommand { path: Vec<String> },
}

impl Step {
    pub fn type_name(&self) -> &'static str {
        match self {
            Step::Click { .. } => "clickAt",
            Step::Scroll { .. } => "scrollView",
            Step::Drag { .. } => "dragItem",
            Step::WriteText { .. } => "writeText",
            Step::SendKeys { .. } => "sendKeys",
            Step::FillValue { .. } => "fillValue",
            Step::PickText { .. } => "pickText",
            Step::InvokeAction { .. } => "invokeAction",
            Step::PasteText { .. } => "pasteText",
            Step::RunCommand { .. } => "runCommand",
        }
    }

    pub fn element(&self) -> Option<usize> {
        match self {
            Step::Click { target: Target::Element(i), .. } | Step::Scroll { target: Target::Element(i), .. } => Some(*i),
            Step::WriteText { element, .. } => *element,
            Step::FillValue { element, .. } | Step::PickText { element, .. } | Step::InvokeAction { element, .. } => Some(*element),
            _ => None,
        }
    }

    pub fn parse(v: Option<&Value>) -> Result<Step, TurboError> {
        let o = v.and_then(Value::as_object).ok_or_else(|| TurboError::bad("payload.step must be an object with a \"type\" field"))?;
        let ty = o.get("type").and_then(Value::as_str).ok_or_else(|| TurboError::bad("payload.step.type must be a string"))?;
        Ok(match ty {
            "clickAt" => {
                let button = match o.get("button").and_then(Value::as_str).unwrap_or("left") {
                    "left" => Button::Left,
                    "right" => Button::Right,
                    "middle" => Button::Middle,
                    b => return Err(TurboError::bad(format!("button must be left, right or middle, not \"{b}\""))),
                };
                let times = opt_int(o, "clickTimes")?.unwrap_or(1);
                if !(1..=3).contains(&times) {
                    return Err(TurboError::bad("clickTimes must be 1, 2 or 3"));
                }
                Step::Click { target: target(o)?, button, times: times as u8 }
            }
            "scrollView" => {
                let direction = match o.get("direction").and_then(Value::as_str) {
                    Some("up") => Direction::Up,
                    Some("down") => Direction::Down,
                    Some("left") => Direction::Left,
                    Some("right") => Direction::Right,
                    _ => return Err(TurboError::bad("scrollView requires direction (up/down/left/right)")),
                };
                let pages = o.get("pages").and_then(Value::as_f64).unwrap_or(1.0);
                if !(0.1..=20.0).contains(&pages) {
                    return Err(TurboError::bad("pages must be between 0.1 and 20"));
                }
                Step::Scroll { target: target(o)?, direction, pages }
            }
            "dragItem" => Step::Drag {
                from: (coord(o, "startX")?, coord(o, "startY")?),
                to: (coord(o, "endX")?, coord(o, "endY")?),
            },
            "writeText" => Step::WriteText {
                text: o.get("text").and_then(Value::as_str).filter(|t| !t.is_empty()).ok_or_else(|| TurboError::bad("writeText requires a non-empty text"))?.to_string(),
                element: opt_index(o)?,
            },
            "sendKeys" => Step::SendKeys {
                key: o.get("key").and_then(Value::as_str).filter(|k| !k.trim().is_empty()).ok_or_else(|| TurboError::bad("sendKeys requires a key"))?.to_string(),
            },
            "fillValue" => Step::FillValue {
                element: req_index(o)?,
                value: match o.get("value") {
                    Some(Value::String(s)) => s.clone(),
                    Some(Value::Number(n)) => n.to_string(),
                    Some(Value::Bool(b)) => b.to_string(),
                    _ => return Err(TurboError::bad("fillValue requires a value")),
                },
            },
            "pickText" => Step::PickText {
                element: req_index(o)?,
                text: o.get("text").and_then(Value::as_str).filter(|t| !t.is_empty()).ok_or_else(|| TurboError::bad("pickText requires a non-empty text"))?.to_string(),
                prefix: o.get("prefix").and_then(Value::as_str).map(str::to_string),
                suffix: o.get("suffix").and_then(Value::as_str).map(str::to_string),
                mode: match o.get("selection").and_then(Value::as_str).unwrap_or("text") {
                    "text" => Caret::Select,
                    "cursor_before" => Caret::Before,
                    "cursor_after" => Caret::After,
                    m => return Err(TurboError::bad(format!("selection must be text, cursor_before or cursor_after, not \"{m}\""))),
                },
            },
            "invokeAction" => Step::InvokeAction {
                element: req_index(o)?,
                name: o.get("name").and_then(Value::as_str).filter(|n| !n.trim().is_empty()).ok_or_else(|| TurboError::bad("invokeAction requires an action name"))?.to_string(),
            },
            "pasteText" => Step::PasteText {
                text: o.get("text").and_then(Value::as_str).filter(|t| !t.is_empty()).ok_or_else(|| TurboError::bad("pasteText requires a non-empty text"))?.to_string(),
                format: match o.get("format").and_then(Value::as_str).unwrap_or("text") {
                    "text" | "plain" | "txt" => PasteFormat::Text,
                    "markdown" | "md" => PasteFormat::Markdown,
                    "html" => PasteFormat::Html,
                    f => return Err(TurboError::bad(format!("format must be text, markdown or html, not \"{f}\""))),
                },
            },
            "runCommand" => Step::RunCommand { path: crate::events::parse_path(o.get("path"))? },
            other => {
                return Err(TurboError::new(
                    ErrorCode::NotSupported,
                    format!("Unsupported step type \"{}\". Supported: clickAt, scrollView, dragItem, writeText, sendKeys, fillValue, pickText, invokeAction, pasteText, runCommand.", crate::protocol::clean(other, 40)),
                ))
            }
        })
    }
}

fn opt_int(o: &Map<String, Value>, k: &str) -> Result<Option<i64>, TurboError> {
    match o.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v.as_i64().or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64)).map(Some).ok_or_else(|| TurboError::bad(format!("{k} must be an integer"))),
    }
}

fn opt_index(o: &Map<String, Value>) -> Result<Option<usize>, TurboError> {
    let v = match o.get("elementNumber") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(s)) => s.trim().parse::<i64>().map_err(|_| TurboError::bad("elementNumber must be an integer"))?,
        Some(v) => v.as_i64().ok_or_else(|| TurboError::bad("elementNumber must be an integer"))?,
    };
    if v < 0 {
        return Err(TurboError::bad("elementNumber must be ≥ 0"));
    }
    Ok(Some(v as usize))
}

fn req_index(o: &Map<String, Value>) -> Result<usize, TurboError> {
    opt_index(o)?.ok_or_else(|| TurboError::bad("elementNumber is required"))
}

fn coord(o: &Map<String, Value>, k: &str) -> Result<f64, TurboError> {
    let v = o.get(k).and_then(Value::as_f64).filter(|f| f.is_finite()).ok_or_else(|| TurboError::bad(format!("{k} must be a number")))?;
    if v < -0.5 {
        return Err(TurboError::bad(format!("{k} must not be negative")));
    }
    Ok(v)
}

fn target(o: &Map<String, Value>) -> Result<Target, TurboError> {
    let idx = opt_index(o)?;
    let (hx, hy) = (o.get("x").is_some_and(|v| !v.is_null()), o.get("y").is_some_and(|v| !v.is_null()));
    match (idx, hx, hy) {
        (Some(_), true, _) | (Some(_), _, true) => Err(TurboError::bad("Give exactly one target: elementNumber OR x and y, not both.")),
        (Some(i), false, false) => Ok(Target::Element(i)),
        (None, true, true) => Ok(Target::Point(coord(o, "x")?, coord(o, "y")?)),
        (None, true, false) | (None, false, true) => Err(TurboError::bad("x and y must be given together (screenshot pixel coordinates).")),
        (None, false, false) => Err(TurboError::bad("Give exactly one target: elementNumber or both x and y.")),
    }
}

/// Plain text of a paste payload (markdown source, or HTML with tags dropped).
pub fn paste_plain(text: &str, format: PasteFormat) -> String {
    match format {
        PasteFormat::Html => {
            let mut out = String::new();
            let mut in_tag = false;
            for ch in text.chars() {
                match ch {
                    '<' => in_tag = true,
                    '>' => in_tag = false,
                    c if !in_tag => out.push(c),
                    _ => {}
                }
            }
            out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&nbsp;", " ")
        }
        _ => text.to_string(),
    }
}

/// UTF-16 range of `text` in `haystack`, disambiguated by prefix / suffix (pickText).
pub fn find_text(haystack: &str, text: &str, prefix: Option<&str>, suffix: Option<&str>) -> Option<(usize, usize)> {
    let mut from = 0;
    while let Some(pos) = haystack[from..].find(text) {
        let start = from + pos;
        let end = start + text.len();
        let ok_prefix = prefix.map_or(true, |p| haystack[..start].ends_with(p));
        let ok_suffix = suffix.map_or(true, |s| haystack[end..].starts_with(s));
        if ok_prefix && ok_suffix {
            let u16_start = haystack[..start].encode_utf16().count();
            let u16_len = text.encode_utf16().count();
            return Some((u16_start, u16_len));
        }
        from = start + text.chars().next().map_or(1, char::len_utf8);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parsing() {
        assert_eq!(
            Step::parse(Some(&json!({"type": "clickAt", "elementNumber": 4}))).unwrap(),
            Step::Click { target: Target::Element(4), button: Button::Left, times: 1 }
        );
        assert!(Step::parse(Some(&json!({"type": "clickAt", "x": 1}))).is_err());
        assert!(Step::parse(Some(&json!({"type": "nope"}))).is_err());
        assert_eq!(find_text("a b a c", "a", Some("b "), None), Some((4, 1)));
    }
}
