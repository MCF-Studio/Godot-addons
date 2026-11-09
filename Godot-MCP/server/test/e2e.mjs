// End-to-end smoke test: spawns the MCP server over stdio and drives a running Godot editor.
// Usage: node test/e2e.mjs   (editor must be open on test_project with the plugin enabled)
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectPath = path.resolve(here, "../../test_project");

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.resolve(here, "../dist/index.js")],
  env: { ...process.env, GODOT_PROJECT_PATH: projectPath },
  stderr: "inherit",
});
const client = new Client({ name: "e2e", version: "0.0.0" });
await client.connect(transport);

let failures = 0;
function check(cond, label) {
  if (!cond) failures++;
  console.log(`${cond ? "PASS" : "FAIL"} check: ${label}`);
}
async function call(name, args = {}, { expectError = false } = {}) {
  const res = await client.callTool({ name, arguments: args });
  const text = res.content?.[0]?.text ?? "";
  const okay = expectError ? res.isError : !res.isError;
  if (!okay) failures++;
  console.log(`${okay ? "PASS" : "FAIL"} ${name} ${JSON.stringify(args)}\n  ${text.slice(0, 400).replace(/\n/g, "\n  ")}`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

const { tools } = await client.listTools();
console.log(`${tools.length} tools: ${tools.map((t) => t.name).join(", ")}\n`);

await call("godot_version");
await call("get_editor_state");
await call("create_scene", { path: "res://generated/e2e.tscn", root_type: "Node2D" });
await call("add_node", { type: "Sprite2D", name: "Hero", properties: { position: [100, 50], modulate: "#ff8800" } });
await call("add_node", { type: "Node2D", name: "Group" });
await call("set_node_properties", { node_path: "Hero", properties: { rotation_degrees: 45, scale: { x: 2, y: 2 } } });
await call("get_node_properties", { node_path: "Hero", non_default_only: true });
await call("reparent_node", { node_path: "Hero", new_parent_path: "Group" });
await call("rename_node", { node_path: "Group/Hero", new_name: "Player" });
await call("create_script", {
  path: "res://generated/player.gd",
  content: 'extends Sprite2D\n\n\nfunc _ready() -> void:\n\tprint("player ready at ", position)\n',
  attach_to: "Group/Player",
});
await call("read_script", { path: "res://generated/player.gd" });
await call("instantiate_scene", { scene_path: "res://main.tscn", name: "MainInstance" });
await call("get_scene_tree");
await call("save_scene");
await call("delete_node", { node_path: "MainInstance" });
const treeHas = async (name) => JSON.stringify(await call("get_scene_tree")).includes(`"name":"${name}"`);
await call("undo");
check(await treeHas("MainInstance"), "undo restores the deleted node");
await call("redo");
check(!(await treeHas("MainInstance")), "redo deletes it again");
await call("reparent_node", { node_path: "Group/Player", new_parent_path: "." });
await call("undo");
check(await treeHas("Player") && JSON.stringify(await call("get_scene_tree")).includes("Group/Player"), "undo reverts reparent");
await call("search_classes", { query: "body2d", base_class: "Node2D" });
await call("get_class_info", { class_name: "Sprite2D" });
await call("list_files", { extensions: ["tscn", "gd"] });
await call("get_editor_log", { max_lines: 5 });

// Error paths
await call("add_node", { type: "NotAClass" }, { expectError: true });
await call("delete_node", { node_path: "Nope" }, { expectError: true });

// CLI tools
await call("create_script", { path: "res://generated/broken.gd", content: "extends Node\nfunc _ready(:\n" });
await call("check_script", { script: "res://generated/broken.gd" }, { expectError: false });
await call("check_script", { script: "res://generated/player.gd" });
await call("run_and_capture", { scene: "res://generated/e2e.tscn", quit_after_frames: 5, timeout_sec: 30 });

await client.close();
console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL PASSED");
process.exit(failures ? 1 : 0);
