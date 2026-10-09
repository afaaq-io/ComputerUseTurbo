//! Per-session state: element numbers, change baselines, session
//! approvals, screenshots, the Stop flag.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Instant;

use crate::image_util::Geometry;
use crate::platform::WindowInfo;
use crate::tree::Indexer;

pub struct AppState<E> {
    pub pid: u32,
    pub indexer: Indexer,
    pub elements: HashMap<usize, E>,
    pub secure: HashSet<usize>,
    pub baseline: Option<HashMap<usize, String>>,
    pub observed: bool,
    pub window: Option<WindowInfo>,
    pub geometry: Option<Geometry>,
    pub last_thumb: Option<Vec<u8>>,
    pub menu_bar: HashSet<usize>,
    pub last_action_end: Option<Instant>,
    pub last_observed_at: Option<Instant>,
    pub background_noted: bool,
    /// The app's windows at the latest observation (`waitFor newWindow` counts what opened
    /// since then).
    pub windows_at_observation: Option<Vec<u64>>,
}

impl<E> AppState<E> {
    pub fn new(pid: u32) -> Self {
        Self {
            pid,
            indexer: Indexer::default(),
            elements: HashMap::new(),
            secure: HashSet::new(),
            baseline: None,
            observed: false,
            window: None,
            geometry: None,
            last_thumb: None,
            menu_bar: HashSet::new(),
            last_action_end: None,
            last_observed_at: None,
            background_noted: false,
            windows_at_observation: None,
        }
    }

    /// The app relaunched: element references are dead; numbers continue.
    pub fn relaunched(&mut self, pid: u32) {
        self.pid = pid;
        self.elements.clear();
        self.secure.clear();
        self.window = None;
        self.geometry = None;
        self.last_thumb = None;
    }
}

pub struct Session<E> {
    pub apps: HashMap<String, AppState<E>>,
    pub approved: HashSet<String>,
    pub stopped: bool,
    pub screenshots: Vec<PathBuf>,
    pub last_touch: Instant,
    pub last_gated: Option<Instant>,
}

impl<E> Session<E> {
    pub fn new() -> Self {
        Self {
            apps: HashMap::new(),
            approved: HashSet::new(),
            stopped: false,
            screenshots: vec![],
            last_touch: Instant::now(),
            last_gated: None,
        }
    }
}

impl<E> Default for Session<E> {
    fn default() -> Self {
        Self::new()
    }
}
