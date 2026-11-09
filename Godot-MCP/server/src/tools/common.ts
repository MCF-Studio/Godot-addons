import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { GodotBridge } from "../bridge.js";
import { assertProjectDir, type GodotCli } from "../cli.js";

export interface Ctx {
  server: McpServer;
  bridge: GodotBridge;
  cli: GodotCli;
}

export function ok(data: unknown): CallToolResult {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text", text }] };
}

export function fail(message: string): CallToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

/** Runs `fn` and turns its value or thrown error into a tool result. */
export async function guard(fn: () => Promise<unknown>): Promise<CallToolResult> {
  try {
    return ok(await fn());
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
}

/** Shared zod field for tools that need a project on disk. */
export const projectPathField = z
  .string()
  .optional()
  .describe("Absolute path to the Godot project folder (containing project.godot). Defaults to GODOT_PROJECT_PATH, then to the project open in the editor.");

/** project_path argument -> GODOT_PROJECT_PATH -> project currently open in the editor. */
export async function resolveProject(ctx: Ctx, projectPath?: string): Promise<string> {
  const candidate = projectPath || process.env.GODOT_PROJECT_PATH;
  if (candidate) return assertProjectDir(candidate);
  try {
    const state = await ctx.bridge.call<{ project_path?: string }>("get_editor_state", {}, 3_000);
    if (state?.project_path) return assertProjectDir(state.project_path);
  } catch {
    /* fall through */
  }
  throw new Error("No project specified: pass project_path, set GODOT_PROJECT_PATH, or open the project in the Godot editor with the plugin enabled.");
}

type Shape = z.ZodRawShape;

/**
 * Registers a tool that forwards its arguments unchanged to the editor addon method of the same name.
 */
export function bridgeTool(
  ctx: Ctx,
  name: string,
  description: string,
  inputSchema: Shape,
  opts: { readOnly?: boolean; destructive?: boolean; timeoutMs?: number } = {},
): void {
  ctx.server.registerTool(
    name,
    {
      description,
      inputSchema,
      annotations: { readOnlyHint: opts.readOnly ?? false, destructiveHint: opts.destructive ?? false },
    },
    async (args: Record<string, unknown>) => guard(() => ctx.bridge.call(name, stripUndefined(args), opts.timeoutMs)),
  );
}

function stripUndefined(obj: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

/** Free-form JSON value accepted for Godot property values. */
export const jsonValue = z
  .any()
  .describe(
    'Property value. Vectors: {"x":1,"y":2} or [1,2]. Color: "#ff8800", "red" or [r,g,b,a]. ' +
      'Resources: "res://path.tres". NodePath: "Path/To/Node". Anything else: a Godot literal string, e.g. "Rect2(0, 0, 10, 10)".',
  );
