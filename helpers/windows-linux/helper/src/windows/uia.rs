//! UI Automation: reading a window's control tree (one cached subtree request) and the
//! element operations the steps use (patterns, values, text ranges).

use std::time::Instant;

use turbo_core::tree::Node;
use windows::core::{Interface, BSTR, VARIANT};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::Ole::{SafeArrayDestroy, SafeArrayGetElement, SafeArrayGetLBound, SafeArrayGetUBound};
use windows::Win32::UI::Accessibility::*;

/// A UI Automation element. UIA client objects are free-threaded (used from MTA threads).
#[derive(Clone)]
pub struct El(pub IUIAutomationElement);
unsafe impl Send for El {}
unsafe impl Sync for El {}

pub struct Uia {
    pub a: IUIAutomation,
}
unsafe impl Send for Uia {}
unsafe impl Sync for Uia {}

pub fn com_init() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
}

fn s(b: windows::core::Result<BSTR>) -> Option<String> {
    b.ok().map(|b| b.to_string()).filter(|s| !s.trim().is_empty())
}

pub fn runtime_id(el: &IUIAutomationElement) -> Option<String> {
    unsafe {
        let sa = el.GetRuntimeId().ok()?;
        if sa.is_null() {
            return None;
        }
        let lb = SafeArrayGetLBound(sa, 1).ok()?;
        let ub = SafeArrayGetUBound(sa, 1).ok()?;
        let mut parts = vec![];
        for i in lb..=ub {
            let mut v: i32 = 0;
            if SafeArrayGetElement(sa, &i, &mut v as *mut i32 as *mut _).is_ok() {
                parts.push(v.to_string());
            }
        }
        let _ = SafeArrayDestroy(sa);
        Some(parts.join("."))
    }
}

