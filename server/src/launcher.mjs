// Finds and starts the platform helper, and retries the connection while it starts up.
//
//   macOS    Computer Use Turbo.app, started through LaunchServices (`open -g -a`): the OS
//            attributes privacy grants (Accessibility, Screen Recording) to the app bundle,
//            which a child of node would not get.
//   Windows  ComputerUseTurbo.exe, started detached.
//   Linux    computer-use-turbo-helper, started detached.

import { execFile, spawn } from 'node:child_process';
import { statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

import { HelperError } from './errors.mjs';
import { silentLogger } from './log.mjs';
import { PRODUCT_DIR, helperLogPath, platformId } from './paths.mjs';

/** Helper file name per platform. */
export const HELPER_NAMES = Object.freeze({
  macos: 'Computer Use Turbo.app',
  windows: 'computer-use-turbo-helper.exe',
  linux: 'computer-use-turbo-helper',
});

/** Retry cadence after launching the helper. */
export const CONNECT_RETRY_INTERVAL_MS = 250;
export const CONNECT_RETRY_TOTAL_MS = 10_000;

/** server/ (the npm package root): this file lives in server/src/. */
export const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Candidate helper locations in priority order. If $CUT_HELPER_APP is set it is the ONLY
 * candidate: an override that points nowhere is an error, never a silent fallback.
 *
 * @param {{env?: NodeJS.ProcessEnv, home?: string, packageDir?: string, platform?: string}} [options]
 * @returns {{path: string, source: string}[]}
 */
export function helperAppCandidates({
  env = process.env,
  home = homedir(),
  packageDir = PACKAGE_DIR,
  platform = process.platform,
} = {}) {
  if (env.CUT_HELPER_APP) {
    return [{ path: resolve(env.CUT_HELPER_APP), source: '$CUT_HELPER_APP' }];
  }
  const os = platformId(platform);
  const name = HELPER_NAMES[os];
  const dev =
    os === 'macos'
      ? { path: resolve(packageDir, '..', 'helpers', 'macos', 'build', name), source: 'development build' }
      : { path: resolve(packageDir, '..', 'helpers', 'windows-linux', 'target', 'release', name), source: 'development build' };
  switch (os) {
    case 'macos':
      return [
        { path: join(home, 'Applications', name), source: 'installed (~/Applications)' },
        { path: join('/Applications', name), source: 'installed (/Applications)' },
        dev,
      ];
    case 'windows':
      return [
        {
          path: join(env.LOCALAPPDATA || join(home, 'AppData', 'Local'), 'Programs', PRODUCT_DIR, name),
          source: 'installed (%LOCALAPPDATA%\\Programs)',
        },
        dev,
      ];
    default:
      return [{ path: join(home, '.local', 'bin', name), source: 'installed (~/.local/bin)' }, dev];
  }
}

/**
 * Return the first candidate that exists (an .app bundle directory on macOS, a file elsewhere).
 *
 * @param {Parameters<typeof helperAppCandidates>[0] & {exists?: (p: string) => boolean}} [options]
 * @returns {{path: string, source: string} | null}
 */
export function locateHelperApp(options = {}) {
  const exists = options.exists ?? defaultExists;
  for (const candidate of helperAppCandidates(options)) {
    if (exists(candidate.path)) return candidate;
  }
  return null;
}

function defaultExists(p) {
  try {
    const st = statSync(p);
    return st.isDirectory() || st.isFile();
  } catch {
    return false;
  }
}

/**
 * Human-readable instructions shown when no helper can be found.
 *
 * @param {{path: string, source: string}[]} candidates
 */
export function helperNotFoundMessage(candidates) {
  const repoRoot = resolve(PACKAGE_DIR, '..');
  return [
    `The Computer Use Turbo helper was not found. Looked in: ${candidates.map((c) => `${c.path} (${c.source})`).join('; ')}.`,
    'Build and install it, then try again:',
    `  cd ${repoRoot} && ./scripts/build.sh && ./scripts/install.sh`,
    'and grant it the accessibility and screen-capture permissions your OS asks for.',
    'Alternatively set CUT_HELPER_APP to the absolute path of a built helper.',
  ].join('\n');
}

/**
 * Start the helper in the background.
 *
 * @param {string} appPath
 * @param {{execFileImpl?: typeof execFile, spawnImpl?: typeof spawn, timeoutMs?: number, platform?: string}} [options]
 * @returns {Promise<void>}
 */
export function launchHelperApp(
  appPath,
  { execFileImpl = execFile, spawnImpl = spawn, timeoutMs = 15_000, platform = process.platform } = {},
) {
  if (platformId(platform) !== 'macos') {
    return new Promise((resolvePromise, reject) => {
      try {
        const child = spawnImpl(appPath, [], { detached: true, stdio: 'ignore', windowsHide: true });
        child.once?.('error', (error) =>
          reject(HelperError.of('helperFault', `Failed to start ${appPath}: ${error.message}`, { retryable: false, cause: error })),
        );
        child.unref?.();
        setTimeout(resolvePromise, 50).unref?.();
      } catch (error) {
        reject(HelperError.of('helperFault', `Failed to start ${appPath}: ${error.message}`, { retryable: false, cause: error }));
      }
    });
  }
  return new Promise((resolvePromise, reject) => {
    execFileImpl('open', ['-g', '-a', appPath], { timeout: timeoutMs }, (error, _stdout, stderr) => {
      if (error) {
        const detail = String(stderr ?? '').trim() || error.message;
        reject(
          HelperError.of('helperFault', `Failed to launch ${appPath} with "open -g -a": ${detail}`, {
            retryable: false,
            cause: error,
          }),
        );
      } else {
        resolvePromise();
      }
    });
  });
}

/**
 * True if `err` means "nobody is listening yet / the connection dropped
 * while setting up" — i.e. worth launching the helper and retrying. Errors
 * the helper actually *answered* with (version mismatch, …) are not.
 *
 * @param {unknown} err
 */
export function isTransientConnectError(err) {
  return Boolean(err && typeof err === 'object' && /** @type {any} */ (err).transient === true);
}

/**
 * Connect to the helper, launching it if necessary.
 *
 *   1. try `connectOnce()`; done if it succeeds
 *   2. a non-transient error (e.g. protocolMismatch) is rethrown immediately
 *   3. otherwise locate + launch the helper app (unless launching is disabled)
 *   4. retry `connectOnce()` every `intervalMs` until `timeoutMs` has elapsed
 *
 * @template T
 * @param {object} options
 * @param {() => Promise<T>} options.connectOnce attempt one connect + hello
 * @param {string} options.socketPath only used in error messages
 * @param {boolean} [options.launch=true] false → never run `open`, only retry
 * @param {typeof locateHelperApp} [options.locate]
 * @param {typeof launchHelperApp} [options.launchApp]
 * @param {typeof helperAppCandidates} [options.candidates]
 * @param {number} [options.intervalMs]
 * @param {number} [options.timeoutMs]
 * @param {(ms: number) => Promise<unknown>} [options.sleepImpl]
 * @param {() => number} [options.now]
 * @param {import('./log.mjs').Logger} [options.logger]
 * @returns {Promise<T>}
 */
export async function connectWithLaunch({
  connectOnce,
  socketPath,
  launch = true,
  locate = locateHelperApp,
  launchApp = launchHelperApp,
  candidates = helperAppCandidates,
  intervalMs = CONNECT_RETRY_INTERVAL_MS,
  timeoutMs = CONNECT_RETRY_TOTAL_MS,
  sleepImpl = sleep,
  now = Date.now,
  logger = silentLogger,
}) {
  let lastError;
  try {
    return await connectOnce();
  } catch (err) {
    if (!isTransientConnectError(err)) throw err;
    lastError = err;
  }

  let launchedPath = null;
  if (launch) {
    const app = locate();
    if (!app) {
      throw HelperError.of('helperFault', helperNotFoundMessage(candidates()), { retryable: false });
    }
    logger.info(`helper not reachable at ${socketPath} (${describe(lastError)}); launching ${app.path}`);
    await launchApp(app.path);
    launchedPath = app.path;
  } else {
    logger.info(`helper not reachable at ${socketPath} (${describe(lastError)}); auto-launch disabled, retrying`);
  }

  const startedAt = now();
  while (now() - startedAt < timeoutMs) {
    await sleepImpl(intervalMs);
    try {
      return await connectOnce();
    } catch (err) {
      if (!isTransientConnectError(err)) throw err;
      lastError = err;
    }
  }

  const seconds = Math.round(timeoutMs / 100) / 10;
  const what = launchedPath
    ? `Launched ${launchedPath} but could not connect to its socket at ${socketPath} within ${seconds}s`
    : `Could not connect to the helper socket at ${socketPath} within ${seconds}s (auto-launch disabled by CUT_NO_LAUNCH)`;
  throw HelperError.of(
    'helperFault',
    `${what} (last error: ${describe(lastError)}). ` +
      `Make sure the helper can start (it runs in the background) and check ${helperLogPath()}. ` +
      'If it is not installed, run scripts/build.sh and scripts/install.sh.',
    { cause: lastError },
  );
}

/** Short description of a connect failure, preferring the OS-level cause. */
function describe(err) {
  if (!err) return 'unknown error';
  const cause = /** @type {any} */ (err).cause;
  return String(cause?.message ?? /** @type {any} */ (err).message ?? err);
}
