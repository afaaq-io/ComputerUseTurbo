// JSON-RPC 2.0 client for the helper's socket / named pipe.
//
// Responsibilities:
//  - connect to the Unix socket (Windows: named pipe) and perform the mandatory `hello`
//    handshake (API version check; a mismatch is fatal and never retried)
//  - serialise requests: exactly one request in flight per connection
//  - stamp every `request` with deadlineUnixMillis and the session, and arm a
//    local timer slightly longer than the deadline as a safety net
//  - map JSON-RPC errors to HelperError {code, name, message, retryable}
//  - reconnect lazily (with an optional launch strategy) after the
//    connection closes
//
// It deliberately knows nothing about MCP; server.mjs builds on top of it.

import { randomUUID } from 'node:crypto';
import net from 'node:net';

import { HelperError } from './errors.mjs';
import { FrameDecoder, FramingError, encodeFrame } from './framing.mjs';
import { silentLogger } from './log.mjs';
import { defaultSocketPath } from './paths.mjs';

export { HelperError } from './errors.mjs';

/** API version this client speaks (`hello.clientApiVersion`). */
export const CLIENT_API_VERSION = 'turbo-1';
export const CLIENT_NAME = 'computer-use-turbo-server';

/** Default per-request deadline sent to the helper. */
export const DEFAULT_DEADLINE_MS = 120_000;
/** The local safety timer fires this long after the helper's deadline. */
export const LOCAL_TIMEOUT_GRACE_MS = 5_000;
/**
 * Gated requests may show the approval dialog, whose wait time the helper
 * adds to the deadline and which itself times out after 120 s.
 * The local timer allows for that so it never fires before the helper would.
 */
export const APPROVAL_ALLOWANCE_MS = 120_000;
/** How long to wait for the `hello` reply on a fresh connection. */
export const HELLO_TIMEOUT_MS = 5_000;

/** Request types that run the helper's safety and approval checks first. */
export const GATED_REQUEST_TYPES = Object.freeze(new Set(['observeApp', 'act', 'appCommands', 'waitFor']));

/**
 * Mark an error as a transient connection failure: nobody listening yet, or
 * the connection dropped during setup. The launch/retry strategy only retries
 * errors marked this way.
 * @template {Error} E
 * @param {E} err
 * @returns {E}
 */
function transient(err) {
  /** @type {any} */ (err).transient = true;
  return err;
}

/**
 * @typedef {object} Session
 * @property {string} sessionId
 * @property {string|null} turnId
 */

/**
 * @typedef {object} HelloResult
 * @property {string} serverApiVersion
 * @property {string} [helperVersion]
 * @property {number} [pid]
 * @property {{accessibility: boolean, screenRecording: boolean}} [permissions]
 */

/**
 * @typedef {(connectOnce: () => Promise<Connection>, context: {socketPath: string}) => Promise<Connection>} ConnectStrategy
 */

/**
 * One live socket connection plus its decoder and the single pending call.
 * @typedef {object} Connection
 * @property {net.Socket} socket
 * @property {FrameDecoder} decoder
 * @property {{id: number, resolve: (v: unknown) => void, reject: (e: unknown) => void, timer: NodeJS.Timeout}|null} pending
 * @property {boolean} dead
 * @property {HelloResult|null} hello
 * @property {number} serial connection number (diagnostics)
 */

