import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { GodotBridge } from "./bridge.js";
import { GodotCli } from "./cli.js";
import { registerCliTools } from "./tools/cli.js";
import type { Ctx } from "./tools/common.js";
import { registerProjectTools } from "./tools/project.js";
import { registerSceneTools } from "./tools/scene.js";
import { registerScriptTools } from "./tools/script.js";
import { registerTodoTools } from "./tools/todo.js";
import { registerLspTools } from "./tools/lsp.js";
import { LspManager } from "./lsp/locate.js";

const host = process.env.GODOT_MCP_HOST ?? "127.0.0.1";
const port = Number(process.env.GODOT_MCP_PORT ?? 6505);

const server = new McpServer(
  { name: "godot-mcp", version: "0.2.0" },
  {
    instructions:
      "Controls Godot 4. Editor tools (scenes, nodes, scripts, run) need the Godot editor open with the 'Godot MCP' plugin enabled; " +
      "start with get_editor_state. CLI tools (godot_version, run_and_capture, check_script, export_project) work without the editor. " +
      "Node paths are relative to the edited scene root ('.' = root). Use run_and_capture to read game output and errors. " +
      "GDScript: after writing a script, check it with gdscript_diagnostics (Godot's language server: fast, knows the whole project); " +
      "use gdscript_definition / gdscript_references / gdscript_hover / gdscript_symbols to navigate code instead of grepping. " +
      "When the MCF Todo addon is enabled, its Todo dock is shared with the user: todo_list / todo_add / todo_update / todo_remove (set a task to `doing` when you start it and `done` when finished).",
  },
);

const cli = new GodotCli();
const ctx: Ctx = {
  server,
  bridge: new GodotBridge(`ws://${host}:${port}`, process.env.GODOT_MCP_TOKEN || undefined),
  cli,
  // A headless editor started for the language server stops after 10 minutes without queries.
  lsp: new LspManager(cli, { autostart: process.env.GODOT_LSP_AUTOSTART !== "0", idleMs: 10 * 60_000 }),
};

registerProjectTools(ctx);
registerSceneTools(ctx);
registerScriptTools(ctx);
registerTodoTools(ctx);
registerCliTools(ctx);
registerLspTools(ctx);

await server.connect(new StdioServerTransport());
console.error(`[godot-mcp] ready (editor bridge: ws://${host}:${port})`);

const shutdown = () => {
  ctx.bridge.close();
  ctx.lsp.dispose();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
