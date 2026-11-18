import { existsSync, readdirSync, statSync } from "node:fs";
import type net from "node:net";
import os from "node:os";
import path from "node:path";
import { GodotCli } from "../cli.js";
import { listEditors, samePath } from "../editors.js";
import { openSocket } from "./client.js";
import { LspManager } from "./locate.js";
import { frame, fromUri, LspFramer, normalizeUris, toGodotUri, type LspMessage } from "./protocol.js";

/**
 * `godot-mcp-server.mjs --lsp`: a stdio language server for clients that cannot open TCP (Claude Code's
 * plugin LSP servers). It finds the Godot language server of the client's project (see LspManager) and
 * relays bytes both ways, rewriting only what Godot needs:
 *  - initialize gets the Godot project as root (the client may have opened a parent folder);
 *  - file:// URIs are sent in Godot's own form (older Godot versions are strict about it);
 *  - Godot-specific notifications (gdscript/capabilities is several MB of class list) are dropped.
 * Without a Godot project or a reachable Godot, it answers as an empty server instead of crashing, so the
 * client does not restart it in a loop. stdout carries the protocol only: logs go to stderr.
 */
export async function runLspBridge(): Promise<void> {
  const log = (m: string) => console.error(`[godot-mcp lsp] ${m}`);
  const write = (msg: LspMessage) => process.stdout.write(frame(msg));

  let godot: net.Socket | undefined;
  let mode: "waiting" | "connecting" | "relay" | "empty" = "waiting";
  const queued: LspMessage[] = [];
  let exitRequested = false;
  const manager = new LspManager(new GodotCli(), { autostart: process.env.GODOT_LSP_AUTOSTART !== "0", idleMs: Infinity });

  const quit = (code: number) => {
    manager.dispose(); // stops a headless editor we started
    godot?.destroy();
    process.exit(code);
  };

  const sendToGodot = (msg: LspMessage) => godot?.write(frame(normalizeUris(msg)));

  /** Answers like a server without any feature (no Godot project, or Godot unreachable). */
  const answerEmpty = (msg: LspMessage) => {
    if (msg.method === "exit") quit(0);
    if (msg.id === undefined || msg.id === null || !msg.method) return;
    if (msg.method === "initialize") write({ jsonrpc: "2.0", id: msg.id, result: { capabilities: {}, serverInfo: { name: "godot-mcp-gdscript (inactive)" } } });
    else write({ jsonrpc: "2.0", id: msg.id, result: null });
  };

  const start = async (init: LspMessage) => {
    mode = "connecting";
    const project = findProject(init.params ?? {});
    if (!project) {
      log("no Godot project (project.godot) in the client's workspace: GDScript features are off");
      mode = "empty";
      answerEmpty(init);
      queued.splice(0).forEach(answerEmpty);
      return;
    }
    try {
      const endpoint = await manager.endpoint(project);
      godot = await openSocket(endpoint.host, endpoint.port, 3_000);
      log(`relaying to Godot's language server ${endpoint.host}:${endpoint.port} (${endpoint.source}) for ${project}`);
    } catch (e) {
      log(`Godot's language server is unavailable: ${(e as Error).message}`);
      mode = "empty";
      answerEmpty(init);
      queued.splice(0).forEach(answerEmpty);
      return;
    }
    const fromGodot = new LspFramer((msg) => {
      if (msg.method && /^gdscript(_client)?\//.test(msg.method)) return;
      if (msg.method === "window/showMessage" && /other projects than the one opened/i.test(msg.params?.message ?? "")) return;
      write(msg);
    });
    godot.on("data", (chunk: Buffer) => {
      try {
        fromGodot.push(chunk);
      } catch (e) {
        log(`invalid data from Godot: ${(e as Error).message}`);
        godot?.destroy();
      }
    });
    godot.on("error", () => undefined);
    godot.on("close", () => {
      if (exitRequested) quit(0);
      log("Godot's language server closed the connection (editor closed?)");
      quit(1); // the client restarts us, and we find whichever Godot serves the project now
    });
    const root = project.replace(/\\/g, "/");
    sendToGodot({
      ...init,
      params: { ...init.params, rootPath: root, rootUri: toGodotUri(project), workspaceFolders: [{ uri: toGodotUri(project), name: path.basename(project) }] },
    });
    mode = "relay";
    queued.splice(0).forEach(sendToGodot);
  };

  const fromClient = new LspFramer((msg) => {
    if (msg.method === "exit") exitRequested = true;
    switch (mode) {
      case "waiting":
        if (msg.method === "initialize") void start(msg);
        else queued.push(msg);
        break;
      case "connecting":
        queued.push(msg);
        break;
      case "relay":
        sendToGodot(msg);
        if (msg.method === "exit") setTimeout(() => quit(0), 500).unref();
        break;
      case "empty":
        answerEmpty(msg);
        break;
    }
  });
  process.stdin.on("data", (chunk: Buffer) => {
    try {
      fromClient.push(chunk);
    } catch (e) {
      log(`invalid data from the client: ${(e as Error).message}`);
      quit(1);
    }
  });
  process.stdin.on("end", () => quit(0));
  process.on("SIGINT", () => quit(0));
  process.on("SIGTERM", () => quit(0));
}

const SKIP_DIRS = new Set(["node_modules", ".git", ".godot", ".import", "dist", "build", ".venv"]);

function isProject(dir: string): boolean {
  return existsSync(path.join(dir, "project.godot"));
}

/** Godot projects up to `depth` levels below `dir`. */
function projectsBelow(dir: string, depth: number, out: string[] = []): string[] {
  if (depth < 0 || out.length > 20) return out;
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of entries.sort()) {
    if (SKIP_DIRS.has(name) || name.startsWith(".")) continue;
    const sub = path.join(dir, name);
    try {
      if (!statSync(sub).isDirectory()) continue;
    } catch {
      continue;
    }
    if (isProject(sub)) out.push(sub);
    else projectsBelow(sub, depth - 1, out);
  }
  return out;
}

/**
 * Godot project of the client's workspace: GODOT_PROJECT_PATH; else the workspace folder or one of its
 * parents; else a project inside it (several: the one open in an editor, else the first by name).
 */
export function findProject(params: { rootPath?: string | null; rootUri?: string | null; workspaceFolders?: { uri: string }[] | null }): string | undefined {
  if (process.env.GODOT_PROJECT_PATH && isProject(process.env.GODOT_PROJECT_PATH)) return path.resolve(process.env.GODOT_PROJECT_PATH);
  const roots: string[] = [];
  for (const f of params.workspaceFolders ?? []) if (f?.uri) roots.push(fromUri(f.uri));
  if (params.rootUri) roots.push(fromUri(params.rootUri));
  if (params.rootPath) roots.push(path.resolve(params.rootPath));
  roots.push(process.cwd());
  for (const root of roots) {
    for (let dir = root; ; dir = path.dirname(dir)) {
      if (isProject(dir)) return dir;
      if (path.dirname(dir) === dir) break;
    }
  }
  for (const root of roots) {
    // Not below a drive root or the home folder: that would be a scan of the whole disk, and a random pick.
    if (path.dirname(root) === root || samePath(root, os.homedir())) continue;
    const found = projectsBelow(root, 3);
    if (found.length === 0) continue;
    const open = listEditors();
    return found.find((p) => open.some((e) => samePath(e.project_path, p))) ?? found[0];
  }
  return undefined;
}
