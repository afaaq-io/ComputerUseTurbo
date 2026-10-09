// Who is driving the helper (`session.agent`), found at runtime:
//
//   name   CUT_AGENT_NAME if set, else the MCP client's own self-description from the
//          initialize handshake (clientInfo.title, else clientInfo.name). Shown in the
//          helper's overlay and approval card ("<name> is working in Safari").
//   host   the desktop app this server runs inside, from the process ancestry. Its window
//          anchors the live preview, and the helper refuses to control it (an agent must
//          never act on its own host).
//
// No agent or host is known by name here.

import { execFileSync } from 'node:child_process';
import { readFileSync, readlinkSync } from 'node:fs';

import { platformId } from './paths.mjs';

const MAX_DEPTH = 32;

/**
 * @typedef {object} AgentInfo
 * @property {string} [name]
 * @property {number} [hostPid]
 * @property {string} [hostAppPath]
 * @property {number[]} [ancestorPids] nearest first (for helpers that pick the host themselves)
 */

/**
 * Display name for the agent.
 * @param {{name?: string, title?: string} | undefined} clientInfo
 * @param {NodeJS.ProcessEnv} [env]
 */
export function agentName(clientInfo, env = process.env) {
  const fromEnv = env.CUT_AGENT_NAME?.trim();
  if (fromEnv) return fromEnv;
  const title = typeof clientInfo?.title === 'string' ? clientInfo.title.trim() : '';
  if (title) return title;
  const name = typeof clientInfo?.name === 'string' ? clientInfo.name.trim() : '';
  return name || undefined;
}

/**
 * The outermost `.app` bundle in an executable path (macOS), or null.
 * "/Applications/X.app/Contents/Frameworks/X Helper.app/Contents/MacOS/X Helper" → "/Applications/X.app".
 * @param {string} path
 */
export function outermostAppBundle(path) {
  const m = /^(.*?\.app)(?:\/|$)/.exec(path);
  return m ? m[1] : null;
}

/**
 * Parent pid + executable path of one process, or null.
 * @param {number} pid
 * @param {string} os
 * @returns {{ppid: number, exe: string} | null}
 */
function processInfo(pid, os) {
  try {
    if (os === 'linux') {
      const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
      const ppid = Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]);
      let exe = '';
      try {
        exe = readlinkSync(`/proc/${pid}/exe`);
      } catch {
        exe = '';
      }
      return Number.isInteger(ppid) ? { ppid, exe } : null;
    }
    if (os === 'macos') {
      const out = execFileSync('ps', ['-o', 'ppid=,comm=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 }).trim();
      const m = /^(\d+)\s+(.*)$/.exec(out);
      return m ? { ppid: Number(m[1]), exe: m[2] } : null;
    }
    return null;
  } catch {
    return null;
  }
}

/** All ancestors of this process on Windows in one query: pid → {ppid, exe}. */
function windowsProcessTable() {
  try {
    const out = execFileSync(
      'powershell.exe',
      ['-NoProfile', '-Command', 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId)`t$($_.ParentProcessId)`t$($_.ExecutablePath)" }'],
      { encoding: 'utf8', timeout: 8000, windowsHide: true },
    );
    const table = new Map();
    for (const line of out.split(/\r?\n/)) {
      const [pid, ppid, exe] = line.split('\t');
      if (pid) table.set(Number(pid), { ppid: Number(ppid), exe: exe ?? '' });
    }
    return table;
  } catch {
    return new Map();
  }
}

/**
 * Walk up from `startPid`: the ancestor chain and, on macOS, the host app — the top-most
 * ancestor that is an app bundle (the desktop app the agent's process tree runs in; a CLI or
 * helper bundled as a nested or separate `.app` further down is skipped). Its pid is the
 * main process of that bundle.
 *
 * @param {{startPid?: number, platform?: string, lookup?: (pid: number) => ({ppid: number, exe: string} | null)}} [options]
 * @returns {{hostPid?: number, hostAppPath?: string, ancestorPids: number[]}}
 */
export function detectHost({ startPid = process.ppid, platform = process.platform, lookup } = {}) {
  const os = platformId(platform);
  let find = lookup;
  if (!find) {
    if (os === 'windows') {
      const table = windowsProcessTable();
      find = (pid) => table.get(pid) ?? null;
    } else {
      find = (pid) => processInfo(pid, os);
    }
  }
  const ancestorPids = [];
  let hostPid;
  let hostAppPath;
  let pid = startPid;
  for (let i = 0; i < MAX_DEPTH && Number.isInteger(pid) && pid > 1; i++) {
    const info = find(pid);
    if (!info) break;
    ancestorPids.push(pid);
    if (os === 'macos') {
      const bundle = outermostAppBundle(info.exe);
      if (bundle) {
        // Keep going up: the last bundled ancestor wins.
        hostAppPath = bundle;
        hostPid = pid;
      }
    }
    pid = info.ppid;
  }
  return { hostPid, hostAppPath, ancestorPids };
}

/**
 * The `session.agent` object sent with each request.
 * @param {{clientInfo?: {name?: string, title?: string}, host: ReturnType<typeof detectHost>, env?: NodeJS.ProcessEnv}} options
 * @returns {AgentInfo}
 */
export function agentInfo({ clientInfo, host, env = process.env }) {
  /** @type {AgentInfo} */
  const out = {};
  const name = agentName(clientInfo, env);
  if (name) out.name = name;
  if (host.hostPid) out.hostPid = host.hostPid;
  if (host.hostAppPath) out.hostAppPath = host.hostAppPath;
  if (host.ancestorPids.length) out.ancestorPids = host.ancestorPids;
  return out;
}
