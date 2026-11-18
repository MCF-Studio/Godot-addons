// End-to-end smoke test: spawns the MCP server over stdio and drives a running Godot editor.
// Usage: node test/e2e.mjs   (editor must be open on test_project with the plugin enabled)
// Env:   E2E_PROJECT       project the editor has open (default: ../../test_project)
//        E2E_EXPECT_TODO=1 the MCF Todo addon is enabled there: test the todo_* tools for real.
//                          Unset: the addon is absent and the tools must say so clearly.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import WebSocket from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectPath = process.env.E2E_PROJECT ? path.resolve(process.env.E2E_PROJECT) : path.resolve(here, "../../test_project");
const expectTodo = process.env.E2E_EXPECT_TODO === "1";

// On teste le serveur tel qu'il est livré : le fichier unique embarqué dans l'addon (npm run build).
const serverFile = path.resolve(here, "../../addons/godot_mcp/server/godot-mcp-server.mjs");
if (!fs.existsSync(serverFile)) {
  console.error("Serveur embarqué introuvable : lance d'abord `npm run build` dans Godot-MCP/server.");
  process.exit(2);
}
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverFile],
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

// Todo list (optional MCF Todo addon)
if (expectTodo) {
  const added = await call("todo_add", { items: ["e2e task A", "e2e task B"], position: "top", status: "open" });
  const [a, b] = added.added ?? [];
  check(a?.index === 0 && b?.index === 1 && a?.text === "e2e task A", "todo_add keeps the given order at the top");
  await call("todo_update", { id: b.id, status: "doing" });
  await call("todo_update", { id: a.id, text: "e2e task A (edited)", position: "bottom" });
  const list = await call("todo_list", { status: "active" });
  const ours = (list.items ?? []).filter((t) => t.text.startsWith("e2e task"));
  check(ours.length === 2 && ours[0].id === b.id && ours[1].text === "e2e task A (edited)", "todo_update changes status, text and position");
  const onDisk = JSON.parse(fs.readFileSync(path.join(projectPath, ".mcf_todo", "todo.json"), "utf8"));
  check(onDisk.items.some((t) => t.id === a.id && t.text === "e2e task A (edited)"), "todo list is saved to res://.mcf_todo/todo.json right away");
  await call("todo_update", { id: "nope", status: "done" }, { expectError: true });
  await call("todo_add", { text: "   " }, { expectError: true });
  const removed = await call("todo_remove", { ids: [a.id, b.id] });
  check(removed.removed === 2, "todo_remove deletes the tasks");
} else {
  for (const [name, args] of [["todo_list", {}], ["todo_add", { text: "x" }], ["todo_update", { id: "x", status: "done" }], ["todo_remove", { id: "x" }]]) {
    const text = await call(name, args, { expectError: true });
    check(String(text).includes("MCF Todo addon is not installed"), `${name} explains that the MCF Todo addon is missing`);
  }
  // Un outil qui échoue "proprement" ne doit rien écrire d'inquiétant dans le journal de l'éditeur.
  const journal = await call("get_editor_log", { max_lines: 100, errors_only: true });
  check(!JSON.stringify(journal).includes("meta' values"), "todo_* sans l'addon n'ajoute aucune erreur moteur au journal de l'éditeur");
}

// Error paths
await call("add_node", { type: "NotAClass" }, { expectError: true });
await call("delete_node", { node_path: "Nope" }, { expectError: true });

// Paths must stay inside the project
await call("read_script", { path: "res://../README.md" }, { expectError: true });
await call("read_script", { path: "C:/Windows/win.ini" }, { expectError: true });
await call("create_scene", { path: "res://../escape.tscn" }, { expectError: true });
await call("list_files", { path: "res://.." }, { expectError: true });

