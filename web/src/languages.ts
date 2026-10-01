import * as monaco from "./monaco.generated";
import "./languagedefs";

export interface LanguageInfo {
  id: string;
  name: string;
}

/** 言語を選ぶ一覧（名前順。plaintext を先頭に） */
export function allLanguages(): LanguageInfo[] {
  const list = monaco.languages
    .getLanguages()
    .map((l) => ({ id: l.id, name: l.aliases?.[0] ?? l.id }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const plain = list.findIndex((l) => l.id === "plaintext");
  if (plain > 0) list.unshift(...list.splice(plain, 1));
  return list;
}

export function languageName(id: string): string {
  const l = monaco.languages.getLanguages().find((x) => x.id === id);
  return l?.aliases?.[0] ?? id;
}

// Monaco の登録表に無いが、既存の言語の色付けで足りるもの（小文字で書く）
const extraFilenames: Record<string, string> = {
  ".zshrc": "shell", ".zshenv": "shell", ".zprofile": "shell", ".zlogin": "shell", ".zlogout": "shell",
  ".bashrc": "shell", ".bash_profile": "shell", ".bash_login": "shell", ".bash_logout": "shell", ".profile": "shell",
  ".envrc": "shell", ".env": "shell", ".dev.vars": "shell",
  brewfile: "ruby", podfile: "ruby", fastfile: "ruby", appfile: "ruby", matchfile: "ruby", pluginfile: "ruby",
  dangerfile: "ruby", guardfile: "ruby", capfile: "ruby", vagrantfile: "ruby", berksfile: "ruby",
  containerfile: "dockerfile",
  ".npmrc": "ini", ".gitmodules": "ini", ".flake8": "ini", ".pylintrc": "ini", ".coveragerc": "ini",
  "cargo.lock": "ini", "poetry.lock": "ini", "uv.lock": "ini", pipfile: "ini",
};
const extraExtensions: Record<string, string> = {
  ".mdc": "markdown",
  // Monaco に文法が無い。<script>・<style> を埋め込みで色分けする html で代用する
  ".vue": "html", ".svelte": "html",
  ".plist": "xml", ".entitlements": "xml", ".xcscheme": "xml", ".xcworkspacedata": "xml", ".xcprivacy": "xml",
  ".storyboard": "xml", ".xib": "xml", ".rss": "xml", ".atom": "xml", ".gpx": "xml", ".kml": "xml",
  ".zsh": "shell", ".ksh": "shell", ".command": "shell", ".env": "shell",
  // TOML は Monaco に文法が無い。[section]・key = value・# のコメントが同じ形の ini で代用する
  ".toml": "ini", ".conf": "ini", ".cfg": "ini",
  ".ru": "ruby", ".rake": "ruby", ".podspec": "ruby", ".jbuilder": "ruby", ".thor": "ruby",
  ".mm": "objective-c",
  ".keymap": "cpp", ".overlay": "cpp", ".dts": "cpp", ".dtsi": "cpp", ".ino": "cpp",
  ".pyi": "python",
};
/** 外して付け直す接尾辞（`config.json.sample` は json として見る） */
const templateSuffixes = [".example", ".sample", ".template", ".tmpl", ".dist", ".orig", ".bak"];

/** 1 行目の shebang（`#!/usr/bin/env -S node --flag` 等）のコマンド名から */
const shebangLanguages: [RegExp, string][] = [
  [/^(ba|z|k|da|a)?sh$/, "shell"],
  [/^python[\d.]*$/, "python"],
  [/^ruby[\d.]*$/, "ruby"],
  [/^(node|nodejs|deno|bun|zx)$/, "javascript"],
  [/^(ts-node|tsx)$/, "typescript"],
  [/^perl[\d.]*$/, "perl"],
  [/^php[\d.]*$/, "php"],
  [/^lua[\d.]*$/, "lua"],
  [/^(Rscript)$/, "r"],
];

function languageForShebang(firstLine: string): string | undefined {
  if (!firstLine.startsWith("#!")) return undefined;
  const words = firstLine.slice(2).trim().split(/\s+/);
  let command = words[0]?.split("/").pop() ?? "";
  if (command === "env") command = words.slice(1).find((w) => !w.startsWith("-") && !w.includes("=")) ?? "";
  return shebangLanguages.find(([re]) => re.test(command))?.[1];
}

function languageForName(name: string): string | undefined {
  const lower = name.toLowerCase();
  if (extraFilenames[lower]) return extraFilenames[lower];
  for (const l of monaco.languages.getLanguages()) {
    if (l.filenames?.some((f) => f.toLowerCase() === lower)) return l.id;
  }
  if (lower.startsWith(".env.")) return "shell";
  if (lower.startsWith("dockerfile.")) return "dockerfile";
  let best: { id: string; length: number } | undefined;
  const consider = (ext: string, id: string) => {
    if (lower.endsWith(ext.toLowerCase()) && (!best || ext.length > best.length)) best = { id, length: ext.length };
  };
  for (const l of monaco.languages.getLanguages()) for (const ext of l.extensions ?? []) consider(ext, l.id);
  for (const [ext, id] of Object.entries(extraExtensions)) consider(ext, id);
  if (best) return best.id;
  const suffix = templateSuffixes.find((s) => lower.endsWith(s) && lower.length > s.length);
  return suffix ? languageForName(name.slice(0, -suffix.length)) : undefined;
}

/** ファイル名から言語を決める（拡張子・ファイル名・`.env` のような名前、`~/.config/git/ignore`）。
 *  名前で決まらなければ中身の 1 行目の shebang を見る。分からなければ plaintext */
export function languageForPath(path: string, content?: string): string {
  if (/(^|\/)(git\/ignore|\.git\/info\/exclude)$/.test(path)) return "ignore";
  const name = path.split("/").pop() ?? path;
  return languageForName(name) ?? languageForShebang(content?.slice(0, 200).split("\n", 1)[0] ?? "") ?? "plaintext";
}
