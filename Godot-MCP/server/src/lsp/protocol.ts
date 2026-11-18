import path from "node:path";

/** One JSON-RPC message of the Language Server Protocol. */
export interface LspMessage {
  jsonrpc?: "2.0";
  id?: number | string | null;
  method?: string;
  params?: any;
  result?: any;
  error?: { code: number; message: string; data?: unknown };
}

/** Refuses absurd frames instead of buffering them forever (Godot's biggest message is a few MB). */
const MAX_FRAME_BYTES = 64 * 1024 * 1024;
const HEADER_END = Buffer.from("\r\n\r\n");

/**
 * Splits a byte stream into LSP messages ("Content-Length: N\r\n\r\n" + N bytes of JSON).
 * Throws on a malformed header: the stream cannot be resynchronised, the caller must close it.
 */
export class LspFramer {
  private buf: Buffer = Buffer.alloc(0);

  constructor(private readonly onMessage: (msg: LspMessage) => void) {}

  push(chunk: Buffer): void {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    for (;;) {
      const headerEnd = this.buf.indexOf(HEADER_END);
      if (headerEnd < 0) {
        if (this.buf.length > 8192) throw new Error("LSP header too long");
        return;
      }
      const header = this.buf.subarray(0, headerEnd).toString("ascii");
      const match = /^content-length:\s*(\d+)\s*$/im.exec(header);
      if (!match) throw new Error(`LSP header without Content-Length: ${header.slice(0, 200)}`);
      const length = Number(match[1]);
      if (length > MAX_FRAME_BYTES) throw new Error(`LSP message too large (${length} bytes)`);
      const start = headerEnd + HEADER_END.length;
      if (this.buf.length < start + length) return;
      const body = this.buf.subarray(start, start + length).toString("utf8");
      this.buf = this.buf.subarray(start + length);
      let msg: LspMessage;
      try {
        msg = JSON.parse(body);
      } catch {
        continue; // one bad body does not desynchronise the stream: skip it
      }
      this.onMessage(msg);
    }
  }
}

export function frame(msg: LspMessage): Buffer {
  const body = Buffer.from(JSON.stringify(msg), "utf8");
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii"), body]);
}

/**
 * file:// URI in the form Godot builds itself ("file:///" + project path, not percent-encoded,
 * upper-case drive letter on Windows). Every Godot 4.x version understands it.
 */
export function toGodotUri(fsPath: string): string {
  let p = path.resolve(fsPath).replace(/\\/g, "/");
  if (/^[a-z]:/.test(p)) p = p[0].toUpperCase() + p.slice(1);
  return p.startsWith("/") ? `file://${p}` : `file:///${p}`;
}

/** Filesystem path of a file:// URI, whatever its encoding ("file:///I%3A/x", "file:///i:/x", "file:///home/x"). */
export function fromUri(uri: string): string {
  let p = uri.replace(/^file:\/\//i, "");
  try {
    p = decodeURIComponent(p);
  } catch {
    /* keep as is */
  }
  if (/^\/[a-zA-Z]:/.test(p)) p = p.slice(1); // "/C:/x" -> "C:/x"
  return path.resolve(p);
}

/** Rewrites file:// URIs into Godot's form, wherever they are in a message (client -> Godot). */
export function normalizeUris<T>(value: T): T {
  if (typeof value === "string") return (/^file:\/\//i.test(value) ? toGodotUri(fromUri(value)) : value) as T;
  if (Array.isArray(value)) return value.map(normalizeUris) as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    // "text" holds document contents (didOpen / didChange / didSave): never touch it.
    for (const [k, v] of Object.entries(value)) out[k] = k === "text" ? v : normalizeUris(v);
    return out as T;
  }
  return value;
}
