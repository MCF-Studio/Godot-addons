import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { resToFs } from "../cli.js";
import { pathKey } from "../editors.js";
import type { Diagnostic, GodotLspClient, Position } from "../lsp/client.js";
import type { LspEndpoint } from "../lsp/locate.js";
import { fromUri } from "../lsp/protocol.js";
import { guard, projectPathField, resolveProject, type Ctx } from "./common.js";

const SEVERITY = ["", "error", "warning", "info", "hint"];
const SYMBOL_KIND = ["", "file", "module", "namespace", "package", "class", "method", "property", "field", "constructor", "enum", "interface", "function", "variable", "constant", "string", "number", "boolean", "array", "object", "key", "null", "enum_member", "struct", "event", "operator", "type_parameter"];
const MAX_PROJECT_FILES = 300;

export interface FormattedDiagnostic {
  line: number; // 1-based
  column: number; // 1-based
  severity: string;
  message: string;
}

export function formatDiagnostics(list: Diagnostic[]): FormattedDiagnostic[] {
  return list
    .map((d) => ({ line: d.range.start.line + 1, column: d.range.start.character + 1, severity: SEVERITY[d.severity ?? 1] ?? "error", message: d.message }))
    .sort((a, b) => a.line - b.line || a.column - b.column);
}

/** res:// path when inside the project, else the absolute path. */
function displayPath(projectDir: string, fsPath: string): string {
  const root = pathKey(projectDir) + "/";
  const key = pathKey(fsPath);
  return key.startsWith(root) ? "res://" + path.resolve(fsPath).replace(/\\/g, "/").slice(root.length) : fsPath.replace(/\\/g, "/");
}

/** Accepts res://x.gd, a path relative to the project, or an absolute path inside it. */
function scriptFile(projectDir: string, p: string): string {
  const abs = p.startsWith("res://") || !path.isAbsolute(p) ? resToFs(projectDir, p) : resToFs(projectDir, path.relative(projectDir, p));
  if (!existsSync(abs)) throw new Error(`File not found: ${p}`);
  return abs;
}

function gdFiles(dir: string, includeAddons: boolean, out: string[] = [], root = dir): string[] {
  for (const name of readdirSync(dir).sort()) {
    if (name.startsWith(".")) continue;
    const full = path.join(dir, name);
    let isDir = false;
    try {
      isDir = statSync(full).isDirectory();
    } catch {
      continue;
    }
    if (isDir) {
      if (!includeAddons && dir === root && name === "addons") continue;
      if (existsSync(path.join(full, ".gdignore"))) continue;
      gdFiles(full, includeAddons, out, root);
    } else if (name.endsWith(".gd")) out.push(full);
  }
  return out;
}

const isWordChar = (c: string | undefined) => !!c && /[A-Za-z0-9_]/.test(c);

/** Finds `symbol` as a whole word on `line` (1-based), or on the first line containing it. Returns an LSP position. */
export function locateSymbol(text: string, symbol: string, line?: number): Position {
  const lines = text.split(/\r?\n/);
  const search = (i: number) => {
    const l = lines[i] ?? "";
    for (let at = l.indexOf(symbol); at >= 0; at = l.indexOf(symbol, at + 1)) {
      if (!isWordChar(l[at - 1]) && !isWordChar(l[at + symbol.length])) return at;
    }
    return -1;
  };
  if (line !== undefined) {
    const at = search(line - 1);
    if (at < 0) throw new Error(`'${symbol}' is not on line ${line}: ${(lines[line - 1] ?? "(no such line)").trim()}`);
    return { line: line - 1, character: at };
  }
  for (let i = 0; i < lines.length; i++) {
    const at = search(i);
    if (at >= 0) return { line: i, character: at };
  }
  throw new Error(`'${symbol}' does not appear in this file.`);
}

function hoverText(contents: unknown): string {
  if (!contents) return "";
  if (typeof contents === "string") return contents;
  if (Array.isArray(contents)) return contents.map(hoverText).filter(Boolean).join("\n\n");
  const c = contents as { value?: string };
  return typeof c.value === "string" ? c.value : "";
}

