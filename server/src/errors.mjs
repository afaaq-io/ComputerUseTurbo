// Error taxonomy shared by the helper and the MCP server.

/**
 * Helper error codes, by name. Each code says whether a retry can help.
 * @type {Readonly<Record<string, {code: number, retryable: boolean}>>}
 */
export const HELPER_ERRORS = Object.freeze({
  callerRejected: { code: 4001, retryable: false },
  appBlockedByPolicy: { code: 4002, retryable: false },
  appProtected: { code: 4003, retryable: false },
  accessMissing: { code: 4004, retryable: false },
  accessWaiting: { code: 4005, retryable: true },
  appNameUnclear: { code: 4006, retryable: false },
  staleElement: { code: 4007, retryable: true },
  haltedByUser: { code: 4008, retryable: false },
  userTookOver: { code: 4009, retryable: true },
  displayLocked: { code: 4010, retryable: true },
  protocolMismatch: { code: 4011, retryable: false },
  timedOut: { code: 4012, retryable: true },
  appMissing: { code: 4013, retryable: false },
  noWindow: { code: 4014, retryable: true },
  observeFirst: { code: 4015, retryable: true },
  passwordGuard: { code: 4016, retryable: false },
  badArguments: { code: 4017, retryable: false },
  actionError: { code: 4018, retryable: true },
  notSupported: { code: 4019, retryable: false },
  helperFault: { code: 4020, retryable: true },
  userDeclined: { code: 4021, retryable: false },
  userActive: { code: 4022, retryable: true },
});

/** JSON-RPC 2.0 level error codes. */
export const JSONRPC_ERRORS = Object.freeze({
  parseError: { code: -32700, retryable: false },
  invalidRequest: { code: -32600, retryable: false },
  methodNotFound: { code: -32601, retryable: false },
  invalidParams: { code: -32602, retryable: false },
  // -32603 is JSON-RPC's own "Internal error"; named distinctly so it is not
  // confused with the helper's 4020 helperFault.
  jsonRpcInternalError: { code: -32603, retryable: false },
});

/** Reverse lookup: numeric code → {name, retryable}. */
const BY_CODE = new Map(
  [...Object.entries(HELPER_ERRORS), ...Object.entries(JSONRPC_ERRORS)].map(([name, v]) => [
    v.code,
    { name, retryable: v.retryable },
  ]),
);

/** Convenience: numeric code for an error name, e.g. CODES.appMissing === 4013. */
export const CODES = Object.freeze(
  Object.fromEntries(Object.entries(HELPER_ERRORS).map(([name, v]) => [name, v.code])),
);

/**
 * An error reported by (or on behalf of) the helper.
 *
 * `name` is the symbolic name (e.g. "appMissing"), `code` the negative
 * integer, `retryable` whether repeating the same call may succeed.
 *
 * Errors that originate locally in the MCP server re-use these names:
 *  - connection / protocol failures talking to the helper → helperFault
 *  - the local safety timer firing                         → timedOut
 *  - hello reporting a different API version               → protocolMismatch
 *  - bad tool arguments caught before contacting the helper → badArguments
 */
export class HelperError extends Error {
  /**
   * @param {{code: number, name: string, message: string, retryable?: boolean, data?: unknown, cause?: unknown}} fields
   */
  constructor({ code, name, message, retryable, data, cause }) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = name;
    this.code = code;
    this.retryable = retryable ?? BY_CODE.get(code)?.retryable ?? false;
    if (data !== undefined) this.data = data;
  }

  /**
   * Build a HelperError for an error name with the table's code and retryability.
   * @param {keyof typeof HELPER_ERRORS} name
   * @param {string} message
   * @param {{retryable?: boolean, cause?: unknown, data?: unknown}} [extra]
   */
  static of(name, message, extra = {}) {
    const entry = HELPER_ERRORS[name] ?? HELPER_ERRORS.helperFault;
    return new HelperError({
      code: entry.code,
      name: HELPER_ERRORS[name] ? name : 'helperFault',
      message,
      retryable: extra.retryable ?? entry.retryable,
      data: extra.data,
      cause: extra.cause,
    });
  }

  /**
   * Map a JSON-RPC `error` member to a HelperError. Prefers the helper's own
   * `data.name` / `data.retryable`, falls back to the code table, and finally
   * to a generic "unknownError".
   *
   * @param {unknown} rpcError
   */
  static fromRpcError(rpcError) {
    const err = rpcError && typeof rpcError === 'object' ? /** @type {any} */ (rpcError) : {};
    const code = Number.isInteger(err.code) ? err.code : HELPER_ERRORS.helperFault.code;
    const known = BY_CODE.get(code);
    const data = err.data && typeof err.data === 'object' ? err.data : undefined;
    const name =
      typeof data?.name === 'string' && data.name.length > 0 ? data.name : (known?.name ?? 'unknownError');
    const retryable = typeof data?.retryable === 'boolean' ? data.retryable : (known?.retryable ?? false);
    const message =
      typeof err.message === 'string' && err.message.length > 0 ? err.message : `helper returned error ${code}`;
    return new HelperError({ code, name, message, retryable, data });
  }

  /** The canonical one-line rendering used in MCP tool results. */
  toToolText() {
    return `${this.name} (${this.code}): ${this.message}`;
  }

  toJSON() {
    return { code: this.code, name: this.name, message: this.message, retryable: this.retryable };
  }
}
