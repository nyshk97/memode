// monaco-editor の editor.main.js から「言語サービス（TS・JSON・CSS・HTML の補完や検査）」と
// LSP クライアントを除いた import の並びを作る。メモ用途ではシンタックスハイライトだけ欲しく、
// 言語サービスを入れると単体のファイルを開いただけで「import が解決できない」などの赤線が出るため。
// monaco-editor を上げたときに追従できるよう、毎回のビルドで作り直す（生成物は gitignore）。
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const main = join(here, "../node_modules/monaco-editor/esm/vs/editor/editor.main.js");
const out = join(here, "../src/monaco.generated.ts");
const src = readFileSync(main, "utf8");

const lines = [];
for (const line of src.split("\n")) {
  const m = line.match(/^import (?:\* as \w+ from )?'([^']+)';$/);
  if (!m) continue;
  const spec = m[1];
  if (spec.includes("/languages/features/") || spec.includes("monaco-lsp-client")) continue;
  const abs = join(dirname(main), spec);
  lines.push(`import "${relative(dirname(out), abs).split("\\").join("/")}";`);
}
if (lines.length < 50) throw new Error(`editor.main.js から拾えた import が少なすぎる (${lines.length})。monaco-editor の構成が変わった可能性がある`);
lines.push(`export * from "${relative(dirname(out), join(dirname(main), "editor.api.js"))}";`);
writeFileSync(out, `// scripts/gen-monaco-entry.mjs が生成（編集しない）\n${lines.join("\n")}\n`);
console.log(`monaco entry: ${lines.length} lines -> ${relative(process.cwd(), out)}`);
