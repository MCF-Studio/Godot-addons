import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { BridgeUnavailableError } from "../bridge.js";
import { resToFs } from "../cli.js";
import { bridgeTool, guard, projectPathField, resolveProject, type Ctx } from "./common.js";

export function registerScriptTools(ctx: Ctx): void {
  ctx.server.registerTool(
    "create_script",
    {
      description:
        "Creates or overwrites a GDScript file. With the editor connected, the script is reloaded and can be attached to a node at once; " +
        "otherwise the file is written directly to disk (project_path required).",
      inputSchema: {
        path: z.string().describe('Script path, e.g. "res://scripts/player.gd".'),
        content: z.string().optional().describe("Full source code. If omitted, a minimal template extending base_type is written."),
        base_type: z.string().default("Node").describe("Class extended by the template when content is omitted."),
        attach_to: z.string().optional().describe('Node path in the edited scene to attach the script to (editor only), e.g. "Player".'),
        project_path: projectPathField,
      },
    },
    async (args) =>
      guard(async () => {
        const { project_path, ...params } = args;
        try {
          return await ctx.bridge.call("create_script", params);
        } catch (e) {
          if (!(e instanceof BridgeUnavailableError)) throw e;
          if (params.attach_to) throw e;
          const project = await resolveProject(ctx, project_path);
          const file = resToFs(project, params.path);
          const source = params.content ?? `extends ${params.base_type}\n\n\nfunc _ready() -> void:\n\tpass\n`;
          await mkdir(path.dirname(file), { recursive: true });
          await writeFile(file, source, "utf8");
          return { path: params.path, written_to: file, via: "filesystem (editor not connected)" };
        }
      }),
  );

  ctx.server.registerTool(
    "read_script",
    {
      description: "Returns the source code of a script (or any text file) in the project.",
      inputSchema: { path: z.string().describe('e.g. "res://scripts/player.gd"'), project_path: projectPathField },
      annotations: { readOnlyHint: true },
    },
    async ({ path: resPath, project_path }) =>
      guard(async () => {
        try {
          return await ctx.bridge.call("read_script", { path: resPath });
        } catch (e) {
          if (!(e instanceof BridgeUnavailableError)) throw e;
          const project = await resolveProject(ctx, project_path);
          return { path: resPath, content: await readFile(resToFs(project, resPath), "utf8") };
        }
      }),
  );

  bridgeTool(
    ctx,
    "attach_script",
    "Attaches an existing script to a node of the edited scene (pass an empty script_path to detach). Undoable.",
    {
      node_path: z.string().describe('Node path relative to the scene root, "." for the root.'),
      script_path: z.string().describe("res:// path of the script, or empty string to remove the script."),
    },
  );
}
