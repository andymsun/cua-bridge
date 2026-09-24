// Packaged documentation agents read on demand (browser.documentation(),
// agent.documentation.get(name), capability .documentation()).
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "docs");

export function listDocs(sub = "") {
  const out = [];
  for (const e of fs.readdirSync(path.join(dir, sub), { withFileTypes: true })) {
    const rel = path.join(sub, e.name);
    if (e.isDirectory()) out.push(...listDocs(rel));
    else if (e.name.endsWith(".md")) out.push(rel.slice(0, -3));
  }
  return out.sort();
}

export async function readDoc(name) {
  const file = path.join(dir, `${String(name).replace(/\.md$/, "")}.md`);
  if (!file.startsWith(dir + path.sep) || !fs.existsSync(file)) {
    throw new Error(`No documentation named "${name}". Available: ${listDocs().join(", ")}`);
  }
  return fs.readFileSync(file, "utf8");
}
