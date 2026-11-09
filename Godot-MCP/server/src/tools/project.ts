import { z } from "zod";
import { bridgeTool, type Ctx } from "./common.js";

export function registerProjectTools(ctx: Ctx): void {
  bridgeTool(
    ctx,
    "get_editor_state",
    "Returns the Godot version, project name/path, main scene, open scenes, edited scene, selected nodes and whether the game is running.",
    {},
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "list_files",
    "Lists files in the project (res://), skipping hidden folders such as .godot.",
    {
      path: z.string().default("res://").describe("Folder to list."),
      recursive: z.boolean().default(true),
      extensions: z.array(z.string()).optional().describe('Only these extensions, e.g. ["tscn", "gd"].'),
    },
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "search_classes",
    "Searches Godot classes (built-in and global script classes) by name, optionally restricted to subclasses of a base class.",
    {
      query: z.string().default("").describe("Case-insensitive substring of the class name."),
      base_class: z.string().optional().describe('Only classes inheriting from this, e.g. "Node2D" or "Resource".'),
      limit: z.number().int().min(1).max(500).default(100),
    },
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "get_class_info",
    "Describes a Godot class: parent chain, properties (with types), methods and signals defined on it.",
    {
      class_name: z.string(),
      include_inherited: z.boolean().default(false).describe("Also list members inherited from parent classes."),
    },
    { readOnly: true },
  );

  bridgeTool(ctx, "run_project", "Runs the project's main scene from the editor (like F5).", {});
  bridgeTool(
    ctx,
    "run_current_scene",
    "Runs the scene currently edited (like F6). With `path`, runs that scene instead.",
    { path: z.string().optional().describe("Optional res:// scene path to run.") },
  );
  bridgeTool(ctx, "stop_project", "Stops the game launched from the editor.", {});

  bridgeTool(
    ctx,
    "get_editor_log",
    "Returns recent messages and errors printed in the editor process (script errors, push_error, print from @tool scripts). " +
      "Requires Godot 4.5+. Output of a game launched with run_project is NOT included; use run_and_capture to get game output.",
    {
      max_lines: z.number().int().min(1).max(2000).default(200),
      errors_only: z.boolean().default(false),
      clear: z.boolean().default(false).describe("Clear the buffer after reading."),
    },
    { readOnly: true },
  );
}
