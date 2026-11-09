import { z } from "zod";
import { bridgeTool, jsonValue, type Ctx } from "./common.js";

const nodePath = z.string().describe('Path of the node relative to the edited scene root. "." is the root itself, e.g. "Player/Sprite2D".');

export function registerSceneTools(ctx: Ctx): void {
  // --- Scenes ---
  bridgeTool(
    ctx,
    "get_scene_tree",
    "Returns the node tree of the scene currently edited in the Godot editor (name, type, path, script, instanced scene, children).",
    { max_depth: z.number().int().min(0).optional().describe("Limit recursion depth (default: unlimited).") },
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "open_scene",
    "Opens a scene file in the editor and makes it the edited scene.",
    { path: z.string().describe('Scene path, e.g. "res://scenes/main.tscn".') },
  );

  bridgeTool(
    ctx,
    "create_scene",
    "Creates a new scene file with a single root node, saves it and (by default) opens it in the editor.",
    {
      path: z.string().describe('Destination, e.g. "res://scenes/level.tscn". Parent folders are created.'),
      root_type: z.string().default("Node2D").describe("Class of the root node (Node2D, Node3D, Control, CharacterBody2D...)."),
      root_name: z.string().optional().describe("Root node name (default: derived from the file name)."),
      open: z.boolean().default(true).describe("Open the scene in the editor after creating it."),
    },
  );

  bridgeTool(
    ctx,
    "save_scene",
    "Saves the edited scene. With `path`, saves it under that path instead (Save As).",
    { path: z.string().optional().describe("Optional res:// path for Save As.") },
  );

  bridgeTool(
    ctx,
    "instantiate_scene",
    "Instances a PackedScene (.tscn) as a child node in the edited scene. Undoable with Ctrl+Z.",
    {
      scene_path: z.string().describe("res:// path of the scene to instance."),
      parent_path: nodePath.default("."),
      name: z.string().optional().describe("Name for the new instance."),
    },
  );

  bridgeTool(ctx, "undo", "Undoes the last action in the edited scene (same as Ctrl+Z), including actions made by these tools.", {});
  bridgeTool(ctx, "redo", "Redoes the last undone action in the edited scene (same as Ctrl+Shift+Z).", {});

  // --- Nodes ---
  bridgeTool(
    ctx,
    "add_node",
    "Adds a new node to the edited scene. Undoable with Ctrl+Z.",
    {
      type: z.string().describe("Godot class name, e.g. Sprite2D, CollisionShape2D, Label, MeshInstance3D."),
      parent_path: nodePath.default("."),
      name: z.string().optional().describe("Node name (default: the class name)."),
      properties: z.record(z.string(), jsonValue).optional().describe("Initial property values, e.g. {\"position\": [100, 50]}."),
    },
  );

  bridgeTool(ctx, "delete_node", "Deletes a node (and its children) from the edited scene. Undoable with Ctrl+Z.", { node_path: nodePath }, { destructive: true });

  bridgeTool(ctx, "rename_node", "Renames a node in the edited scene. Undoable.", { node_path: nodePath, new_name: z.string() });

  bridgeTool(
    ctx,
    "reparent_node",
    "Moves a node under another parent, keeping its global transform. Undoable.",
    { node_path: nodePath, new_parent_path: nodePath },
  );

  bridgeTool(
    ctx,
    "get_node_properties",
    "Lists the editor-visible properties of a node with their current values and types.",
    {
      node_path: nodePath,
      filter: z.string().optional().describe("Only properties whose name contains this substring."),
      non_default_only: z.boolean().default(false).describe("Only properties that differ from the class default."),
    },
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "set_node_properties",
    "Sets one or more properties on a node in the edited scene, in a single undoable action. Values are converted to the property's type.",
    {
      node_path: nodePath,
      properties: z.record(z.string(), jsonValue).describe('Map of property name to value, e.g. {"position": {"x": 10, "y": 20}, "modulate": "#ff0000"}.'),
    },
  );
}
