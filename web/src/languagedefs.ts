import * as monaco from "./monaco.generated";
import { createTokenizationSupport } from "monaco-editor/languages/features/json/tokenization.js";

// Monaco に色付けが無い（または言語サービスごと外したので登録されていない）言語を足す。
// - JSON: Monaco では言語の登録が言語サービス（features/json）の中にしかなく、gen-monaco-entry.mjs で外しているので
//   言語そのものが無い。ワーカーを使わない色付けの部品（tokenization.js）だけを借りて登録し直す（赤線は出さない）
// - ignore（.gitignore 等）・diff: Monaco に文法が無いので Monarch で書く

monaco.languages.register({
  id: "json",
  extensions: [".json", ".jsonc", ".json5", ".jsonl", ".ndjson", ".har", ".map", ".code-snippets", ".code-workspace", ".webmanifest", ".geojson", ".ipynb"],
  filenames: [".babelrc", ".bowerrc", ".jshintrc", ".jscsrc", ".eslintrc", ".swcrc", ".nycrc", "Package.resolved", "flake.lock", "composer.lock", "Pipfile.lock"],
  aliases: ["JSON", "json"],
});
monaco.languages.setTokensProvider("json", createTokenizationSupport(true));
// Monaco の jsonMode.js の richEditConfiguration と同じ
monaco.languages.setLanguageConfiguration("json", {
  wordPattern: /(-?\d*\.\d\w*)|([^[{\]}:",\s]+)/g,
  comments: { lineComment: "//", blockComment: ["/*", "*/"] },
  brackets: [
    ["{", "}"],
    ["[", "]"],
  ],
  autoClosingPairs: [
    { open: "{", close: "}", notIn: ["string"] },
    { open: "[", close: "]", notIn: ["string"] },
    { open: '"', close: '"', notIn: ["string"] },
  ],
});

monaco.languages.register({
  id: "ignore",
  filenames: [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore", ".stylelintignore", ".cursorignore", ".vscodeignore", ".gcloudignore", ".hgignore", ".slugignore"],
  aliases: ["Ignore", "ignore"],
});
monaco.languages.setMonarchTokensProvider("ignore", {
  tokenizer: {
    root: [
      [/^\s*#.*$/, "comment"],
      [/^!/, "keyword"],
      [/\\./, "string"],
      [/\*\*|[*?]|\[[^\]]*\]/, "regexp"],
      [/\//, "delimiter"],
    ],
  },
});
monaco.languages.setLanguageConfiguration("ignore", { comments: { lineComment: "#" } });

monaco.languages.register({ id: "diff", extensions: [".diff", ".patch", ".rej"], aliases: ["Diff", "diff"] });
monaco.languages.setMonarchTokensProvider("diff", {
  tokenizer: {
    root: [
      [/^(diff|index|new file mode|deleted file mode|similarity index|rename from|rename to|Binary files) .*$/, "meta"],
      [/^(---|\+\+\+) .*$/, "type"],
      [/^@@.*$/, "keyword"],
      [/^\+.*$/, "inserted.diff"],
      [/^-.*$/, "deleted.diff"],
      [/^\\ .*$/, "comment"],
    ],
  },
});

/** 既定のテーマ（vs・vs-dark）に、diff の追加行・削除行の色だけ足したもの */
export const themes = { light: "memode-light", dark: "memode-dark" };
monaco.editor.defineTheme(themes.light, {
  base: "vs",
  inherit: true,
  rules: [
    { token: "inserted.diff", foreground: "22863A" },
    { token: "deleted.diff", foreground: "B31D28" },
  ],
  colors: {},
});
monaco.editor.defineTheme(themes.dark, {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "inserted.diff", foreground: "81B88B" },
    { token: "deleted.diff", foreground: "F14C4C" },
  ],
  colors: {},
});