export class HelperClient {
  /**
   * @param {object} [options]
   * @param {string} [options.socketPath] default: $CUT_SOCKET_PATH or the default per-user path
   * @param {string} [options.clientName]
   * @param {Session} [options.session] default: a fresh UUID with turnId null
   * @param {number} [options.defaultDeadlineMs]
   * @param {number} [options.localGraceMs]
   * @param {number} [options.approvalAllowanceMs]
   * @param {number} [options.helloTimeoutMs]
   * @param {ConnectStrategy} [options.connectStrategy] wraps a single connect
   *   attempt with launch/retry logic (see launcher.mjs). Default: one attempt.
   * @param {import('./log.mjs').Logger} [options.logger]
   */
  constructor({
    socketPath = defaultSocketPath(),
    clientName = CLIENT_NAME,
    session = { sessionId: randomUUID(), turnId: null },
    defaultDeadlineMs = DEFAULT_DEADLINE_MS,
    localGraceMs = LOCAL_TIMEOUT_GRACE_MS,
    approvalAllowanceMs = APPROVAL_ALLOWANCE_MS,
    helloTimeoutMs = HELLO_TIMEOUT_MS,
    connectStrategy = (connectOnce) => connectOnce(),
    logger = silentLogger,
  } = {}) {
    this.socketPath = socketPath;
    this.clientName = clientName;
    this.session = Object.freeze({ sessionId: session.sessionId, turnId: session.turnId ?? null });
    this.defaultDeadlineMs = defaultDeadlineMs;
    this.localGraceMs = localGraceMs;
    this.approvalAllowanceMs = approvalAllowanceMs;
    this.helloTimeoutMs = helloTimeoutMs;
    this.connectStrategy = connectStrategy;
    this.log = logger;
  }

  /** @type {Connection|null} */
  #conn = null;
  /** Tail of the serial work queue; never rejects. */
  #tail = Promise.resolve();
  #nextId = 1;
  #connectionSerial = 0;
  /** @type {HelperError|null} set on protocolMismatch: the client is unusable */
  #fatal = null;
  #closed = false;
  /** @type {HelloResult|null} */
  #lastHello = null;

  /** True while a connection that completed `hello` is open. */
  get connected() {
    return this.#conn !== null && !this.#conn.dead;
  }

  /** Result of the most recent successful `hello`, if any. */
  get helloResult() {
    return this.#lastHello;
  }

