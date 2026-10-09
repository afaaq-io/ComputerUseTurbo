// Per-platform locations shared with the native helper.
//
// Every platform helper (macOS, Windows, Linux) uses the same layout, rooted in the
// platform's usual per-user folders. Overrides for development (never needed in normal use):
//   CUT_SOCKET_PATH      socket / named pipe to connect to
//   CUT_SCREENSHOT_DIR   directory screenshots must live in

import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const PRODUCT_DIR = 'ComputerUseTurbo';
export const PRODUCT_SLUG = 'computer-use-turbo';

/** 'macos' | 'windows' | 'linux' (anything else is treated like Linux). */
export function platformId(platform = process.platform) {
  if (platform === 'darwin') return 'macos';
  if (platform === 'win32') return 'windows';
  return 'linux';
}

function localAppData(env, home) {
  return env.LOCALAPPDATA || join(home, 'AppData', 'Local');
}

/**
 * `/run/user/<uid>` when it exists: the runtime directory, for agent apps that start MCP
 * servers without XDG_RUNTIME_DIR (the helper looks in the same place).
 */
function userRuntimeDir() {
  if (typeof process.getuid !== 'function') return null;
  const dir = `/run/user/${process.getuid()}`;
  return existsSync(dir) ? dir : null;
}

/** Per-user state: settings, approvals, the socket on macOS. */
export function supportDir({ env = process.env, home = homedir(), platform = process.platform } = {}) {
  switch (platformId(platform)) {
    case 'macos':
      return join(home, 'Library', 'Application Support', PRODUCT_DIR);
    case 'windows':
      return join(localAppData(env, home), PRODUCT_DIR);
    default:
      return join(env.XDG_STATE_HOME || join(home, '.local', 'state'), PRODUCT_SLUG);
  }
}

/** Where the helper listens: a Unix socket (macOS, Linux) or a named pipe (Windows). */
export function defaultSocketPath({ env = process.env, home = homedir(), platform = process.platform } = {}) {
  if (env.CUT_SOCKET_PATH) return env.CUT_SOCKET_PATH;
  switch (platformId(platform)) {
    case 'macos':
      return join(supportDir({ env, home, platform }), 'turbo.sock');
    case 'windows':
      return `\\\\.\\pipe\\${PRODUCT_SLUG}-${env.USERNAME || 'user'}`;
    default: {
      const runtime = env.XDG_RUNTIME_DIR || userRuntimeDir();
      return runtime ? join(runtime, `${PRODUCT_SLUG}.sock`) : join(supportDir({ env, home, platform }), 'turbo.sock');
    }
  }
}

/** Screenshots the helper writes (deleted by the server once read). */
export function screenshotDir({ env = process.env, home = homedir(), platform = process.platform } = {}) {
  if (env.CUT_SCREENSHOT_DIR) return env.CUT_SCREENSHOT_DIR;
  switch (platformId(platform)) {
    case 'macos':
      return join(home, 'Library', 'Caches', PRODUCT_DIR, 'shots');
    case 'windows':
      return join(localAppData(env, home), PRODUCT_DIR, 'shots');
    default:
      return join(env.XDG_CACHE_HOME || join(home, '.cache'), PRODUCT_SLUG, 'shots');
  }
}

/** The helper's log file (only referenced in messages). */
export function helperLogPath({ env = process.env, home = homedir(), platform = process.platform } = {}) {
  switch (platformId(platform)) {
    case 'macos':
      return join(home, 'Library', 'Logs', PRODUCT_DIR, 'helper.log');
    default:
      return join(supportDir({ env, home, platform }), 'logs', 'helper.log');
  }
}
