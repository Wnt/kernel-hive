// ============================================================================
//  streamClient/byteReader — incremental byte reader over a uni-stream reader
//  (the tagged audio / KIND_PARAMS paths). Lifted verbatim from streamClient.
// ============================================================================

export class ByteReader {
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private buf: Uint8Array = new Uint8Array(0);
  private done = false;

  constructor(reader: ReadableStreamDefaultReader<Uint8Array>) {
    this.reader = reader;
  }

  private async pull(): Promise<boolean> {
    if (this.done) return false;
    const { value, done } = await this.reader.read();
    if (done) { this.done = true; return false; }
    if (value && value.length) {
      const next = new Uint8Array(this.buf.length + value.length);
      next.set(this.buf, 0);
      next.set(value, this.buf.length);
      this.buf = next;
    }
    return true;
  }

  /** Read exactly n bytes, or null at end-of-stream. */
  async readBytes(n: number): Promise<Uint8Array | null> {
    while (this.buf.length < n) {
      if (!(await this.pull())) return null;
    }
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }

  async readU8(): Promise<number | null> {
    const b = await this.readBytes(1);
    return b ? b[0] : null;
  }
  async readU16LE(): Promise<number | null> {
    const b = await this.readBytes(2);
    return b ? b[0] | (b[1] << 8) : null;
  }
  async readU32LE(): Promise<number | null> {
    const b = await this.readBytes(4);
    return b ? (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0 : null;
  }
  /** Drain the rest of the stream into one contiguous buffer. */
  async readToEnd(): Promise<Uint8Array> {
    while (await this.pull()) { /* accumulate */ }
    const out = this.buf;
    this.buf = new Uint8Array(0);
    return out;
  }
}
