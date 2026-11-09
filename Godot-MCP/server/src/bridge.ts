import WebSocket from "ws";

/** Raised when the editor addon cannot be reached (as opposed to a command failing inside Godot). */
export class BridgeUnavailableError extends Error {}

/** Raised when the addon received the command but reported an error. */
export class GodotCommandError extends Error {}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * JSON-over-WebSocket client for the Godot editor addon.
 * Protocol: {id, method, params, token?} -> {id, result} | {id, error: {message}}
 * Connects lazily on the first call and reconnects after a disconnect.
 */
export class GodotBridge {
  private ws?: WebSocket;
  private connecting?: Promise<WebSocket>;
  private pending = new Map<number, Pending>();
  private nextId = 1;

  constructor(
    readonly url: string,
    private readonly token?: string,
    private readonly defaultTimeoutMs = 15_000,
  ) {}

  async call<T = unknown>(method: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<T> {
    const ws = await this.connect();
    const id = this.nextId++;
    const payload: Record<string, unknown> = { id, method, params };
    if (this.token) payload.token = this.token;

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new GodotCommandError(`Godot did not answer '${method}' within ${timeoutMs ?? this.defaultTimeoutMs} ms.`));
      }, timeoutMs ?? this.defaultTimeoutMs);
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      ws.send(JSON.stringify(payload), (err) => {
        if (!err) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new BridgeUnavailableError(`Failed to send to Godot: ${err.message}`));
      });
    });
  }

  /** True if the editor answers a ping. Never throws. */
  async isAvailable(): Promise<boolean> {
    try {
      await this.call("ping", {}, 2_000);
      return true;
    } catch {
      return false;
    }
  }

  close(): void {
    this.ws?.close();
    this.ws = undefined;
  }

  private connect(): Promise<WebSocket> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return Promise.resolve(this.ws);
    if (this.connecting) return this.connecting;

    this.connecting = new Promise<WebSocket>((resolve, reject) => {
      const ws = new WebSocket(this.url, { handshakeTimeout: 3_000, maxPayload: 64 * 1024 * 1024 });
      let opened = false;

      ws.on("open", () => {
        opened = true;
        this.ws = ws;
        resolve(ws);
      });
      ws.on("message", (data) => this.onMessage(data.toString()));
      ws.on("error", (err) => {
        if (!opened) {
          reject(
            new BridgeUnavailableError(
              `Cannot reach the Godot editor at ${this.url} (${err.message}). ` +
                `Open the project in the Godot editor and enable the "Godot MCP" plugin ` +
                `(Project > Project Settings > Plugins), or use the CLI tools (run_and_capture, check_script, export_project).`,
            ),
          );
        }
      });
      ws.on("close", () => {
        if (this.ws === ws) this.ws = undefined;
        for (const [id, p] of this.pending) {
          clearTimeout(p.timer);
          p.reject(new BridgeUnavailableError("Connection to the Godot editor was closed."));
          this.pending.delete(id);
        }
      });
    }).finally(() => {
      this.connecting = undefined;
    });

    return this.connecting;
  }

  private onMessage(text: string): void {
    let msg: { id?: number; result?: unknown; error?: { message?: string } };
    try {
      // Godot's JSON.stringify leaves control characters unescaped; they are only legal escaped.
      msg = JSON.parse(text.replace(/[\u0000-\u001f]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`));
    } catch {
      console.error("[godot-mcp] invalid JSON from Godot:", text.slice(0, 200));
      const badId = Number(/^\{"id":\s*(\d+)/.exec(text)?.[1]);
      const p = this.pending.get(badId);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(badId);
        p.reject(new GodotCommandError("Godot sent a response that is not valid JSON."));
      }
      return;
    }
    const id = typeof msg.id === "number" ? Math.round(msg.id) : undefined;
    const p = id !== undefined ? this.pending.get(id) : undefined;
    if (!p || id === undefined) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    if (msg.error) p.reject(new GodotCommandError(msg.error.message ?? "Unknown Godot error"));
    else p.resolve(msg.result ?? null);
  }
}