// The WebSocket refuses a client without the token (e.g. a web page opening ws://127.0.0.1)
{
  const port = Number(process.env.GODOT_MCP_PORT ?? 6505);
  const answer = await new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`, { origin: "https://evil.example" });
    ws.on("open", () => ws.send(JSON.stringify({ id: 1, method: "get_editor_state", params: {} })));
    ws.on("message", (d) => resolve(String(d)));
    ws.on("error", (e) => resolve(`error: ${e.message}`));
    setTimeout(() => resolve("timeout"), 5000);
  });
  check(answer.includes("Invalid or missing token") && !answer.includes("project_path"), `a client without the token is refused (${answer.slice(0, 80)})`);
}

// GDScript language server
await call("create_script", {
  path: "res://generated/lsp_probe.gd",
  content: "extends Node\n\n\nfunc helper(x: int) -> int:\n\treturn x * 2\n\n\nfunc _ready() -> void:\n\tprint(helper(3))\n",
});
const okDiag = await call("gdscript_diagnostics", { paths: ["res://generated/lsp_probe.gd", "res://generated/player.gd"] });
check(okDiag.ok === true && okDiag.checked === 2, "gdscript_diagnostics: clean scripts have no error");
const symbols = await call("gdscript_symbols", { path: "res://generated/lsp_probe.gd" });
check(symbols.symbols?.some((s) => s.name === "helper" && s.line === 4) && symbols.symbols?.some((s) => s.name === "_ready"), "gdscript_symbols lists the functions with their lines");
const def = await call("gdscript_definition", { path: "res://generated/lsp_probe.gd", symbol: "helper", line: 9 });
check(def.definitions?.some((d) => d.path === "res://generated/lsp_probe.gd" && d.line === 4), "gdscript_definition finds the declaration");
const refs = await call("gdscript_references", { path: "res://generated/lsp_probe.gd", symbol: "helper" });
check(refs.count >= 2 && refs.references.every((r) => r.path === "res://generated/lsp_probe.gd"), "gdscript_references finds the declaration and the call");
const hover = await call("gdscript_hover", { path: "res://generated/lsp_probe.gd", symbol: "print" });
check(/print/.test(hover.documentation ?? ""), "gdscript_hover documents a built-in function");
await call("gdscript_hover", { path: "res://generated/lsp_probe.gd", symbol: "nope_not_here" }, { expectError: true });

// CLI tools
const broken = await call("create_script", { path: "res://generated/broken.gd", content: "extends Node\nfunc _ready(:\n" });
check(broken.diagnostics?.some((d) => d.severity === "error" && d.line === 2), "create_script returns the language server's errors");
const brokenDiag = await call("gdscript_diagnostics", { paths: ["res://generated/broken.gd"] });
check(brokenDiag.ok === false && brokenDiag.errors > 0, "gdscript_diagnostics reports a syntax error");
const projectDiag = await call("gdscript_diagnostics", {});
check(
  projectDiag.files?.some((f) => f.path === "res://generated/broken.gd") && !projectDiag.files?.some((f) => f.path.startsWith("res://addons/")),
  "gdscript_diagnostics without paths checks the project, addons excluded",
);
await call("check_script", { script: "res://generated/broken.gd" }, { expectError: false });
await call("check_script", { script: "res://generated/player.gd" });
await call("run_and_capture", { scene: "res://generated/e2e.tscn", quit_after_frames: 5, timeout_sec: 30 });

await client.close();

// The stdio bridge Claude Code uses (`--lsp`): the client's workspace is the folder ABOVE the project.
{
  const lsp = startLsp({ env: { ...process.env, GODOT_PROJECT_PATH: "" } });
  lsp.send({ id: 1, method: "initialize", params: { processId: null, rootUri: pathToFileURL(path.dirname(projectPath)).href, capabilities: {} } });
  const init = await lsp.waitFor((m) => m.id === 1);
  check(init?.result?.capabilities?.definitionProvider === true, "--lsp: initialize is relayed to Godot (project found below the workspace)");
  lsp.send({ method: "initialized", params: {} });
  // pathToFileURL gives the percent-encoded form ("file:///I:/..." with %20 etc.), not Godot's own.
  const uri = pathToFileURL(path.join(projectPath, "generated", "lsp_bridge.gd")).href;
  lsp.send({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "gdscript", version: 1, text: "extends Node\nfunc f(:\n" } } });
  const diag = await lsp.waitFor((m) => m.method === "textDocument/publishDiagnostics" && m.params.diagnostics.length > 0);
  check(!!diag, "--lsp: diagnostics come back for an unsaved document");
  check(!lsp.messages.some((m) => m.method?.startsWith("gdscript")), "--lsp: Godot-specific notifications are not forwarded");
  lsp.send({ id: 2, method: "shutdown", params: null });
  await lsp.waitFor((m) => m.id === 2, 5000);
  lsp.send({ method: "exit" });
  const code = await lsp.exited(5000);
  check(code === 0, `--lsp exits cleanly after "exit" (${code})`);

  // No Godot project in the workspace: answer as an empty server instead of crashing (no restart loop).
  const emptyDir = fs.mkdtempSync(path.join(os.tmpdir(), "godot-mcp-e2e-"));
  const empty = startLsp({ cwd: emptyDir, env: { ...process.env, GODOT_PROJECT_PATH: "" } });
  empty.send({ id: 1, method: "initialize", params: { processId: null, rootUri: null, capabilities: {} } });
  const emptyInit = await empty.waitFor((m) => m.id === 1, 5000);
  check(emptyInit && Object.keys(emptyInit.result?.capabilities ?? { x: 1 }).length === 0, "--lsp without a Godot project answers with no capabilities");
  await new Promise((r) => setTimeout(r, 500));
  check(empty.proc.exitCode === null, "--lsp without a Godot project stays up");
  empty.proc.kill();
  await empty.exited(5000); // its working directory cannot be removed while it runs (Windows)
  fs.rmSync(emptyDir, { recursive: true, force: true });
}

function startLsp(options) {
  const proc = spawn(process.execPath, [serverFile, "--lsp"], { stdio: ["pipe", "pipe", "inherit"], ...options });
  const messages = [];
  let buf = Buffer.alloc(0);
  proc.stdout.on("data", (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      const h = buf.indexOf("\r\n\r\n");
      if (h < 0) break;
      const len = Number(/Content-Length: *(\d+)/i.exec(buf.subarray(0, h).toString())[1]);
      if (buf.length < h + 4 + len) break;
      messages.push(JSON.parse(buf.subarray(h + 4, h + 4 + len).toString()));
      buf = buf.subarray(h + 4 + len);
    }
  });
  return {
    proc,
    messages,
    send(m) {
      const b = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...m }));
      proc.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${b.length}\r\n\r\n`), b]));
    },
    async waitFor(pred, ms = 30000) {
      for (const end = Date.now() + ms; Date.now() < end; await new Promise((r) => setTimeout(r, 100))) {
        const m = messages.find(pred);
        if (m) return m;
      }
      return undefined;
    },
    exited(ms) {
      return new Promise((r) => {
        if (proc.exitCode !== null) return r(proc.exitCode);
        proc.on("exit", (c) => r(c));
        setTimeout(() => r("still running"), ms);
      });
    },
  };
}
console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL PASSED");
process.exit(failures ? 1 : 0);
