// セッションの形（Swift の SessionStore はこれをそのまま JSON で置く）。
// ファイルのタブは、未保存の変更があるときだけ中身を持つ（無ければ起動時にディスクから読み直す）

/** 外で書き換わったかを比べるための目印（Swift の FileIO.Base） */
export interface FileBase {
  mtime: number;
  size: number;
  hash: string;
}

export interface DiskSnapshot {
  content: string;
  bom: boolean;
  /** まだディスクに無いファイル（`memode 新しいファイル.md`）では無い */
  base?: FileBase;
}

export interface SessionDoc {
  id: number;
  path?: string;
  language: string;
  /** メモは常に、ファイルは未保存の変更があるときだけ */
  content?: string;
  dirty: boolean;
  bom?: boolean;
  base?: FileBase;
  /** 起動時に Swift が付ける: いまのディスクの中身、または読めなかった理由 */
  disk?: DiskSnapshot;
  diskError?: string;
}

export interface SessionGroup {
  tabs: number[];
  active: number;
  /** 文書ごとのカーソル・スクロール（Monaco の ICodeEditorViewState） */
  viewStates: Record<string, unknown>;
}

export interface Session {
  version: 1;
  activeGroup: number;
  groups: SessionGroup[];
  docs: SessionDoc[];
}