fn cached_bool(el: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> bool {
    unsafe { el.GetCachedPropertyValue(id).ok().and_then(|v| bool::try_from(&v).ok()).unwrap_or(false) }
}

fn cached_i32(el: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<i32> {
    unsafe { el.GetCachedPropertyValue(id).ok().and_then(|v| i32::try_from(&v).ok()) }
}

fn cached_str(el: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<String> {
    unsafe { el.GetCachedPropertyValue(id).ok().and_then(|v: VARIANT| BSTR::try_from(&v).ok()).map(|b| b.to_string()).filter(|s| !s.is_empty()) }
}

fn cached_f64(el: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<f64> {
    unsafe { el.GetCachedPropertyValue(id).ok().and_then(|v| f64::try_from(&v).ok()) }
}

fn has_page_content(children: &[Node]) -> bool {
    children.iter().any(|c| matches!(c.role.as_str(), "link" | "button" | "image") || has_page_content(&c.children))
}

/// UIA control type → our words.
pub fn role_of(ct: i32, text_pattern: bool, read_only: bool) -> (&'static str, Option<&'static str>) {
    match ct {
        50000 => ("button", None),
        50001 => ("calendar", None),
        50002 => ("check box", None),
        50003 => ("combo box", None),
        50004 => ("text field", None),
        50005 => ("link", None),
        50006 => ("image", None),
        50007 => ("list item", None),
        50008 => ("list", None),
        50009 => ("menu", None),
        50010 => ("menu bar", None),
        50011 => ("menu item", None),
        50012 => ("progress bar", None),
        50013 => ("radio button", None),
        50014 => ("scroll bar", None),
        50015 => ("slider", None),
        50016 => ("stepper", None),
        50017 => ("status bar", None),
        50018 => ("tab group", None),
        50019 => ("tab", None),
        50020 => ("text", None),
        50021 => ("toolbar", None),
        50022 => ("tool tip", None),
        50023 => ("outline", None),
        50024 => ("row", Some("tree item")),
        50025 => ("group", Some("custom")),
        50026 => ("group", None),
        50027 => ("group", Some("thumb")),
        50028 => ("table", None),
        50029 => ("row", None),
        50030 => {
            // A web page is recognised by its content once read (`node`), never by the
            // window class of a particular engine.
            if text_pattern && !read_only {
                ("text area", None)
            } else {
                ("text area", Some("document"))
            }
        }
        50031 => ("button", Some("split button")),
        50032 => ("window", None),
        50033 => ("group", None),
        50034 => ("group", Some("header")),
        50035 => ("column header", None),
        50036 => ("table", None),
        50037 => ("group", Some("title bar")),
        50038 => ("group", Some("separator")),
        50040 => ("toolbar", Some("app bar")),
        _ => ("group", None),
    }
}

pub struct Read {
    pub elements: Vec<El>,
    pub focused: Option<usize>,
    pub count: usize,
    pub cut: bool,
    pub has_web: bool,
    pub deadline: Instant,
    pub focused_id: Option<String>,
}

const MAX_NODES: usize = 2500;

impl Uia {
    pub fn new() -> windows::core::Result<Self> {
        com_init();
        let a: IUIAutomation = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)? };
        Ok(Self { a })
    }

    fn cache_request(&self) -> windows::core::Result<IUIAutomationCacheRequest> {
        unsafe {
            let c = self.a.CreateCacheRequest()?;
            for p in [
                UIA_NamePropertyId,
                UIA_ControlTypePropertyId,
                UIA_AutomationIdPropertyId,
                UIA_ClassNamePropertyId,
                UIA_IsEnabledPropertyId,
                UIA_HasKeyboardFocusPropertyId,
                UIA_IsPasswordPropertyId,
                UIA_BoundingRectanglePropertyId,
                UIA_IsOffscreenPropertyId,
                UIA_HelpTextPropertyId,
                UIA_ValueValuePropertyId,
                UIA_ValueIsReadOnlyPropertyId,
                UIA_ToggleToggleStatePropertyId,
                UIA_ExpandCollapseExpandCollapseStatePropertyId,
                UIA_SelectionItemIsSelectedPropertyId,
                UIA_RangeValueValuePropertyId,
                UIA_IsInvokePatternAvailablePropertyId,
                UIA_IsTogglePatternAvailablePropertyId,
                UIA_IsExpandCollapsePatternAvailablePropertyId,
                UIA_IsValuePatternAvailablePropertyId,
                UIA_IsRangeValuePatternAvailablePropertyId,
                UIA_IsScrollPatternAvailablePropertyId,
                UIA_IsSelectionItemPatternAvailablePropertyId,
                UIA_IsTextPatternAvailablePropertyId,
                UIA_IsWindowPatternAvailablePropertyId,
            ] {
                c.AddProperty(p)?;
            }
            c.SetTreeScope(TreeScope_Subtree)?;
            c.SetTreeFilter(&self.a.ControlViewCondition()?)?;
            Ok(c)
        }
    }

    pub fn from_window(&self, hwnd: HWND) -> Option<El> {
        unsafe { self.a.ElementFromHandle(hwnd).ok().map(El) }
    }

    /// Read a window's tree (one cross-process round trip for the whole subtree).
    pub fn read_window(&self, hwnd: HWND, r: &mut Read) -> Option<Node> {
        unsafe {
            let el = self.a.ElementFromHandle(hwnd).ok()?;
            let cached = el.BuildUpdatedCache(&self.cache_request().ok()?).ok()?;
            self.node(&cached, 0, r)
        }
    }

    fn node(&self, el: &IUIAutomationElement, depth: usize, r: &mut Read) -> Option<Node> {
        if r.count >= MAX_NODES || Instant::now() > r.deadline {
            r.cut = true;
            return None;
        }
        r.count += 1;
        unsafe {
            let offscreen = cached_bool(el, UIA_IsOffscreenPropertyId);
            if depth > 0 && offscreen {
                return None;
            }
            let ct = el.CachedControlType().map(|c| c.0).unwrap_or(0);
            let text_p = cached_bool(el, UIA_IsTextPatternAvailablePropertyId);
            let value_p = cached_bool(el, UIA_IsValuePatternAvailablePropertyId);
            let read_only = cached_bool(el, UIA_ValueIsReadOnlyPropertyId);
            let (role, sub) = role_of(ct, text_p, read_only);
            let mut n = Node { role: role.into(), subrole: sub.map(str::to_string), ..Default::default() };
            n.is_window = role == "window";
            n.is_web_area = role == "web area";
            if n.is_web_area {
                r.has_web = true;
            }
            n.title = s(el.CachedName());
            n.description = s(el.CachedHelpText());
            n.identifier = s(el.CachedAutomationId()).filter(|id| id.len() < 80 && !id.chars().all(|c| c.is_ascii_digit()));
            n.secure = el.CachedIsPassword().map(|b| b.as_bool()).unwrap_or(false);
            if n.secure {
                n.subrole = Some("secure text field".into());
            }
            n.focused = el.CachedHasKeyboardFocus().map(|b| b.as_bool()).unwrap_or(false);
            n.disabled = !el.CachedIsEnabled().map(|b| b.as_bool()).unwrap_or(true);
            n.editable = value_p && !read_only && matches!(role, "text field" | "text area" | "combo box");
            n.selected = cached_bool(el, UIA_SelectionItemIsSelectedPropertyId);
            n.checked = cached_i32(el, UIA_ToggleToggleStatePropertyId) == Some(1);
            let expand = cached_i32(el, UIA_ExpandCollapseExpandCollapseStatePropertyId);
            n.expanded = expand == Some(1);
            if !n.secure {
                if value_p {
                    n.value = cached_str(el, UIA_ValueValuePropertyId);
                } else if cached_bool(el, UIA_IsRangeValuePatternAvailablePropertyId) {
                    n.value = cached_f64(el, UIA_RangeValueValuePropertyId).map(|v| if v.fract() == 0.0 { format!("{}", v as i64) } else { format!("{v}") });
                }
                if role == "text" && n.value.is_none() {
                    n.value = n.title.take();
                }
            }
            if cached_bool(el, UIA_IsTogglePatternAvailablePropertyId) && role != "check box" {
                n.actions.push("Toggle".into());
            }
            if cached_bool(el, UIA_IsExpandCollapsePatternAvailablePropertyId) && expand != Some(3) {
                n.actions.push(if n.expanded { "Collapse".into() } else { "Expand".into() });
            }
            if cached_bool(el, UIA_IsScrollPatternAvailablePropertyId) {
                n.actions.push("Scroll Up".into());
                n.actions.push("Scroll Down".into());
            }
            if cached_bool(el, UIA_IsRangeValuePatternAvailablePropertyId) {
                n.actions.push("Increment".into());
                n.actions.push("Decrement".into());
            }
            if cached_bool(el, UIA_IsSelectionItemPatternAvailablePropertyId) && !n.selected && role != "radio button" {
                n.actions.push("Select".into());
            }
            if let Ok(rect) = el.CachedBoundingRectangle() {
                n.frame = Some((rect.left as f64, rect.top as f64, (rect.right - rect.left) as f64, (rect.bottom - rect.top) as f64));
            }
            let id = runtime_id(el);
            if n.focused && id.is_some() {
                r.focused_id = id.clone();
            }
            n.identity = id;
            let idx = r.elements.len();
            r.elements.push(El(el.clone()));
            n.element = Some(idx);
            if n.focused {
                r.focused = Some(idx);
            }
            if depth < 40 && !n.secure {
                if let Ok(kids) = el.GetCachedChildren() {
                    let len = kids.Length().unwrap_or(0);
                    let mut shown = 0;
                    for i in 0..len {
                        if let Ok(k) = kids.GetElement(i) {
                            if let Some(c) = self.node(&k, depth + 1, r) {
                                n.children.push(c);
                                shown += 1;
                            }
                        }
                    }
                    if len > 50 && shown < len {
                        n.rows_note = Some(format!("({shown} of {len} rows shown; {} more rows hidden; scroll to see them)", len - shown));
                    }
                }
            }
            // A read-only document holding links, buttons or images is a web page, whatever
            // engine renders it.
            if ct == 50030 && !n.editable && has_page_content(&n.children) {
                n.role = "web area".into();
                n.subrole = None;
                n.is_web_area = true;
                r.has_web = true;
            }
            Some(n)
        }
    }

    pub fn focused(&self) -> Option<El> {
        unsafe { self.a.GetFocusedElement().ok().map(El) }
    }
}

impl El {
    /// Key presses here become text: an edit / document / combo box, or anything with a
    /// writable value or a text pattern.
    pub fn accepts_text(&self) -> bool {
        unsafe {
            let ct = self.0.CurrentControlType().map(|c| c.0).unwrap_or(0);
            if matches!(ct, 50004 | 50030 | 50003) {
                return true;
            }
            self.0.GetCurrentPattern(UIA_TextPatternId).is_ok_and(|p| !p.as_raw().is_null())
        }
    }

    /// `edit "Name"` — role and label, for notes.
    pub fn describe(&self) -> String {
        unsafe {
            let ct = self.0.CurrentControlType().map(|c| c.0).unwrap_or(0);
            let (role, _) = role_of(ct, false, true);
            let name = self.0.CurrentName().ok().map(|b| b.to_string()).filter(|s| !s.trim().is_empty());
            turbo_core::events::describe(role, name.as_deref())
        }
    }

    pub fn pid(&self) -> Option<u32> {
        unsafe { self.0.CurrentProcessId().ok().map(|p| p as u32) }
    }
    pub fn alive(&self) -> bool {
        self.pid().is_some()
    }
    pub fn is_password(&self) -> bool {
        unsafe { self.0.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false) }
    }
    pub fn name(&self) -> Option<String> {
        unsafe { s(self.0.CurrentName()) }
    }
    pub fn class(&self) -> String {
        unsafe { s(self.0.CurrentClassName()).unwrap_or_default() }
    }
    pub fn hwnd(&self) -> Option<HWND> {
        unsafe { self.0.CurrentNativeWindowHandle().ok().filter(|h| !h.0.is_null()) }
    }
    pub fn center(&self) -> Option<(f64, f64)> {
        unsafe {
            let r = self.0.CurrentBoundingRectangle().ok()?;
            (r.right > r.left && r.bottom > r.top).then(|| ((r.left + r.right) as f64 / 2.0, (r.top + r.bottom) as f64 / 2.0))
        }
    }
    pub fn focus(&self) -> bool {
        unsafe { self.0.SetFocus().is_ok() }
    }

    pub fn pattern<T: Interface>(&self, id: UIA_PATTERN_ID) -> Option<T> {
        unsafe { self.0.GetCurrentPattern(id).ok().and_then(|u| u.cast::<T>().ok()) }
    }

    pub fn invoke(&self) -> bool {
        self.pattern::<IUIAutomationInvokePattern>(UIA_InvokePatternId).is_some_and(|p| unsafe { p.Invoke().is_ok() })
    }
    pub fn toggle(&self) -> bool {
        self.pattern::<IUIAutomationTogglePattern>(UIA_TogglePatternId).is_some_and(|p| unsafe { p.Toggle().is_ok() })
    }
    pub fn toggle_state(&self) -> Option<bool> {
        self.pattern::<IUIAutomationTogglePattern>(UIA_TogglePatternId).and_then(|p| unsafe { p.CurrentToggleState().ok() }).map(|s| s.0 == 1)
    }
    pub fn select(&self) -> bool {
        self.pattern::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId).is_some_and(|p| unsafe { p.Select().is_ok() })
    }
    pub fn expand(&self, open: bool) -> bool {
        self.pattern::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId)
            .is_some_and(|p| unsafe { if open { p.Expand().is_ok() } else { p.Collapse().is_ok() } })
    }
    pub fn expanded(&self) -> Option<bool> {
        self.pattern::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId)
            .and_then(|p| unsafe { p.CurrentExpandCollapseState().ok() })
            .map(|s| s.0 == 1)
    }
    pub fn value(&self) -> Option<String> {
        self.pattern::<IUIAutomationValuePattern>(UIA_ValuePatternId).and_then(|p| unsafe { p.CurrentValue().ok() }).map(|b| b.to_string())
    }
    pub fn set_value(&self, v: &str) -> bool {
        self.pattern::<IUIAutomationValuePattern>(UIA_ValuePatternId).is_some_and(|p| unsafe { p.SetValue(&BSTR::from(v)).is_ok() })
    }
    pub fn value_writable(&self) -> bool {
        self.pattern::<IUIAutomationValuePattern>(UIA_ValuePatternId).is_some_and(|p| unsafe { !p.CurrentIsReadOnly().map(|b| b.as_bool()).unwrap_or(true) })
    }
    pub fn set_range(&self, v: f64) -> bool {
        self.pattern::<IUIAutomationRangeValuePattern>(UIA_RangeValuePatternId).is_some_and(|p| unsafe { p.SetValue(v).is_ok() })
    }
    pub fn step_range(&self, up: bool) -> bool {
        self.pattern::<IUIAutomationRangeValuePattern>(UIA_RangeValuePatternId).is_some_and(|p| unsafe {
            let cur = p.CurrentValue().unwrap_or(0.0);
            let step = p.CurrentSmallChange().unwrap_or(1.0).max(f64::EPSILON);
            p.SetValue(if up { cur + step } else { cur - step }).is_ok()
        })
    }
    pub fn scroll(&self, vertical: bool, forward: bool, pages: u32) -> bool {
        let Some(p) = self.pattern::<IUIAutomationScrollPattern>(UIA_ScrollPatternId) else { return false };
        let amount = if forward { ScrollAmount_LargeIncrement } else { ScrollAmount_LargeDecrement };
        for _ in 0..pages.max(1) {
            let r = unsafe { if vertical { p.Scroll(ScrollAmount_NoAmount, amount) } else { p.Scroll(amount, ScrollAmount_NoAmount) } };
            if r.is_err() {
                return false;
            }
        }
        true
    }
    pub fn scroll_into_view(&self) {
        if let Some(p) = self.pattern::<IUIAutomationScrollItemPattern>(UIA_ScrollItemPatternId) {
            unsafe {
                let _ = p.ScrollIntoView();
            }
        }
    }
    pub fn text(&self) -> Option<String> {
        if let Some(p) = self.pattern::<IUIAutomationTextPattern>(UIA_TextPatternId) {
            if let Some(t) = unsafe { p.DocumentRange().ok().and_then(|r| r.GetText(-1).ok()) } {
                return Some(t.to_string());
            }
        }
        self.value().or_else(|| self.name())
    }
    /// Select UTF-16 range [start, start + len) (or put the caret at one end).
    pub fn select_text(&self, start: usize, len: usize, caret: Option<bool>) -> bool {
        let Some(p) = self.pattern::<IUIAutomationTextPattern>(UIA_TextPatternId) else { return false };
        unsafe {
            let Ok(doc) = p.DocumentRange() else { return false };
            let Ok(r) = doc.Clone() else { return false };
            let _ = r.MoveEndpointByRange(TextPatternRangeEndpoint_End, &doc, TextPatternRangeEndpoint_Start);
            let (s, e) = match caret {
                None => (start, start + len),
                Some(false) => (start, start),
                Some(true) => (start + len, start + len),
            };
            let _ = r.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, e as i32);
            let _ = r.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, s as i32);
            r.Select().is_ok()
        }
    }
    pub fn selected_text(&self) -> Option<String> {
        let p = self.pattern::<IUIAutomationTextPattern>(UIA_TextPatternId)?;
        unsafe {
            let arr = p.GetSelection().ok()?;
            if arr.Length().ok()? < 1 {
                return None;
            }
            Some(arr.GetElement(0).ok()?.GetText(4096).ok()?.to_string()).filter(|t| !t.is_empty())
        }
    }
}
