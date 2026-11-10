#!/usr/bin/env node
// Embarque le serveur MCP et ses dépendances dans UN seul fichier, placé dans l'addon :
//   addons/godot_mcp/server/godot-mcp-server.mjs   (+ THIRD-PARTY-LICENSES.txt)
// Le chat de l'éditeur l'utilise tel quel : pas de `npm install` pour l'utilisateur, rien à choisir.
// Prérequis côté utilisateur : Node.js 18+. Le fichier généré n'est pas versionné (voir .gitignore).
import { build } from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const outDir = path.resolve(serverRoot, "../addons/godot_mcp/server");
const outFile = path.join(outDir, "godot-mcp-server.mjs");

fs.mkdirSync(outDir, { recursive: true });

const result = await build({
  entryPoints: [path.join(serverRoot, "src/index.ts")],
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node18",
  outfile: outFile,
  metafile: true,
  legalComments: "none", // les licences sont rassemblées dans THIRD-PARTY-LICENSES.txt
  // ws charge ces deux modules natifs s'ils existent (accélération facultative).
  external: ["bufferutil", "utf-8-validate"],
  // Les dépendances CommonJS appellent require() sur des modules Node : en ESM il faut le recréer.
  banner: {
    js:
      "// Généré par Godot-MCP/server/scripts/bundle.mjs : ne pas modifier à la main.\n" +
      "import { createRequire as __godotMcpCreateRequire } from 'node:module';\n" +
      "const require = __godotMcpCreateRequire(import.meta.url);",
  },
  logLevel: "warning",
});

// --- Licences des paquets embarqués -------------------------------------------
const packages = new Map(); // dossier du paquet -> { name, version, license, text }
for (const input of Object.keys(result.metafile.inputs)) {
  const normalized = input.split(path.sep).join("/");
  const at = normalized.lastIndexOf("node_modules/");
  if (at < 0) continue;
  const rest = normalized.slice(at + "node_modules/".length).split("/");
  const name = rest[0].startsWith("@") ? `${rest[0]}/${rest[1]}` : rest[0];
  const dir = path.join(serverRoot, normalized.slice(0, at), "node_modules", ...name.split("/"));
  if (packages.has(dir)) continue;
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const licenseFile = fs.readdirSync(dir).find((f) => /^(licen[cs]e|copying)(\.|$)/i.test(f));
  packages.set(dir, {
    name: manifest.name,
    version: manifest.version,
    license: typeof manifest.license === "string" ? manifest.license : manifest.license?.type ?? "inconnue",
    text: licenseFile ? fs.readFileSync(path.join(dir, licenseFile), "utf8").trim() : "(aucun fichier de licence dans le paquet)",
  });
}
const sorted = [...packages.values()].sort((a, b) => a.name.localeCompare(b.name));
const notice =
  "Le fichier godot-mcp-server.mjs embarque les paquets open source ci-dessous.\n" +
  "Leurs licences sont reproduites telles que publiées par leurs auteurs.\n\n" +
  sorted.map((p) => `${"=".repeat(78)}\n${p.name} ${p.version} — ${p.license}\n${"=".repeat(78)}\n${p.text}\n`).join("\n");
fs.writeFileSync(path.join(outDir, "THIRD-PARTY-LICENSES.txt"), notice, "utf8");

const kb = Math.round(fs.statSync(outFile).size / 1024);
console.log(`serveur MCP embarqué : ${path.relative(serverRoot, outFile)} (${kb} Ko, ${sorted.length} paquets)`);
const unlicensed = sorted.filter((p) => p.text.startsWith("(aucun"));
if (unlicensed.length) console.warn("sans fichier de licence : " + unlicensed.map((p) => p.name).join(", "));
