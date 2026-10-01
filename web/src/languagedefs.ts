import * as monaco from "./monaco.generated";
import { createTokenizationSupport } from "monaco-editor/languages/features/json/tokenization.js";
import { language as markdownLanguage } from "monaco-editor/languages/definitions/markdown/markdown.js";

// Monaco に色付けが無い（または言語サービスごと外したので登録されていない）言語を足す。
// - JSON: Monaco では言語の登録が言語サービス（features/json）の中にしかなく、gen-monaco-entry.mjs で外しているので
//   言語そのものが無い。ワーカーを使わない色付けの部品（tokenization.js）だけを借りて登録し直す（赤線は出さない）
// - ignore（.gitignore 等）・diff: Monaco に文法が無いので Monarch で書く
// - Markdown: Monaco の文法では見出し・リストの記号・チェックボックスが全部 keyword なので、色を分けられるよう差し替える

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

// Monaco の Markdown は使うときに文法を読み込む（registerTokensProviderFactory）。先にここで直接登録すると、
// そちらは呼ばれずにこれが使われる（言語の設定 conf は Monaco のものがそのまま読み込まれる）。
// 先頭に足した規則が元の規則より先に当たる。トークン名には元の文法の tokenPostfix（.md）が付く
monaco.languages.setMonarchTokensProvider("markdown", {
  ...markdownLanguage,
  tokenizer: {
    ...markdownLanguage.tokenizer,
    root: [
      [/^(\s{0,3})(#+)((?:[^\\#]|@escapes)+)((?:#+)?)/, ["white", "heading.mark", "heading", "heading.mark"]],
      // 済みのチェックボックスは行の残りごと薄く消す
      [/^(\s*)([*\-+]|\d+\.)(\s+)(\[[xX]\])(.*)$/, ["white", "list", "white", "checkbox", "done"]],
      [/^(\s*)([*\-+]|\d+\.)(\s+)(\[ \])/, ["white", "list", "white", "checkbox"]],
      [/^(\s*)([*\-+:]|\d+\.)(\s)/, ["white", "list", "white"]],
      ...markdownLanguage.tokenizer.root,
    ],
    linecontent: markdownLanguage.tokenizer.linecontent.map((rule) =>
      Array.isArray(rule) && rule[1] === "variable" ? [rule[0], "code"] : rule,
    ),
  },
} as monaco.languages.IMonarchLanguage);

/** 背景は CSS の板（.editor-host）が塗るので、エディタ自身は透明にする */
const transparentChrome = {
  "editor.background": "#00000000",
  "editorGutter.background": "#00000000",
  "editor.lineHighlightBorder": "#00000000",
  "scrollbar.shadow": "#00000000",
  "editorOverviewRuler.border": "#00000000",
};

type Palette = Record<
  "text" | "heading" | "mark" | "list" | "checkbox" | "done" | "code" | "keyword" | "string" | "comment" | "number" | "type" | "variable" | "tag" | "regexp" | "link",
  string
>;
/** 文字の色。言語ごとのトークン名（keyword.python 等）は前方一致で当たる */
const syntax = (c: Palette): monaco.editor.ITokenThemeRule[] => [
  { token: "", foreground: c.text },
  { token: "keyword", foreground: c.keyword },
  { token: "string", foreground: c.string },
  { token: "comment", foreground: c.comment },
  { token: "number", foreground: c.number },
  { token: "constant", foreground: c.number },
  { token: "type", foreground: c.type },
  { token: "variable", foreground: c.variable },
  { token: "variable.predefined", foreground: c.variable },
  { token: "predefined", foreground: c.variable },
  { token: "tag", foreground: c.tag },
  { token: "attribute.name", foreground: c.number },
  { token: "attribute.value", foreground: c.string },
  { token: "regexp", foreground: c.regexp },
  // Markdown（上で差し替えた文法のトークン）
  { token: "heading.md", foreground: c.heading, fontStyle: "bold" },
  { token: "heading.mark.md", foreground: c.mark, fontStyle: "bold" },
  { token: "list.md", foreground: c.list },
  { token: "checkbox.md", foreground: c.checkbox },
  { token: "done.md", foreground: c.done, fontStyle: "strikethrough" },
  { token: "code.md", foreground: c.code },
  { token: "variable.source.md", foreground: c.code },
  { token: "string.md", foreground: c.mark },
  { token: "string.link.md", foreground: c.link },
  { token: "strong.md", foreground: c.heading, fontStyle: "bold" },
  { token: "emphasis.md", fontStyle: "italic" },
  { token: "comment.md", foreground: c.comment },
  { token: "keyword.md", foreground: c.list },
  { token: "keyword.table.header.md", foreground: c.heading, fontStyle: "bold" },
];

/** 既定のテーマ（vs・vs-dark）に、diff の追加行・削除行の色と、板に合わせた地の色・文字の色を足したもの */
export const themes = { light: "memode-light", dark: "memode-dark" };
monaco.editor.defineTheme(themes.light, {
  base: "vs",
  inherit: true,
  rules: [
    { token: "inserted.diff", foreground: "22863A" },
    { token: "deleted.diff", foreground: "B31D28" },
    ...syntax({
      text: "1F1F26", heading: "0D0D12", mark: "8E8E99", list: "2F6BFF", checkbox: "7A3DDB", done: "B0B0BA", code: "A8590F",
      keyword: "8A3FD6", string: "1B8048", comment: "8E8E99", number: "B4671B", type: "0F7C8C", variable: "1D68C8",
      tag: "C4285A", regexp: "C2410C", link: "1D68C8",
    }),
  ],
  colors: {
    ...transparentChrome,
    "editor.foreground": "#1f1f26",
    "editor.lineHighlightBackground": "#0000000a",
    "editorLineNumber.foreground": "#00000038",
    "editorLineNumber.activeForeground": "#00000099",
    "editorCursor.foreground": "#2f6bff",
    // 括弧の色分けはトークンの色より優先される（Markdown のチェックボックスもこの色になる）
    "editorBracketHighlight.foreground1": "#7a3ddb",
    "editorBracketHighlight.foreground2": "#2f6bff",
    "editorBracketHighlight.foreground3": "#b4671b",
  },
});
monaco.editor.defineTheme(themes.dark, {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "inserted.diff", foreground: "81B88B" },
    { token: "deleted.diff", foreground: "F14C4C" },
    ...syntax({
      text: "E6E6EC", heading: "FFFFFF", mark: "8A8A99", list: "7AA8FF", checkbox: "B49BFF", done: "6B6B78", code: "EFC07C",
      keyword: "D3A6FF", string: "8EE6AE", comment: "7D7D8A", number: "F0B45E", type: "7FD8E8", variable: "8CCBFF",
      tag: "FF8FA3", regexp: "FF9E64", link: "8CCBFF",
    }),
  ],
  colors: {
    ...transparentChrome,
    "editor.foreground": "#e6e6ec",
    "editor.lineHighlightBackground": "#ffffff0b",
    "editorLineNumber.foreground": "#ffffff33",
    "editorLineNumber.activeForeground": "#ffffffa6",
    "editorCursor.foreground": "#7aa8ff",
    "editorBracketHighlight.foreground1": "#b49bff",
    "editorBracketHighlight.foreground2": "#7aa8ff",
    "editorBracketHighlight.foreground3": "#f0b45e",
  },
});
