// monaco-editor の中で型の無いモジュール（languagedefs.ts で JSON の色付けだけ借りる）
declare module "monaco-editor/languages/features/json/tokenization.js" {
  import type { languages } from "monaco-editor";
  export function createTokenizationSupport(supportComments: boolean): languages.TokensProvider;
}
declare module "monaco-editor/languages/definitions/markdown/markdown.js" {
  import type { languages } from "monaco-editor";
  export const language: languages.IMonarchLanguage & {
    tokenizer: Record<string, languages.IMonarchLanguageRule[]>;
  };
}
