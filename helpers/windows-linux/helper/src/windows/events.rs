//! UI Automation events of the apps being worked on: windows that
//! open, focus moves, value / name changes, notifications. Handlers run on UI Automation's
//! own threads and keep what happened in watched apps in the core's `EventLog`.

use std::collections::HashSet;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

use turbo_core::events::{describe, EventKind, EventLog, UiEvent};
use windows::core::{implement, Interface, BSTR, VARIANT};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER, SAFEARRAY};
use windows::Win32::UI::Accessibility::*;

use super::sys;
use super::uia::{com_init, role_of};

struct Sink {
    log: Arc<EventLog>,
    watched: Mutex<HashSet<u32>>,
}

impl Sink {
    /// The sender's process if it is watched.
    fn pid(&self, sender: Option<&IUIAutomationElement>) -> Option<(u32, IUIAutomationElement)> {
        let el = sender?.clone();
        let pid = unsafe { el.CurrentProcessId() }.ok()? as u32;
        self.watched.lock().unwrap().contains(&pid).then_some((pid, el))
    }
}

fn what(el: &IUIAutomationElement) -> (String, Option<String>, bool) {
    unsafe {
        let ct = el.CurrentControlType().map(|c| c.0).unwrap_or(0);
        let (role, sub) = role_of(ct, false, true);
        let role = if sub == Some("dialog") { "dialog" } else { role };
        let name = el.CurrentName().ok().map(|b| b.to_string()).filter(|s| !s.trim().is_empty());
        let secure = el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false);
        (role.to_string(), name, secure)
    }
}

fn key(el: &IUIAutomationElement) -> String {
    super::uia::runtime_id(el).unwrap_or_default()
}

#[implement(IUIAutomationEventHandler)]
struct Opened(Arc<Sink>);

impl IUIAutomationEventHandler_Impl for Opened_Impl {
    fn HandleAutomationEvent(&self, sender: Option<&IUIAutomationElement>, _id: UIA_EVENT_ID) -> windows::core::Result<()> {
        if let Some((pid, el)) = self.0.pid(sender) {
            if let Ok(r) = unsafe { el.CurrentBoundingRectangle() } {
                if turbo_core::events::incidental_window((r.right - r.left) as f64, (r.bottom - r.top) as f64) {
                    return Ok(());
                }
            }
            let (role, name, _) = what(&el);
            let modal = unsafe { el.CurrentControlType() }.map(|c| c.0).unwrap_or(0) == 50032
                && unsafe { el.GetCurrentPropertyValue(UIA_WindowIsModalPropertyId) }.ok().and_then(|v| bool::try_from(&v).ok()).unwrap_or(false);
            let kind = if modal || role == "dialog" { EventKind::DialogOpened } else { EventKind::WindowOpened };
            self.0.log.push(pid, Some(UiEvent::new(kind).what(name.map(|n| format!("\"{n}\"")).unwrap_or_default()).key(key(&el))));
        }
        Ok(())
    }
}

#[implement(IUIAutomationFocusChangedEventHandler)]
struct Focus(Arc<Sink>);

impl IUIAutomationFocusChangedEventHandler_Impl for Focus_Impl {
    fn HandleFocusChangedEvent(&self, sender: Option<&IUIAutomationElement>) -> windows::core::Result<()> {
        if let Some((pid, el)) = self.0.pid(sender) {
            let (role, name, _) = what(&el);
            self.0.log.push(pid, Some(UiEvent::new(EventKind::FocusMoved).what(describe(&role, name.as_deref())).key(key(&el))));
        }
        Ok(())
    }
}

#[implement(IUIAutomationPropertyChangedEventHandler)]
struct Changed(Arc<Sink>);

impl IUIAutomationPropertyChangedEventHandler_Impl for Changed_Impl {
    fn HandlePropertyChangedEvent(&self, sender: Option<&IUIAutomationElement>, property: UIA_PROPERTY_ID, value: &VARIANT) -> windows::core::Result<()> {
        if let Some((pid, el)) = self.0.pid(sender) {
            let (role, name, secure) = what(&el);
            let event = if property == UIA_NamePropertyId {
                matches!(role.as_str(), "window" | "dialog" | "text" | "status bar")
                    .then(|| UiEvent::new(EventKind::TitleChanged).what(role.clone()).detail(name.clone()))
            } else if secure {
                None
            } else {
                let text = BSTR::try_from(value).ok().map(|b| b.to_string()).or_else(|| f64::try_from(value).ok().map(|v| v.to_string()));
                Some(UiEvent::new(EventKind::ValueChanged).what(describe(&role, name.as_deref())).detail(text))
            };
            self.0.log.push(pid, event.map(|e| e.key(key(&el))));
        }
        Ok(())
    }
}

