#!/usr/bin/env node
// Assemble les livrables à partir des dossiers des addons (aucun code n'est dupliqué dans ce dossier) :
//   dist/mcf-todo/   MCF Todo seul
//   dist/godot-mcp/  Godot MCP seul (addon + serveur MCP compilé)
//   dist/bundle/     les deux ensemble, tels que le chat et la todo se voient
// Avant d'assembler, vérifie la cohérence entre addons (voir les contrôles ci-dessous) et s'arrête au moindre écart.
// Usage : node build.mjs        (le serveur doit être compilé : cd ../Godot-MCP/server && npm ci && npm run build)
// Les .zip se fabriquent à partir de dist/ (étape de mise en ligne).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const dist = path.join(here, "dist");

const todo = { dir: path.join(repo, "MCF-Todo"), addon: "mcf_todo" };
const mcp = { dir: path.join(repo, "Godot-MCP"), addon: "godot_mcp" };
const addonDir = (a) => path.join(a.dir, "addons", a.addon);

/** Fichiers présents à l'identique dans les deux addons (chaque addon doit rester autonome). */
const SHARED = ["dock_host.gd", "ui/auto_text_edit.gd", "ui/text_links.gd"];

const problems = [];

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

// 1. Les fichiers partagés ne doivent pas avoir divergé.
for (const rel of SHARED) {
  const a = path.join(addonDir(todo), rel);
  const b = path.join(addonDir(mcp), rel);
  if (!fs.existsSync(a) || !fs.existsSync(b)) problems.push(`fichier partagé absent : ${rel}`);
  else if (!fs.readFileSync(a).equals(fs.readFileSync(b))) problems.push(`fichier partagé différent entre les deux addons : ${rel}`);
}

// 2. Pas d'UID Godot en double : deux addons installés dans le même projet se marcheraient dessus.
const seen = new Map();
for (const a of [todo, mcp]) {
  for (const file of walk(addonDir(a)).filter((f) => f.endsWith(".uid"))) {
    const uid = fs.readFileSync(file, "utf8").trim();
    const label = `${a.addon}/${path.relative(addonDir(a), file)}`;
    if (seen.has(uid)) problems.push(`UID en double ${uid} : ${seen.get(uid)} et ${label}`);
    else seen.set(uid, label);
  }
}

// 3. Aucun .gd sans .uid (Godot 4.4+ les attend dans le dépôt) ni .uid orphelin.
for (const a of [todo, mcp]) {
  for (const file of walk(addonDir(a))) {
    if (file.endsWith(".gd") && !fs.existsSync(file + ".uid")) problems.push(`.uid manquant : ${a.addon}/${path.relative(addonDir(a), file)}`);
    if (file.endsWith(".gd.uid") && !fs.existsSync(file.slice(0, -4))) problems.push(`.uid orphelin : ${a.addon}/${path.relative(addonDir(a), file)}`);
  }
}

// 4. Les deux addons doivent avoir des plugin.cfg distincts.
const cfgName = (a) => /^name="(.*)"$/m.exec(fs.readFileSync(path.join(addonDir(a), "plugin.cfg"), "utf8"))?.[1];
if (cfgName(todo) === cfgName(mcp)) problems.push("les deux plugin.cfg portent le même nom");

// 5. Le serveur MCP doit être compilé.
const serverDist = path.join(mcp.dir, "server", "dist", "index.js");
if (!fs.existsSync(serverDist)) problems.push("serveur MCP non compilé : cd ../Godot-MCP/server && npm ci && npm run build");

if (problems.length) {
  console.error("Assemblage annulé :\n" + problems.map((p) => "  - " + p).join("\n"));
  process.exit(1);
}

// --- Assemblage ---------------------------------------------------------------
fs.rmSync(dist, { recursive: true, force: true });
const copy = (from, to) => fs.cpSync(from, to, { recursive: true });
const serverFiles = (dest) => {
  copy(path.join(mcp.dir, "server", "dist"), path.join(dest, "server", "dist"));
  for (const f of ["package.json", "package-lock.json"]) copy(path.join(mcp.dir, "server", f), path.join(dest, "server", f));
};

const out = {
  "mcf-todo": (d) => {
    copy(addonDir(todo), path.join(d, "addons", todo.addon));
    copy(path.join(todo.dir, "README.md"), path.join(d, "README.md"));
  },
  "godot-mcp": (d) => {
    copy(addonDir(mcp), path.join(d, "addons", mcp.addon));
    serverFiles(d);
    copy(path.join(mcp.dir, "README.md"), path.join(d, "README.md"));
  },
  bundle: (d) => {
    copy(addonDir(todo), path.join(d, "addons", todo.addon));
    copy(addonDir(mcp), path.join(d, "addons", mcp.addon));
    serverFiles(d);
    copy(path.join(here, "README.md"), path.join(d, "README.md"));
    copy(path.join(todo.dir, "README.md"), path.join(d, "docs", "MCF-Todo.md"));
    copy(path.join(mcp.dir, "README.md"), path.join(d, "docs", "Godot-MCP.md"));
  },
};

for (const [name, build] of Object.entries(out)) {
  const d = path.join(dist, name);
  build(d);
  console.log(`dist/${name}/  ${walk(d).length} fichiers`);
}
console.log("OK : fichiers partagés identiques, UID uniques, serveur compilé.");
