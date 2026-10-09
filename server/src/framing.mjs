// Length-prefixed JSON framing for the helper socket.
//
// Wire format of one frame:
//
//   +----------------------------+------------------------------+
//   | uint32 little-endian N     | N bytes of UTF-8 encoded JSON |
//   +----------------------------+------------------------------+
//
// N == 0 or N > 8 MiB is a protocol error: the receiver must close the
// connection. This module is transport-agnostic (no sockets here) so it can be
// used by the helper client.

/** Size of the length prefix in bytes. */
export const HEADER_BYTES = 4;

/** Largest permitted frame body: 8 MiB (8 388 608 bytes). */
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;

/**
 * Raised for any framing-level protocol violation. The connection that
 * produced it must be closed; the decoder that threw it is poisoned.
 */
export class FramingError extends Error {
  /**
   * @param {string} message
   * @param {'EFRAME_EMPTY'|'EFRAME_TOO_LARGE'|'EFRAME_UTF8'|'EFRAME_JSON'|'EFRAME_ENCODE'|'EFRAME_POISONED'} code
   */
  constructor(message, code) {
    super(message);
    this.name = 'FramingError';
    this.code = code;
    /**
     * Values that were fully decoded from the same push() call before the
     * error was detected. Usually irrelevant (the connection is being torn
     * down), but kept so callers can choose to deliver them.
     * @type {unknown[]}
     */
    this.frames = [];
  }
}

// `fatal: true` makes malformed UTF-8 an error instead of silently inserting
// U+FFFD, which would hide a corrupted stream.
const utf8 = new TextDecoder('utf-8', { fatal: true });

/**
 * Serialise one JSON value into a single frame.
 *
 * @param {unknown} value any JSON-serialisable value
 * @param {{maxFrameBytes?: number}} [options]
 * @returns {Buffer} header + body
 * @throws {FramingError} if the value is not serialisable or is too large
 */
export function encodeFrame(value, { maxFrameBytes = MAX_FRAME_BYTES } = {}) {
  let json;
  try {
    json = JSON.stringify(value);
  } catch (err) {
    throw new FramingError(`cannot serialise frame: ${err.message}`, 'EFRAME_ENCODE');
  }
  if (typeof json !== 'string') {
    // JSON.stringify(undefined) / functions / symbols return undefined.
    throw new FramingError('cannot serialise frame: value is not JSON', 'EFRAME_ENCODE');
  }
  const bodyLength = Buffer.byteLength(json, 'utf8');
  if (bodyLength === 0) {
    throw new FramingError('refusing to encode an empty frame', 'EFRAME_EMPTY');
  }
  if (bodyLength > maxFrameBytes) {
    throw new FramingError(
      `frame of ${bodyLength} bytes exceeds the ${maxFrameBytes}-byte limit`,
      'EFRAME_TOO_LARGE',
    );
  }
  const frame = Buffer.allocUnsafe(HEADER_BYTES + bodyLength);
  frame.writeUInt32LE(bodyLength, 0);
  frame.write(json, HEADER_BYTES, bodyLength, 'utf8');
  return frame;
}

/**
 * Incremental frame decoder for a byte stream.
 *
 * Feed it arbitrary chunks (a frame split across many chunks, many frames
 * coalesced into one chunk, or any mix) and it returns every complete JSON
 * value in order. Body bytes are copied straight into a buffer pre-sized from
 * the header, so large frames arriving in small chunks cost O(N), not O(N²).
 *
 * After a FramingError the decoder is poisoned and every further push()
 * throws: the stream is no longer trustworthy and must be discarded.
 */
export class FrameDecoder {
  /** @param {{maxFrameBytes?: number}} [options] */
  constructor({ maxFrameBytes = MAX_FRAME_BYTES } = {}) {
    this.maxFrameBytes = maxFrameBytes;
    this.#header = Buffer.alloc(HEADER_BYTES);
  }

  #header;
  #headerFilled = 0;
  /** @type {Buffer|null} body of the frame currently being received */
  #body = null;
  #bodyFilled = 0;
  /** @type {FramingError|null} */
  #poisoned = null;

  /** Number of bytes received for a frame that is not yet complete. */
  get bufferedBytes() {
    return this.#headerFilled + this.#bodyFilled + (this.#body ? HEADER_BYTES : 0);
  }

  /** True once a protocol error has been seen. */
  get poisoned() {
    return this.#poisoned !== null;
  }

  /**
   * Consume a chunk of bytes.
   *
   * @param {Uint8Array} chunk
   * @returns {unknown[]} complete decoded JSON values, possibly empty
   * @throws {FramingError} on a protocol violation (see class docs)
   */
  push(chunk) {
    if (this.#poisoned) {
      throw new FramingError(
        `decoder is unusable after an earlier error: ${this.#poisoned.message}`,
        'EFRAME_POISONED',
      );
    }
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    /** @type {unknown[]} */
    const out = [];
    let offset = 0;
    try {
      while (offset < buf.length) {
        if (this.#body === null) {
          // Still collecting the 4-byte length prefix (it may itself be split).
          const take = Math.min(HEADER_BYTES - this.#headerFilled, buf.length - offset);
          buf.copy(this.#header, this.#headerFilled, offset, offset + take);
          this.#headerFilled += take;
          offset += take;
          if (this.#headerFilled < HEADER_BYTES) break;

          const length = this.#header.readUInt32LE(0);
          this.#headerFilled = 0;
          if (length === 0) {
            throw new FramingError('received a zero-length frame', 'EFRAME_EMPTY');
          }
          if (length > this.maxFrameBytes) {
            throw new FramingError(
              `received a frame of ${length} bytes, above the ${this.maxFrameBytes}-byte limit`,
              'EFRAME_TOO_LARGE',
            );
          }
          this.#body = Buffer.allocUnsafe(length);
          this.#bodyFilled = 0;
        } else {
          const body = this.#body;
          const take = Math.min(body.length - this.#bodyFilled, buf.length - offset);
          buf.copy(body, this.#bodyFilled, offset, offset + take);
          this.#bodyFilled += take;
          offset += take;
          if (this.#bodyFilled < body.length) break;

          this.#body = null;
          this.#bodyFilled = 0;
          out.push(parseBody(body));
        }
      }
    } catch (err) {
      const framingError =
        err instanceof FramingError ? err : new FramingError(String(err?.message ?? err), 'EFRAME_JSON');
      framingError.frames = out;
      this.#poisoned = framingError;
      this.#body = null;
      throw framingError;
    }
    return out;
  }

  /** Forget any partial frame and clear the poisoned state. */
  reset() {
    this.#headerFilled = 0;
    this.#body = null;
    this.#bodyFilled = 0;
    this.#poisoned = null;
  }
}

/**
 * @param {Buffer} body
 * @returns {unknown}
 */
function parseBody(body) {
  let text;
  try {
    text = utf8.decode(body);
  } catch {
    throw new FramingError('frame body is not valid UTF-8', 'EFRAME_UTF8');
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new FramingError(`frame body is not valid JSON: ${err.message}`, 'EFRAME_JSON');
  }
}
