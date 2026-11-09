#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { GodotBridge } from "./bridge.js";
import { GodotCli } from "./cli.js";
import { registerCliTools } from "./tools/cli.js";
import type { Ctx } from "./tools/common.js";
import { registerProjectTools } from "./tools/project.js";
import { registerSceneTools } from "./tools/scene.js";
import { registerScriptTools } from "./tools/script.js";

const host = process.env.GODOT_MCP_HOST ?? "127.0.0.1";
const port = Number(process.env.GODOT_MCP_PORT ?? 6505);

const server = new McpServer(
  { name: "godot-mcp", version: "0.1.0" },
  {
    instructions:
      "Controls Godot 4. Editor tools (scenes, nodes, scripts, run) need the Godot editor open with the 'Godot MCP' plugin enabled; " +
      "start with get_editor_state. CLI tools (godot_version, run_and_capture, check_script, export_project) work without the editor. " +
      "Node paths are relative to the edited scene root ('.' = root). Use run_and_capture to read game output and errors.",
  },
);

const ctx: Ctx = {
  server,
  bridge: new GodotBridge(`ws://${host}:${port}`, process.env.GODOT_MCP_TOKEN || undefined),
  cli: new GodotCli(),
};

registerProjectTools(ctx);
registerSceneTools(ctx);
registerScriptTools(ctx);
registerCliTools(ctx);

await server.connect(new StdioServerTransport());
console.error(`[godot-mcp] ready (editor bridge: ws://${host}:${port})`);

const shutdown = () => {
  ctx.bridge.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
