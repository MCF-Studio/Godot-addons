import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import { killTree, type GodotCli } from "../cli.js";
import { editorForProject, pathKey } from "../editors.js";
import { GodotLspClient, LspWorkspaceMismatchError, openSocket } from "./client.js";

export interface LspEndpoint {
  host: string;
  port: number;
  /** env: GODOT_LSP_PORT; editor: the editor that has this project open; default: port 6005; headless: started by us. */
  source: "env" | "editor" | "default" | "headless";
}

export interface LspManagerOptions {
  /** Start a headless editor when no running one serves the project (GODOT_LSP_AUTOSTART=0 disables). */
  autostart: boolean;
  /** Stop a headless editor after this long without queries (Infinity: keep it for the process lifetime). */
  idleMs: number;
}

const DEFAULT_LSP_PORT = 6005;
const HEADLESS_STARTUP_MS = 180_000; // first start of a big project imports every asset

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = (srv.address() as net.AddressInfo).port;
      srv.close(() => resolve(port));
    });
  });
}

/** A `godot --headless --editor --lsp-port N` process serving one project. */
class HeadlessEditor {
  lastUse = Date.now();
  private tail = "";
  private exited = false;

  private constructor(
    readonly projectDir: string,
    readonly port: number,
    private readonly proc: ChildProcess,
  ) {
    const keep = (c: Buffer) => {
      this.tail = (this.tail + c.toString("utf8")).slice(-3000);
    };
    proc.stdout?.on("data", keep);
    proc.stderr?.on("data", keep);
    proc.on("exit", () => {
      this.exited = true;
    });
  }

  static async start(cli: GodotCli, projectDir: string): Promise<HeadlessEditor> {
    const port = await freePort();
    const exe = cli.executable();
    const proc = spawn(exe, ["--headless", "--editor", "--lsp-port", String(port), "--path", projectDir], {
      cwd: projectDir,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      // The Godot MCP plugin stays idle in this editor (no WebSocket server, no chat): see plugin.gd.
      env: { ...process.env, GODOT_MCP_LSP_ONLY: "1" },
    });
    await new Promise<void>((resolve, reject) => {
      proc.once("spawn", () => resolve());
      proc.once("error", (e: NodeJS.ErrnoException) =>
        reject(e.code === "ENOENT" ? new Error(`Godot executable not found ('${exe}'). Set GODOT_PATH, or open the project in the Godot editor.`) : e),
      );
    });
    const editor = new HeadlessEditor(projectDir, port, proc);
    console.error(`[godot-mcp] started a headless Godot editor for its language server (port ${port}, ${projectDir})`);
    await editor.waitReady();
    return editor;
  }

  get alive(): boolean {
    return !this.exited;
  }

  stop(): void {
    if (!this.exited) killTree(this.proc.pid);
    this.exited = true;
  }

  private async waitReady(): Promise<void> {
    const deadline = Date.now() + HEADLESS_STARTUP_MS;
    while (Date.now() < deadline) {
      if (this.exited) throw new Error(`The headless Godot editor exited before its language server started:\n${this.tail.trim().slice(-1500)}`);
      try {
        (await openSocket("127.0.0.1", this.port, 500)).destroy();
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 300));
      }
    }
    this.stop();
    throw new Error(`The headless Godot editor did not open its language server within ${HEADLESS_STARTUP_MS / 1000} s.`);
  }
}

/**
 * Finds the GDScript language server for a project and keeps one client per project.
 * Order: GODOT_LSP_PORT; the editor that has the project open (its session file gives its LSP port);
 * port 6005 if the server there has this project; else a headless editor we start (and stop when idle).
 * A server with another project open is never used: its answers would be about the wrong files.
 */
export class LspManager {
  private readonly clients = new Map<string, Promise<{ client: GodotLspClient; endpoint: LspEndpoint }>>();
  private readonly headless = new Map<string, HeadlessEditor>();
  private readonly starting = new Map<string, Promise<HeadlessEditor>>();
  private idleTimer?: NodeJS.Timeout;

  constructor(
    private readonly cli: GodotCli,
    private readonly opts: LspManagerOptions,
  ) {
    process.once("exit", () => this.dispose());
    if (Number.isFinite(opts.idleMs)) {
      this.idleTimer = setInterval(() => this.stopIdle(), Math.min(60_000, opts.idleMs)).unref();
    }
  }

