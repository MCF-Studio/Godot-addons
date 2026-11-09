import { z } from "zod";
import { guard, projectPathField, resolveProject, type Ctx } from "./common.js";

export function registerCliTools(ctx: Ctx): void {
  const { server, cli } = ctx;

  server.registerTool(
    "godot_version",
    {
      description: "Returns the version and path of the Godot executable used for CLI tools (GODOT_PATH).",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () =>
      guard(async () => {
        const r = await cli.run(["--version"], { timeoutMs: 15_000 });
        return { executable: cli.executable(), version: r.stdout.trim().split(/\r?\n/).pop(), stderr: r.stderr.trim() || undefined };
      }),
  );

  server.registerTool(
    "run_and_capture",
    {
      description:
        "Runs the project (or one scene) in a separate Godot process and returns its stdout/stderr: print() output, errors, stack traces. " +
        "Works without the editor. The process is killed after timeout_sec, which is normal for games that never quit.",
      inputSchema: {
        project_path: projectPathField,
        scene: z.string().optional().describe("res:// scene to run instead of the main scene."),
        headless: z.boolean().default(true).describe("Run without a window (no rendering). Set false to see the game."),
        timeout_sec: z.number().min(1).max(600).default(10),
        quit_after_frames: z.number().int().min(1).optional().describe("Quit cleanly after N frames (--quit-after)."),
        extra_args: z.array(z.string()).optional().describe("Extra command-line arguments; put user args after \"--\"."),
      },
    },
    async (a) =>
      guard(async () => {
        const project = await resolveProject(ctx, a.project_path);
        const args = ["--path", project];
        if (a.headless) args.push("--headless");
        if (a.quit_after_frames) args.push("--quit-after", String(a.quit_after_frames));
        if (a.scene) args.push(a.scene);
        if (a.extra_args) args.push(...a.extra_args);
        return await cli.run(args, { cwd: project, timeoutMs: a.timeout_sec * 1000 });
      }),
  );

  server.registerTool(
    "check_script",
    {
      description:
        "Parses a GDScript file with Godot and reports syntax/type errors without running the game. Works without the editor.",
      inputSchema: {
        project_path: projectPathField,
        script: z.string().describe('res:// path of the script, e.g. "res://scripts/player.gd".'),
      },
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const project = await resolveProject(ctx, a.project_path);
        const r = await cli.run(["--path", project, "--headless", "--check-only", "--script", a.script], { cwd: project, timeoutMs: 60_000 });
        const output = `${r.stdout}\n${r.stderr}`;
        const hasError = r.exitCode !== 0 || /SCRIPT ERROR|Parse Error|ERROR:/i.test(output);
        return { script: a.script, ok: !hasError, exitCode: r.exitCode, output: output.trim() };
      }),
  );

  server.registerTool(
    "export_project",
    {
      description: "Exports the project with a preset defined in export_presets.cfg (export templates must be installed).",
      inputSchema: {
        project_path: projectPathField,
        preset: z.string().describe('Preset name as shown in the Export dialog, e.g. "Windows Desktop".'),
        output_path: z.string().describe("Absolute output file path, e.g. C:/builds/game.exe."),
        mode: z.enum(["release", "debug", "pack"]).default("release"),
      },
    },
    async (a) =>
      guard(async () => {
        const project = await resolveProject(ctx, a.project_path);
        const flag = { release: "--export-release", debug: "--export-debug", pack: "--export-pack" }[a.mode];
        const r = await cli.run(["--path", project, "--headless", flag, a.preset, a.output_path], { cwd: project, timeoutMs: 15 * 60_000 });
        return { ok: r.exitCode === 0 && !r.timedOut, ...r };
      }),
  );
}
