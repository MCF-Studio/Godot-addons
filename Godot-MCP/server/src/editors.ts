import { existsSync, readdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * Session file written by the editor addon (ws_server.gd) for each running editor:
 * <user config dir>/Godot/godot_mcp/editor-<port>.json. Only this user can read it.
 */
export interface EditorSession {
  port: number;
  token: string;
  pid: number;
  project_path: string;
  godot_executable?: string;
  godot_version?: string;
  lsp_host?: string;
  lsp_port?: number;
  started_at?: number;
  file: string;
}

/** Same folder as OS.get_config_dir() + "/Godot/godot_mcp" on the Godot side. */
export function sessionDir(): string {
  let base: string;
  if (process.platform === "win32") base = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
  else if (process.platform === "darwin") base = path.join(os.homedir(), "Library", "Application Support");
  else base = process.env.XDG_CONFIG_HOME && path.isAbsolute(process.env.XDG_CONFIG_HOME) ? process.env.XDG_CONFIG_HOME : path.join(os.homedir(), ".config");
  return path.join(base, "Godot", "godot_mcp");
}

/** Normalized form for comparing paths: absolute, forward slashes, no trailing slash, lower case on Windows. */
export function pathKey(p: string): string {
  const abs = path.resolve(p).replace(/\\/g, "/").replace(/\/+$/, "");
  return process.platform === "win32" ? abs.toLowerCase() : abs;
}

export function samePath(a: string, b: string): boolean {
  return pathKey(a) === pathKey(b);
}

function isAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM"; // exists, owned by someone else
  }
}

/** Running editors, most recently started first. Files left behind by a crashed editor are skipped. */
export function listEditors(dir = sessionDir()): EditorSession[] {
  if (!existsSync(dir)) return [];
  const out: EditorSession[] = [];
  for (const name of readdirSync(dir)) {
    if (!/^editor-\d+\.json$/.test(name)) continue;
    const file = path.join(dir, name);
    try {
      const data = JSON.parse(readFileSync(file, "utf8"));
      if (typeof data?.port !== "number" || typeof data?.token !== "string" || typeof data?.project_path !== "string") continue;
      if (!isAlive(data.pid)) continue;
      out.push({ ...data, file });
    } catch {
      /* being written, or not ours */
    }
  }
  return out.sort((a, b) => (b.started_at ?? 0) - (a.started_at ?? 0));
}

export function editorOnPort(port: number): EditorSession | undefined {
  return listEditors().find((e) => e.port === port);
}

export function editorForProject(projectDir: string): EditorSession | undefined {
  return listEditors().find((e) => samePath(e.project_path, projectDir));
}