  /** Client for `projectDir`. spawn=false never starts a headless editor (quick opportunistic checks). */
  async client(projectDir: string, { spawn = true } = {}): Promise<{ client: GodotLspClient; endpoint: LspEndpoint }> {
    const key = pathKey(projectDir);
    const cached = this.clients.get(key);
    if (cached) {
      try {
        const value = await cached;
        if (!value.client.closed) {
          this.markUsed(key);
          return value;
        }
      } catch {
        /* failed attempt: retry below */
      }
      this.clients.delete(key);
    }
    const attempt = this.connect(projectDir, spawn);
    this.clients.set(key, attempt);
    try {
      const value = await attempt;
      value.client.onClose = () => {
        if (this.clients.get(key) === attempt) this.clients.delete(key);
      };
      return value;
    } catch (e) {
      if (this.clients.get(key) === attempt) this.clients.delete(key);
      throw e;
    }
  }

  /** Endpoint only (the stdio bridge opens its own connection and relays the client's own initialize). */
  async endpoint(projectDir: string, { spawn = true } = {}): Promise<LspEndpoint> {
    const { client, endpoint } = await this.connect(projectDir, spawn);
    client.close();
    return endpoint;
  }

  dispose(): void {
    if (this.idleTimer) clearInterval(this.idleTimer);
    for (const c of this.clients.values()) c.then((v) => v.client.close(), () => undefined);
    this.clients.clear();
    for (const h of this.headless.values()) h.stop();
    this.headless.clear();
  }

  private markUsed(key: string): void {
    const h = this.headless.get(key);
    if (h) h.lastUse = Date.now();
  }

  private stopIdle(): void {
    const now = Date.now();
    for (const [key, h] of this.headless) {
      if (h.alive && now - h.lastUse < this.opts.idleMs) continue;
      h.stop();
      this.headless.delete(key);
      const c = this.clients.get(key);
      this.clients.delete(key);
      c?.then((v) => v.client.close(), () => undefined);
      console.error(`[godot-mcp] stopped the idle headless Godot editor (${h.projectDir})`);
    }
  }

  private async connect(projectDir: string, spawn: boolean): Promise<{ client: GodotLspClient; endpoint: LspEndpoint }> {
    const key = pathKey(projectDir);
    const tried: string[] = [];
    const attempt = async (endpoint: LspEndpoint) => {
      try {
        return { client: await GodotLspClient.connect(endpoint.host, endpoint.port, projectDir), endpoint };
      } catch (e) {
        tried.push(`${endpoint.host}:${endpoint.port} (${endpoint.source}): ${e instanceof LspWorkspaceMismatchError ? `other project open (${e.godotProject})` : (e as Error).message}`);
        return undefined;
      }
    };

    const envPort = Number(process.env.GODOT_LSP_PORT);
    if (envPort > 0) {
      const r = await attempt({ host: process.env.GODOT_LSP_HOST || "127.0.0.1", port: envPort, source: "env" });
      if (r) return r;
      throw new Error(`Cannot use the Godot language server set by GODOT_LSP_PORT: ${tried.join("; ")}`);
    }

    const editor = editorForProject(projectDir);
    if (editor?.lsp_port) {
      const r = await attempt({ host: editor.lsp_host || "127.0.0.1", port: editor.lsp_port, source: "editor" });
      if (r) return r;
    }

    const running = this.headless.get(key);
    if (running?.alive) {
      const r = await attempt({ host: "127.0.0.1", port: running.port, source: "headless" });
      if (r) {
        running.lastUse = Date.now();
        return r;
      }
    }

    if (editor?.lsp_port !== DEFAULT_LSP_PORT) {
      const r = await attempt({ host: "127.0.0.1", port: DEFAULT_LSP_PORT, source: "default" });
      if (r) return r;
    }

    if (!spawn || !this.opts.autostart) {
      throw new Error(
        `No Godot language server is serving ${projectDir}. Open the project in the Godot editor` +
          (this.opts.autostart ? "" : " (GODOT_LSP_AUTOSTART=0: no headless editor is started)") +
          `. Tried: ${tried.join("; ") || "nothing"}`,
      );
    }

    const headless = await this.startHeadless(projectDir);
    const r = await attempt({ host: "127.0.0.1", port: headless.port, source: "headless" });
    if (r) return r;
    throw new Error(`The headless Godot editor started but its language server refused the connection: ${tried.join("; ")}`);
  }

  private startHeadless(projectDir: string): Promise<HeadlessEditor> {
    const key = pathKey(projectDir);
    let p = this.starting.get(key);
    if (!p) {
      p = HeadlessEditor.start(this.cli, projectDir).then((h) => {
        this.headless.get(key)?.stop();
        this.headless.set(key, h);
        return h;
      });
      p.finally(() => this.starting.delete(key)).catch(() => undefined);
      this.starting.set(key, p);
    }
    return p;
  }
}