#[implement(IUIAutomationStructureChangedEventHandler)]
struct Structure(Arc<Sink>);

impl IUIAutomationStructureChangedEventHandler_Impl for Structure_Impl {
    fn HandleStructureChangedEvent(&self, sender: Option<&IUIAutomationElement>, _t: StructureChangeType, _r: *const SAFEARRAY) -> windows::core::Result<()> {
        if let Some((pid, _)) = self.0.pid(sender) {
            self.0.log.push(pid, None);
        }
        Ok(())
    }
}

#[implement(IUIAutomationNotificationEventHandler)]
struct Notified(Arc<Sink>);

impl IUIAutomationNotificationEventHandler_Impl for Notified_Impl {
    fn HandleNotificationEvent(
        &self,
        sender: Option<&IUIAutomationElement>,
        _k: NotificationKind,
        _p: NotificationProcessing,
        text: &BSTR,
        _a: &BSTR,
    ) -> windows::core::Result<()> {
        if let Some((pid, _)) = self.0.pid(sender) {
            let t = text.to_string();
            self.0.log.push(pid, (!t.trim().is_empty()).then(|| UiEvent::new(EventKind::Announcement).detail(Some(t))));
        }
        Ok(())
    }
}

pub struct Events {
    pub log: Arc<EventLog>,
    sink: Arc<Sink>,
    tx: Mutex<Option<Sender<u32>>>,
}

impl Events {
    pub fn new() -> Self {
        let log = Arc::new(EventLog::default());
        Self { sink: Arc::new(Sink { log: log.clone(), watched: Mutex::new(HashSet::new()) }), log, tx: Mutex::new(None) }
    }

    /// Watch `pid`: global handlers start with the first app; each app's windows get
    /// change handlers when it is first watched.
    pub fn watch(&self, pid: u32) {
        if !self.sink.watched.lock().unwrap().insert(pid) {
            return;
        }
        let mut tx = self.tx.lock().unwrap();
        if tx.is_none() {
            let (send, recv) = channel::<u32>();
            let sink = self.sink.clone();
            let started = std::thread::Builder::new().name("turbo-uia-events".into()).spawn(move || {
                com_init();
                let Ok(a) = (unsafe { CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }) else {
                    turbo_core::log::error("UI Automation events unavailable");
                    return;
                };
                unsafe {
                    if let Ok(root) = a.GetRootElement() {
                        let h: IUIAutomationEventHandler = Opened(sink.clone()).into();
                        let _ = a.AddAutomationEventHandler(UIA_Window_WindowOpenedEventId, &root, TreeScope_Subtree, None, &h);
                    }
                    let f: IUIAutomationFocusChangedEventHandler = Focus(sink.clone()).into();
                    let _ = a.AddFocusChangedEventHandler(None, &f);
                }
                turbo_core::log::info("UI Automation events: listening");
                for pid in recv {
                    for h in sys::windows_of(pid) {
                        unsafe {
                            let Ok(win) = a.ElementFromHandle(h) else { continue };
                            let c: IUIAutomationPropertyChangedEventHandler = Changed(sink.clone()).into();
                            let _ = a.AddPropertyChangedEventHandlerNativeArray(
                                &win,
                                TreeScope_Subtree,
                                None,
                                &c,
                                &[UIA_ValueValuePropertyId, UIA_NamePropertyId, UIA_ToggleToggleStatePropertyId, UIA_RangeValueValuePropertyId],
                            );
                            let s: IUIAutomationStructureChangedEventHandler = Structure(sink.clone()).into();
                            let _ = a.AddStructureChangedEventHandler(&win, TreeScope_Subtree, None, &s);
                            if let Ok(a5) = a.cast::<IUIAutomation5>() {
                                let n: IUIAutomationNotificationEventHandler = Notified(sink.clone()).into();
                                let _ = a5.AddNotificationEventHandler(&win, TreeScope_Subtree, None, &n);
                            }
                        }
                    }
                }
            });
            if started.is_ok() {
                *tx = Some(send);
            }
        }
        if let Some(tx) = tx.as_ref() {
            let _ = tx.send(pid);
        }
    }
}
