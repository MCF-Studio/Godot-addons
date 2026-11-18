#!/usr/bin/env node
// Two programs in one file (the addon ships a single bundled file):
//   godot-mcp-server.mjs          MCP server on stdio (default)
//   godot-mcp-server.mjs --lsp    GDScript language server on stdio, relaying to Godot's (for Claude Code plugins)
if (process.argv.includes("--lsp")) {
  const { runLspBridge } = await import("./lsp/proxy.js");
  await runLspBridge();
} else {
  await import("./mcp.js");
}
