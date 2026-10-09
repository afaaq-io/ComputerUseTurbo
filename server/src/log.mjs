// Minimal stderr logger.
//
// stdout belongs exclusively to the MCP stdio transport: a single stray byte
// there corrupts the JSON-RPC stream. Everything diagnostic goes to stderr,
// which MCP clients capture into their own logs.
//
// Level comes from $CUT_LOG_LEVEL: debug | info (default) | warn | error | silent.

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, silent: 100 };

/**
 * @typedef {object} Logger
 * @property {(...args: unknown[]) => void} debug
 * @property {(...args: unknown[]) => void} info
 * @property {(...args: unknown[]) => void} warn
 * @property {(...args: unknown[]) => void} error
 */

/**
 * @param {string} [scope] short component name printed in every line
 * @param {{level?: string, write?: (line: string) => void}} [options]
 * @returns {Logger}
 */
export function createLogger(scope = 'turbo', options = {}) {
  const levelName = (options.level ?? process.env.CUT_LOG_LEVEL ?? 'info').toLowerCase();
  const threshold = LEVELS[levelName] ?? LEVELS.info;
  const write = options.write ?? ((line) => process.stderr.write(line));

  const emit = (level, args) => {
    if (LEVELS[level] < threshold) return;
    const text = args
      .map((a) => (a instanceof Error ? (a.stack ?? a.message) : typeof a === 'string' ? a : safeJson(a)))
      .join(' ');
    write(`${new Date().toISOString()} [${scope}] ${level.toUpperCase()} ${text}\n`);
  };

  return {
    debug: (...args) => emit('debug', args),
    info: (...args) => emit('info', args),
    warn: (...args) => emit('warn', args),
    error: (...args) => emit('error', args),
  };
}

/** A logger that discards everything (default for library code). */
export const silentLogger = Object.freeze({
  debug() {},
  info() {},
  warn() {},
  error() {},
});

function safeJson(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
