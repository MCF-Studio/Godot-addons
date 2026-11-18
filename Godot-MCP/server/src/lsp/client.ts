import { readFile } from "node:fs/promises";
import net from "node:net";
import { pathKey, samePath } from "../editors.js";
import { frame, fromUri, LspFramer, toGodotUri, type LspMessage } from "./protocol.js";

export interface Position {
  line: number; // 0-based (LSP)
  character: number;
}
export interface Range {
  start: Position;
  end: Position;
}
export interface Diagnostic {
  range: Range;
  severity?: number;
  code?: number | string;
  source?: string;
  message: string;
}

/** The language server answers, but for another project than the one asked for. */
export class LspWorkspaceMismatchError extends Error {
  constructor(readonly godotProject: string) {
    super(`This Godot language server has another project open: ${godotProject}`);
  }
}

interface Pending {
  resolve: (value: any) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
}

/** Opens a TCP connection, failing after `timeoutMs` (a closed port fails at once; a filtered one would hang). */
export function openSocket(host: string, port: number, timeoutMs: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`timeout connecting to ${host}:${port}`));
    }, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      socket.setNoDelay(true);
      resolve(socket);
    });
    socket.once("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/**
 * Client of Godot's GDScript language server (TCP, the editor's "network/language_server/remote_port",
 * 6005 by default). Godot accepts several clients at once, so this one coexists with VS Code or Claude Code.
 *
 * Every document query re-opens the file with its current content on disk and closes it afterwards: a
 * headless editor does not watch the disk, and an open document would hide later edits made elsewhere.
 * Queries are serialized (see exclusive()).
 */
export class GodotLspClient {
  closed = false;
  /** Project Godot reported through gdscript_client/changeWorkspace (only sent when it differs from ours). */
  godotWorkspace?: string;
  onClose?: () => void;

  private readonly framer: LspFramer;
  private readonly pending = new Map<number, Pending>();
  private readonly diagnosticWaiters = new Map<string, (d: Diagnostic[]) => void>();
  private readonly versions = new Map<string, number>();
  private nextId = 1;
  private queue: Promise<unknown> = Promise.resolve();

  private constructor(private readonly socket: net.Socket) {
    this.framer = new LspFramer((m) => this.onMessage(m));
    socket.on("data", (chunk: Buffer) => {
      try {
        this.framer.push(chunk);
      } catch (e) {
        console.error(`[godot-mcp] LSP stream error: ${(e as Error).message}`);
        socket.destroy();
      }
    });
    socket.on("error", () => {
      /* "close" follows */
    });
    socket.on("close", () => this.onSocketClosed());
  }

  /**
   * Connects and initializes. Throws LspWorkspaceMismatchError when that server has another project open
   * (the caller then tries elsewhere).
   */
  static async connect(host: string, port: number, projectDir: string, connectTimeoutMs = 1500): Promise<GodotLspClient> {
    const client = new GodotLspClient(await openSocket(host, port, connectTimeoutMs));
    try {
      const root = projectDir.replace(/\\/g, "/");
      await client.request(
        "initialize",
        {
          processId: process.pid,
          clientInfo: { name: "godot-mcp" },
          rootPath: root,
          rootUri: toGodotUri(projectDir),
          workspaceFolders: [{ uri: toGodotUri(projectDir), name: "project" }],
          capabilities: {
            textDocument: {
              publishDiagnostics: {},
              hover: { contentFormat: ["markdown", "plaintext"] },
              documentSymbol: { hierarchicalDocumentSymbolSupport: true },
            },
          },
        },
        20_000,
      );
      client.notify("initialized", {});
      // changeWorkspace is pushed while Godot handles initialize; give a stray late one a moment.
      await new Promise((r) => setTimeout(r, 100));
      if (client.godotWorkspace && !samePath(client.godotWorkspace, projectDir)) throw new LspWorkspaceMismatchError(client.godotWorkspace);
      return client;
    } catch (e) {
      client.close();
      throw e;
    }
  }

  request<T = any>(method: string, params: unknown, timeoutMs = 15_000): Promise<T> {
    if (this.closed) return Promise.reject(new Error("The Godot language server connection is closed."));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Godot's language server did not answer '${method}' within ${timeoutMs} ms.`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.write(frame({ jsonrpc: "2.0", id, method, params }));
    });
  }

  notify(method: string, params: unknown): void {
    if (!this.closed) this.socket.write(frame({ jsonrpc: "2.0", method, params }));
  }

  /** Runs `fn` after every query queued before it. */
  exclusive<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.then(fn, fn);
    this.queue = run.catch(() => undefined);
    return run;
  }

  /** Opens `fsPath` with its current content, runs `fn`, closes it. Returns fn's value. */
  withDocument<T>(fsPath: string, fn: (uri: string, text: string) => Promise<T>): Promise<T> {
    return this.exclusive(async () => {
      const text = await readFile(fsPath, "utf8");
      const uri = this.open(fsPath, text);
      try {
        return await fn(uri, text);
      } finally {
        this.notify("textDocument/didClose", { textDocument: { uri } });
      }
    });
  }

  /** Errors and warnings Godot reports for `fsPath` as it is on disk now. */
  diagnostics(fsPath: string, timeoutMs = 10_000): Promise<Diagnostic[]> {
    return this.exclusive(async () => {
      const text = await readFile(fsPath, "utf8");
      const key = pathKey(fsPath);
      const received = new Promise<Diagnostic[]>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.diagnosticWaiters.delete(key);
          reject(new Error(`Godot's language server sent no diagnostics for ${fsPath} within ${timeoutMs} ms.`));
        }, timeoutMs);
        this.diagnosticWaiters.set(key, (d) => {
          clearTimeout(timer);
          resolve(d);
        });
      });
      const uri = this.open(fsPath, text);
      try {
        return await received;
      } finally {
        this.notify("textDocument/didClose", { textDocument: { uri } });
      }
    });
  }

  close(): void {
    if (!this.closed) {
      try {
        this.socket.end(frame({ jsonrpc: "2.0", method: "exit" }));
      } catch {
        /* already gone */
      }
    }
    this.socket.destroy();
  }

  private open(fsPath: string, text: string): string {
    const uri = toGodotUri(fsPath);
    const version = (this.versions.get(uri) ?? 0) + 1;
    this.versions.set(uri, version);
    this.notify("textDocument/didOpen", { textDocument: { uri, languageId: "gdscript", version, text } });
    return uri;
  }

  private onMessage(msg: LspMessage): void {
    if (msg.method) {
      if (msg.id !== undefined && msg.id !== null) {
        // A request from Godot to us: answer so it never waits (we have no client-side features).
        this.socket.write(frame({ jsonrpc: "2.0", id: msg.id, result: null }));
        return;
      }
      if (msg.method === "textDocument/publishDiagnostics" && msg.params?.uri) {
        const key = pathKey(fromUri(msg.params.uri));
        const waiter = this.diagnosticWaiters.get(key);
        if (waiter) {
          this.diagnosticWaiters.delete(key);
          waiter(msg.params.diagnostics ?? []);
        }
      } else if (msg.method === "gdscript_client/changeWorkspace" && typeof msg.params?.path === "string") {
        this.godotWorkspace = msg.params.path;
      }
      return;
    }
    const id = typeof msg.id === "number" ? msg.id : Number(msg.id);
    const p = this.pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    if (msg.error) p.reject(new Error(`Godot language server: ${msg.error.message}`));
    else p.resolve(msg.result ?? null);
  }

  private onSocketClosed(): void {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("The Godot language server closed the connection (editor closed?)."));
    }
    this.pending.clear();
    this.onClose?.();
  }
}
