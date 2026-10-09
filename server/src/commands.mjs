// App commands: every app's menu commands, kept on disk per
// app so that finding a command in an app the agent has used before is instant. The helper
// reads the menus; this module stores them, ranks them against a query and formats them.

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { supportDir } from './paths.mjs';

export const INDEX_VERSION = 1;
export const SEPARATOR = ' ▸ ';
/** At most this many commands are listed without a query. */
export const LIST_ALL_LIMIT = 150;

/** Where the saved command lists live. */
export function commandsDir(options) {
  return join(supportDir(options), 'commands');
}

/** File name for an app id ("com.apple.TextEdit", "notepad.exe", "/opt/x/app"). */
export function indexFileName(appId) {
  const safe = String(appId)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '_')
    .replace(/^[._]+/, '')
    .slice(0, 120);
  return `${safe || 'app'}.json`;
}

export async function loadIndex(dir, appId) {
  try {
    const data = JSON.parse(await readFile(join(dir, indexFileName(appId)), 'utf8'));
    if (data?.version !== INDEX_VERSION || !Array.isArray(data.commands) || typeof data.signature !== 'string') return null;
    return data;
  } catch {
    return null;
  }
}

export async function saveIndex(dir, appId, index) {
  await mkdir(dir, { recursive: true });
  const file = join(dir, indexFileName(appId));
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify(index), 'utf8');
  await rename(tmp, file);
}

/** Commands as stored: path + shortcut (whether one is available changes all the time). */
export function storedCommands(commands) {
  return (Array.isArray(commands) ? commands : [])
    .filter((c) => Array.isArray(c?.path) && c.path.length > 0 && c.path.every((t) => typeof t === 'string'))
    .map((c) => (typeof c.shortcut === 'string' && c.shortcut ? { path: c.path, shortcut: c.shortcut } : { path: c.path }));
}

// ---------------------------------------------------------------- matching

/** Lower case, no trailing "…", accelerator "&" and punctuation become spaces. */
export function normalize(s) {
  return String(s)
    .toLowerCase()
    .replace(/…|\.\.\./g, ' ')
    .replace(/&(?=\S)/g, '')
    .replace(/[^\p{L}\p{N}+]+/gu, ' ')
    .trim();
}

function words(s) {
  return normalize(s).split(' ').filter(Boolean);
}

/** "Saving" → "sav", "exports" → "export": a light stem so word forms still match. */
function stem(w) {
  if (w.length > 5 && w.endsWith('ing')) return w.slice(0, -3);
  if (w.length > 4 && w.endsWith('ed')) return w.slice(0, -2);
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.slice(0, -1);
  return w;
}

function wordMatches(queryWord, targetWords) {
  const q = stem(queryWord);
  return targetWords.some((t) => {
    const s = stem(t);
    return s === q || (q.length >= 2 && s.startsWith(q)) || (s.length >= 4 && q.startsWith(s));
  });
}

function isSubsequence(needle, hay) {
  let i = 0;
  for (const ch of hay) if (ch === needle[i]) i += 1;
  return i === needle.length;
}

/** A query that is a key chord ("cmd+shift+s") matches the command with that shortcut. */
export function normalizeChord(s) {
  const parts = String(s).toLowerCase().split('+').map((p) => p.trim()).filter(Boolean);
  if (parts.length < 2) return null;
  const alias = { command: 'cmd', super: 'cmd', meta: 'cmd', control: 'ctrl', option: 'alt', opt: 'alt' };
  const key = parts.pop();
  const mods = [...new Set(parts.map((p) => alias[p] ?? p))].sort();
  return [...mods, key].join('+');
}

/** Score of one command for a query (0 = no match). */
export function score(command, query) {
  const title = command.path.at(-1);
  const nq = normalize(query);
  if (!nq) return 0;
  const chord = normalizeChord(query);
  if (chord && command.shortcut && normalizeChord(command.shortcut) === chord) return 120;
  const nt = normalize(title);
  const qWords = nq.split(' ');
  const titleWords = nt.split(' ');
  const allWords = words(command.path.join(' '));
  let s = 0;
  if (nt === nq) s = 100;
  else if (nt.startsWith(nq)) s = 70;
  else if (qWords.every((w) => wordMatches(w, titleWords))) s = 55;
  else if (qWords.every((w) => wordMatches(w, allWords))) s = 40;
  else {
    const hits = qWords.filter((w) => wordMatches(w, allWords)).length;
    if (qWords.length > 1 && hits / qWords.length >= 0.5) s = 15 + 10 * (hits / qWords.length);
    else if (nq.length >= 3 && isSubsequence(nq.replace(/ /g, ''), nt.replace(/ /g, ''))) s = 8;
  }
  if (s === 0) return 0;
  // Prefer short titles and shallow paths among equals.
  return s - Math.min(nt.length, 60) / 60 - (command.path.length - 2) * 0.5;
}

/** Best matches, best first. */
export function rank(commands, query, limit = 15) {
  return commands
    .map((c, i) => ({ c, i, s: score(c, query) }))
    .filter((r) => r.s > 0)
    .sort((a, b) => b.s - a.s || a.i - b.i)
    .slice(0, limit)
    .map((r) => r.c);
}

// ---------------------------------------------------------------- formatting

export function displayPath(path) {
  return path.join(SEPARATOR);
}

/**
 * "File ▸ Export ▸ PDF…" or "File > Export > PDF..." or a JSON-ish array → titles.
 * @param {string | string[]} command
 */
export function parseCommandPath(command) {
  if (Array.isArray(command)) return command.map((t) => String(t).trim()).filter(Boolean);
  const text = String(command).trim();
  const parts = text.includes('▸') ? text.split('▸') : text.split(/\s+>\s+|\s*→\s*/);
  return parts.map((t) => t.trim()).filter(Boolean);
}

/** One line: "File ▸ Export As PDF…  [cmd+shift+e]  (unavailable now)". */
export function formatCommand(c) {
  let line = displayPath(c.path);
  if (c.shortcut) line += `  [${c.shortcut}]`;
  if (c.enabled === false) line += '  (unavailable now)';
  return line;
}

/** Top-level menus with their command counts. */
export function menuOverview(commands) {
  const counts = new Map();
  for (const c of commands) counts.set(c.path[0], (counts.get(c.path[0]) ?? 0) + 1);
  return [...counts].map(([menu, n]) => `${menu} (${n})`).join(', ');
}