  /** Make sure a connection exists (connecting/launching if needed). */
  async connect() {
    return this.#enqueue(async () => {
      this.#assertUsable();
      const conn = await this.#ensureConnected();
      return conn.hello;
    });
  }

  /**
   * Send a `request` and resolve with its result.
   * Requests are queued and sent strictly one at a time.
   *
   * @param {string} requestType one of the helper's request types
   * @param {Record<string, unknown>} [payload]
   * @param {object} [options]
   * @param {number} [options.deadlineMs] relative deadline, default 120 s
   * @param {Session} [options.session] override the client's session
   * @param {AbortSignal} [options.signal] abort while still queued
   * @param {boolean} [options.onlyIfConnected] fail instead of (re)connecting
   * @returns {Promise<any>}
   */
  request(requestType, payload = {}, { deadlineMs, session, signal, onlyIfConnected = false } = {}) {
    return this.#enqueue(async () => {
      this.#assertUsable();
      signal?.throwIfAborted();
      let conn;
      if (onlyIfConnected) {
        if (!this.connected) throw HelperError.of('helperFault', 'not connected to the helper');
        conn = /** @type {Connection} */ (this.#conn);
      } else {
        conn = await this.#ensureConnected();
      }
      signal?.throwIfAborted();

      const relative = deadlineMs ?? this.defaultDeadlineMs;
      const localTimeoutMs =
        relative + this.localGraceMs + (GATED_REQUEST_TYPES.has(requestType) ? this.approvalAllowanceMs : 0);
      const params = {
        requestType,
        payload,
        deadlineUnixMillis: Date.now() + relative,
        session: session ?? this.session,
      };
      return this.#call(conn, 'request', params, localTimeoutMs, {
        // The helper does not notice that we gave up: it keeps going and may still
        // perform the action. A blind retry could click or type twice.
        localTimeoutError:
          requestType === 'act'
            ? (seconds) =>
                HelperError.of(
                  'timedOut',
                  `the helper did not answer within ${seconds}s; the action may already have been performed or may ` +
                    'still be running. Call observe_app to check the app before retrying.',
                  { retryable: false },
                )
            : undefined,
      });
    });
  }

  /** Close the connection and refuse further requests. */
  close() {
    this.#closed = true;
    if (this.#conn) this.#fail(this.#conn, HelperError.of('helperFault', 'helper client closed', { retryable: false }));
  }

  // ---------------------------------------------------------------- internals

  #assertUsable() {
    if (this.#fatal) throw this.#fatal;
    if (this.#closed) throw HelperError.of('helperFault', 'helper client closed', { retryable: false });
  }

  /**
   * Run `task` after every previously queued task has settled.
   * @template T
   * @param {() => Promise<T>} task
   * @returns {Promise<T>}
   */
  #enqueue(task) {
    const run = this.#tail.then(() => task());
    this.#tail = run.then(
      () => {},
      () => {},
    );
    return run;
  }

  /** @returns {Promise<Connection>} */
  async #ensureConnected() {
    if (this.#conn && !this.#conn.dead) return this.#conn;
    this.#conn = null;
    return this.connectStrategy(() => this.#connectOnce(), { socketPath: this.socketPath });
  }

  /**
   * One attempt: open the socket and complete `hello`.
   * @returns {Promise<Connection>}
   */
  async #connectOnce() {
    this.#assertUsable();
    const socket = await new Promise((resolve, reject) => {
      const s = net.createConnection({ path: this.socketPath });
      const onError = (err) => {
        s.destroy();
        reject(
          transient(
            HelperError.of('helperFault', `cannot connect to helper socket ${this.socketPath}: ${err.message}`, {
              cause: err,
            }),
          ),
        );
      };
      s.once('error', onError);
      s.once('connect', () => {
        s.off('error', onError);
        resolve(s);
      });
    });

    const conn = this.#attach(socket);
    /** @type {HelloResult} */
    let hello;
    try {
      hello = /** @type {HelloResult} */ (
        await this.#call(
          conn,
          'hello',
          { clientApiVersion: CLIENT_API_VERSION, clientName: this.clientName },
          this.helloTimeoutMs,
        )
      );
    } catch (err) {
      this.#fail(conn, HelperError.of('helperFault', 'hello failed'));
      if (err instanceof HelperError && err.name === 'protocolMismatch') throw this.#makeFatal(err);
      throw err;
    }

    const serverVersion = hello && typeof hello === 'object' ? hello.serverApiVersion : undefined;
    if (serverVersion !== CLIENT_API_VERSION) {
      this.#fail(conn, HelperError.of('helperFault', 'version mismatch'));
      throw this.#makeFatal(
        HelperError.of(
          'protocolMismatch',
          `helper speaks API "${String(serverVersion)}" but this server speaks "${CLIENT_API_VERSION}"`,
        ),
      );
    }

    if (this.#closed) {
      // close() was called while we were connecting.
      this.#fail(conn, HelperError.of('helperFault', 'helper client closed'));
      this.#assertUsable();
    }

    conn.hello = hello;
    this.#lastHello = hello;
    this.#conn = conn;
    this.log.info(
      `connected to helper ${hello.helperVersion ?? '?'} (pid ${hello.pid ?? '?'}) on ${this.socketPath}; ` +
        `permissions ${JSON.stringify(hello.permissions ?? {})}`,
    );
    return conn;
  }

  /** Record a version mismatch as permanent: the client must not retry. */
  #makeFatal(err) {
    const fatal = HelperError.of(
      'protocolMismatch',
      `${err.message}. The MCP server and the helper are from different builds: ` +
        'rebuild/reinstall both (scripts/build.sh, scripts/install.sh) and restart the MCP server.',
      { retryable: false, data: err.data },
    );
    this.#fatal = fatal;
    this.log.error(fatal.message);
    return fatal;
  }

  /**
   * Wire socket events to a new Connection record.
   * @param {net.Socket} socket
   * @returns {Connection}
   */
  #attach(socket) {
    /** @type {Connection} */
    const conn = {
      socket,
      decoder: new FrameDecoder(),
      pending: null,
      dead: false,
      hello: null,
      serial: ++this.#connectionSerial,
    };
    socket.on('data', (chunk) => {
      let messages;
      try {
        messages = conn.decoder.push(chunk);
      } catch (err) {
        const message = err instanceof FramingError ? err.message : String(err);
        this.#fail(conn, transient(HelperError.of('helperFault', `protocol error from helper: ${message}`)));
        return;
      }
      for (const msg of messages) this.#onMessage(conn, msg);
    });
    socket.on('error', (err) => {
      this.#fail(
        conn,
        transient(HelperError.of('helperFault', `helper connection error: ${err.message}`, { cause: err })),
      );
    });
    socket.on('close', () => {
      this.#fail(conn, transient(HelperError.of('helperFault', 'helper closed the connection')));
    });
    return conn;
  }

  /**
   * Send one JSON-RPC call on `conn` and wait for its response.
   * @param {Connection} conn
   * @param {string} method
   * @param {unknown} params
   * @param {number} localTimeoutMs
   * @param {{localTimeoutError?: (seconds: number) => HelperError}} [options]
   */
  #call(conn, method, params, localTimeoutMs, { localTimeoutError } = {}) {
    return new Promise((resolve, reject) => {
      if (conn.dead) {
        reject(transient(HelperError.of('helperFault', 'helper connection is closed')));
        return;
      }
      const id = this.#nextId++;
      let frame;
      try {
        frame = encodeFrame({ jsonrpc: '2.0', id, method, params });
      } catch (err) {
        reject(HelperError.of('badArguments', `cannot send ${method}: ${err.message}`));
        return;
      }
      const timer = setTimeout(() => {
        // The helper may still answer later; the connection is torn down so a
        // late reply can never be mistaken for the next request's reply.
        const seconds = Math.round(localTimeoutMs / 1000);
        this.#fail(
          conn,
          localTimeoutError?.(seconds) ??
            HelperError.of('timedOut', `the helper did not answer "${method}" within ${seconds}s`),
        );
      }, localTimeoutMs);
      timer.unref?.();
      conn.pending = { id, resolve, reject, timer };
      this.log.debug(`→ #${conn.serial} ${method} id=${id}`, method === 'request' ? params.requestType : '');
      conn.socket.write(frame);
    });
  }

  /**
   * @param {Connection} conn
   * @param {unknown} msg
   */
  #onMessage(conn, msg) {
    if (conn.dead) return;
    if (!msg || typeof msg !== 'object' || Array.isArray(msg) || /** @type {any} */ (msg).jsonrpc !== '2.0') {
      this.#fail(conn, transient(HelperError.of('helperFault', 'protocol error: helper sent a non JSON-RPC 2.0 message')));
      return;
    }
    const m = /** @type {any} */ (msg);
    const pending = conn.pending;
    if (!pending || m.id !== pending.id) {
      // v1 has no notifications and one call in flight; anything else is noise.
      this.log.warn(`ignoring unexpected message from helper (id=${JSON.stringify(m.id)})`);
      return;
    }
    conn.pending = null;
    clearTimeout(pending.timer);
    if ('error' in m && m.error != null) {
      const err = HelperError.fromRpcError(m.error);
      this.log.debug(`← #${conn.serial} id=${m.id} error ${err.name} (${err.code})`);
      pending.reject(err);
    } else if ('result' in m) {
      this.log.debug(`← #${conn.serial} id=${m.id} ok`);
      pending.resolve(m.result);
    } else {
      pending.reject(HelperError.of('helperFault', 'protocol error: response has neither result nor error'));
      this.#fail(conn, HelperError.of('helperFault', 'protocol error'));
    }
  }

  /**
   * Tear down `conn` (idempotent) and reject its pending call with `err`.
   * @param {Connection} conn
   * @param {HelperError} err
   */
  #fail(conn, err) {
    if (conn.dead) return;
    conn.dead = true;
    conn.socket.destroy();
    if (this.#conn === conn) this.#conn = null;
    const pending = conn.pending;
    conn.pending = null;
    if (pending) {
      clearTimeout(pending.timer);
      pending.reject(err);
    }
    this.log.debug(`connection #${conn.serial} closed: ${err.message}`);
  }
}
