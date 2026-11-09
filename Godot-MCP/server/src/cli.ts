import { spawn, spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import path from "node:path";

export interface RunResult {
  exitCode: number | null;
  timedOut: boolean;
  durationMs: number;
  stdout: string;
  stderr: string;
}

export interface RunOptions {
  cwd?: string;
  timeoutMs: number;
}

const MAX_OUTPUT_CHARS = 100_000;

/** Keeps only the tail of a stream once it grows past the limit. */
class TailBuffer {
  private text = "";
  private truncated = false;

  push(chunk: Buffer): void {
    this.text += chunk.toString("utf8");
    if (this.text.length > MAX_OUTPUT_CHARS * 2) {
      this.text = this.text.slice(-MAX_OUTPUT_CHARS);
      this.truncated = true;
    }
  }

  toString(): string {
    const t = this.text.length > MAX_OUTPUT_CHARS ? this.text.slice(-MAX_OUTPUT_CHARS) : this.text;
    return this.truncated || this.text.length > MAX_OUTPUT_CHARS ? `[...truncated...]\n${t}` : t;
  }
}

/** Wraps the Godot executable for headless / command-line operations. */
export class GodotCli {
  private cached?: string;

  /**
   * GODOT_PATH (file) or `godot` on PATH. On Windows, prefers the sibling
   * `*_console.exe` so stdout/stderr are actually captured.
   */
  executable(): string {
    if (this.cached) return this.cached;
    let exe = process.env.GODOT_PATH?.trim() || "godot";
    if (process.platform === "win32" && /\.exe$/i.test(exe) && !/_console\.exe$/i.test(exe)) {
      const consoleExe = exe.replace(/\.exe$/i, "_console.exe");
      if (existsSync(consoleExe)) exe = consoleExe;
    }
    this.cached = exe;
    return exe;
  }

  run(args: string[], opts: RunOptions): Promise<RunResult> {
    const exe = this.executable();
    const started = Date.now();
    return new Promise((resolve, reject) => {
      const child = spawn(exe, args, { cwd: opts.cwd, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
      const out = new TailBuffer();
      const err = new TailBuffer();
      let timedOut = false;

      child.stdout.on("data", (c: Buffer) => out.push(c));
      child.stderr.on("data", (c: Buffer) => err.push(c));

      const timer = setTimeout(() => {
        timedOut = true;
        killTree(child.pid);
      }, opts.timeoutMs);

      child.on("error", (e: NodeJS.ErrnoException) => {
        clearTimeout(timer);
        if (e.code === "ENOENT") {
          reject(new Error(`Godot executable not found ('${exe}'). Set the GODOT_PATH environment variable to your Godot 4 executable.`));
        } else reject(e);
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        resolve({ exitCode: code, timedOut, durationMs: Date.now() - started, stdout: out.toString(), stderr: err.toString() });
      });
    });
  }
}

/** The Windows console wrapper spawns the real Godot process, so the whole tree must go. */
function killTree(pid: number | undefined): void {
  if (!pid) return;
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], { windowsHide: true });
  } else {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      /* already exited */
    }
  }
}

/** Throws unless `dir` is a directory containing project.godot. Returns the absolute path. */
export function assertProjectDir(dir: string): string {
  const abs = path.resolve(dir);
  if (!existsSync(abs) || !statSync(abs).isDirectory()) throw new Error(`Project directory does not exist: ${abs}`);
  if (!existsSync(path.join(abs, "project.godot"))) throw new Error(`No project.godot found in ${abs}`);
  return abs;
}

/** Maps res://foo/bar.gd to an absolute path inside the project, refusing to escape it. */
export function resToFs(projectDir: string, resPath: string): string {
  const rel = resPath.startsWith("res://") ? resPath.slice("res://".length) : resPath;
  const abs = path.resolve(projectDir, rel);
  const root = path.resolve(projectDir);
  if (abs !== root && !abs.startsWith(root + path.sep)) throw new Error(`Path escapes the project: ${resPath}`);
  return abs;
}