export function registerLspTools(ctx: Ctx): void {
  const { server } = ctx;

  /** Project + LSP client + absolute file for a tool call. */
  async function open(projectPath: string | undefined): Promise<{ project: string; client: GodotLspClient; endpoint: LspEndpoint }> {
    const project = await resolveProject(ctx, projectPath);
    const { client, endpoint } = await ctx.lsp.client(project);
    return { project, client, endpoint };
  }

  const fileLine = (file: string, line0: number) => {
    try {
      return readFileSync(file, "utf8").split(/\r?\n/)[line0]?.trim() ?? "";
    } catch {
      return "";
    }
  };

  const locations = (project: string, result: unknown) => {
    const list = Array.isArray(result) ? result : result ? [result] : [];
    return list
      .map((loc: any) => {
        const uri = loc.uri ?? loc.targetUri;
        const range = loc.range ?? loc.targetSelectionRange ?? loc.targetRange;
        if (!uri || !range) return undefined;
        const file = fromUri(uri);
        return { path: displayPath(project, file), line: range.start.line + 1, column: range.start.character + 1, code: fileLine(file, range.start.line) };
      })
      .filter(Boolean);
  };

  const positionFields = {
    path: z.string().describe('Script, e.g. "res://player/player.gd".'),
    symbol: z.string().optional().describe('Identifier to look up, e.g. "take_damage" (found as a whole word on `line`, or its first occurrence in the file).'),
    line: z.number().int().min(1).optional().describe("1-based line. Required with `column`; optional with `symbol`."),
    column: z.number().int().min(1).optional().describe("1-based column of a character inside the identifier (instead of `symbol`)."),
    project_path: projectPathField,
  };

  const position = (text: string, a: { symbol?: string; line?: number; column?: number }): Position => {
    if (a.symbol) return locateSymbol(text, a.symbol, a.line);
    if (a.line !== undefined && a.column !== undefined) return { line: a.line - 1, character: a.column - 1 };
    throw new Error("Give `symbol` (optionally with `line`), or `line` and `column`.");
  };

  server.registerTool(
    "gdscript_diagnostics",
    {
      description:
        "Errors and warnings of GDScript files, from Godot's own language server (the same analysis as the script editor, with the whole project's classes and autoloads known). " +
        "Much faster than check_script. Without `paths`, checks every .gd file of the project (addons excluded unless include_addons). " +
        "Uses the editor that has the project open, else starts a headless editor once (a few seconds).",
      inputSchema: {
        paths: z.array(z.string()).max(MAX_PROJECT_FILES).optional().describe('Scripts to check, e.g. ["res://player.gd"]. Omit for the whole project.'),
        include_addons: z.boolean().default(false).describe("With no `paths`: also check res://addons/."),
        project_path: projectPathField,
      },
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const { project, client, endpoint } = await open(a.project_path);
        let files = a.paths?.length ? a.paths.map((p) => scriptFile(project, p)) : gdFiles(project, a.include_addons);
        const truncated = files.length > MAX_PROJECT_FILES;
        files = files.slice(0, MAX_PROJECT_FILES);
        const results = [];
        let errors = 0;
        let warnings = 0;
        for (const file of files) {
          const diagnostics = formatDiagnostics(await client.diagnostics(file));
          errors += diagnostics.filter((d) => d.severity === "error").length;
          warnings += diagnostics.filter((d) => d.severity === "warning").length;
          // Whole-project runs list only the files with something to say.
          if (diagnostics.length || a.paths?.length) results.push({ path: displayPath(project, file), diagnostics });
        }
        return {
          ok: errors === 0,
          checked: files.length,
          errors,
          warnings,
          files: results,
          ...(truncated ? { truncated: `only the first ${MAX_PROJECT_FILES} files were checked` } : {}),
          language_server: endpoint.source,
        };
      }),
  );

  server.registerTool(
    "gdscript_symbols",
    {
      description: "Outline of a GDScript file from Godot's language server: class, signals, variables, constants, functions with their signatures and lines.",
      inputSchema: { path: positionFields.path, project_path: projectPathField },
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const { project, client } = await open(a.project_path);
        const file = scriptFile(project, a.path);
        const result = await client.withDocument(file, (uri) => client.request<any[]>("textDocument/documentSymbol", { textDocument: { uri } }));
        const out: { name: string; kind: string; detail?: string; line: number; parent?: string }[] = [];
        // Godot returns one top-level symbol for the script's class; its members are its children.
        const walk = (items: any[] | null | undefined, parent: string | undefined, depth: number) => {
          for (const s of items ?? []) {
            const range = s.selectionRange ?? s.range ?? s.location?.range;
            out.push({ name: s.name, kind: SYMBOL_KIND[s.kind] ?? String(s.kind), ...(s.detail ? { detail: s.detail } : {}), line: (range?.start.line ?? 0) + 1, ...(parent ? { parent } : {}) });
            const scriptClass = depth === 0 && s.kind === 5;
            walk(s.children, scriptClass ? undefined : parent ? `${parent}.${s.name}` : s.name, depth + 1);
          }
        };
        walk(result, undefined, 0);
        return { path: displayPath(project, file), symbols: out };
      }),
  );

  server.registerTool(
    "gdscript_definition",
    {
      description: "Where a GDScript identifier (function, variable, class, signal…) is declared, from Godot's language server. Works across files.",
      inputSchema: positionFields,
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const { project, client } = await open(a.project_path);
        const file = scriptFile(project, a.path);
        return client.withDocument(file, async (uri, text) => {
          const pos = position(text, a);
          const result = await client.request("textDocument/definition", { textDocument: { uri }, position: pos });
          const found = locations(project, result);
          return { at: { line: pos.line + 1, column: pos.character + 1 }, definitions: found, ...(found.length ? {} : { note: "No project definition (built-in Godot API? use gdscript_hover or get_class_info)." }) };
        });
      }),
  );

  server.registerTool(
    "gdscript_references",
    {
      description: "Every use of a GDScript identifier across the project, from Godot's language server. Use before renaming or changing a function's signature.",
      inputSchema: { ...positionFields, include_declaration: z.boolean().default(true) },
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const { project, client } = await open(a.project_path);
        const file = scriptFile(project, a.path);
        return client.withDocument(file, async (uri, text) => {
          const pos = position(text, a);
          const result = await client.request("textDocument/references", { textDocument: { uri }, position: pos, context: { includeDeclaration: a.include_declaration } });
          const refs = locations(project, result);
          return { at: { line: pos.line + 1, column: pos.character + 1 }, count: refs.length, references: refs.slice(0, 500) };
        });
      }),
  );

  server.registerTool(
    "gdscript_hover",
    {
      description: "Type, signature and documentation of a GDScript identifier (including Godot's built-in API), as the script editor shows it on hover.",
      inputSchema: positionFields,
      annotations: { readOnlyHint: true },
    },
    async (a) =>
      guard(async () => {
        const { project, client } = await open(a.project_path);
        const file = scriptFile(project, a.path);
        return client.withDocument(file, async (uri, text) => {
          const pos = position(text, a);
          const result = await client.request<{ contents?: unknown } | null>("textDocument/hover", { textDocument: { uri }, position: pos });
          const doc = hoverText(result?.contents).trim();
          return { at: { line: pos.line + 1, column: pos.character + 1 }, documentation: doc || "(nothing known about this position)" };
        });
      }),
  );
}

/**
 * Diagnostics for a file just written, only if a language server is already at hand (never starts a
 * headless editor: create_script must stay fast). undefined = not available.
 */
export async function quickDiagnostics(ctx: Ctx, project: string, fsPath: string): Promise<FormattedDiagnostic[] | undefined> {
  try {
    const { client } = await ctx.lsp.client(project, { spawn: false });
    return formatDiagnostics(await client.diagnostics(fsPath, 5_000));
  } catch {
    return undefined;
  }
}
