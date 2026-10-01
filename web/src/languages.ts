import * as monaco from "./monaco.generated";

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

/** ファイル名から言語を決める（拡張子・ファイル名・`.env` のような名前）。分からなければ plaintext */
export function languageForPath(path: string): string {
  const name = path.split("/").pop() ?? path;
  const lower = name.toLowerCase();
  for (const l of monaco.languages.getLanguages()) {
    if (l.filenames?.some((f) => f.toLowerCase() === lower)) return l.id;
  }
  let best: { id: string; length: number } | undefined;
  for (const l of monaco.languages.getLanguages()) {
    for (const ext of l.extensions ?? []) {
      if (lower.endsWith(ext.toLowerCase()) && (!best || ext.length > best.length)) {
        best = { id: l.id, length: ext.length };
      }
    }
  }
  return best?.id ?? "plaintext";
}
