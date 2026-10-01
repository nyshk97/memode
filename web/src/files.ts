import { post } from "./bridge";
import { languageForPath } from "./languages";
import type { DiskSnapshot, FileBase, Session } from "./session";
import { showQuickPick, type PickItem } from "./quickpick";
import type { Doc, Workspace } from "./workspace";
import * as monaco from "./monaco.generated";

// 保存・セッション・外での書き換えの JS 側。ファイルの読み書きと確認のダイアログは Swift（DocumentService）が持つ

export class FileController {
  /** 前回のセッションを受け取るまではセッションを書かない（起動直後の空の状態で上書きしないため） */
  private sessionEnabled = false;
  private saveTimer: number | undefined;
  /** 保存が済んだら閉じるタブ（閉じる前の確認で「保存」を選んだ） */
  private closeAfterSave = new Map<number, number>();
  /** 「外で書き換わった」の確認待ちの、ディスクの中身 */
  private pendingDisk = new Map<number, DiskSnapshot>();
  /** Cmd+P の一覧（ホームの下・登録フォルダ）。Swift は一覧が変わったときだけ送ってくる */
  private indexCache: { version: number; items: PickItem[] } | undefined;

  constructor(private workspace: Workspace) {
    workspace.onChange = () => this.scheduleSession();
    workspace.onConfirmClose = (doc, groupIndex) => {
      this.closeAfterSave.set(doc.id, groupIndex);
      post({ type: "confirmClose", docId: doc.id, name: workspace.title(doc) });
    };
  }

  // MARK: - セッション

  private scheduleSession(): void {
    if (!this.sessionEnabled) return;
    window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.postSession(), 300);
  }

  private postSession(flushId?: number): void {
    window.clearTimeout(this.saveTimer);
    if (!this.sessionEnabled) {
      post({ type: "sessionSkipped", flushId });
      return;
    }
    const msg: Record<string, unknown> = { type: "session", session: this.workspace.snapshot() };
    if (flushId !== undefined) msg.flushId = flushId;
    post(msg as { type: "session" });
  }

  // MARK: - 保存

  save(doc: Doc, saveAs: boolean): void {
    const msg: Record<string, unknown> = {
      type: "save",
      docId: doc.id,
      suggestedName: this.suggestedName(doc),
      content: doc.model.getValue(),
      bom: doc.bom,
      version: doc.model.getAlternativeVersionId(),
    };
    if (doc.path && !saveAs) msg.path = doc.path;
    post(msg as { type: "save" });
  }

  /** 保存ダイアログに最初に入れる名前。メモは 1 行目から作り、言語の拡張子を付ける */
  private suggestedName(doc: Doc): string {
    if (doc.path) return doc.path.split("/").pop()!;
    const base = this.workspace.title(doc).replace(/[/\\:]/g, "-").replace(/…$/, "").slice(0, 50).trim() || "無題";
    const lang = monaco.languages.getLanguages().find((l) => l.id === doc.model.getLanguageId());
    const ext = doc.model.getLanguageId() === "plaintext" ? ".txt" : (lang?.extensions?.[0] ?? ".txt");
    return base + ext;
  }

  // MARK: - Swift から

  handle(msg: { type: string; [key: string]: unknown }): void {
    const ws = this.workspace;
    const doc = typeof msg.docId === "number" ? ws.doc(msg.docId) : undefined;
    switch (msg.type) {
      case "restore":
        try {
          if (msg.session) ws.restore(msg.session as Session, (event, detail) => post({ type: "log", event, detail }));
        } catch (e) {
          // 復元の途中で失敗した状態で書くと、前回のメモ（session.json にしか無い）を上書きして消してしまう。
          // この起動ではセッションを書かない（session.json はそのまま残る）
          post({ type: "log", event: "session.restore_failed", detail: `${e} セッションの保存を止める` });
          return;
        }
        this.sessionEnabled = true;
        return;
      case "quickOpen": {
        const home = msg.home as string;
        const toItem = (path: string, boost = 0): PickItem => {
          const slash = path.lastIndexOf("/");
          const dir = path.slice(0, slash);
          const detail = dir === home ? "~" : dir.startsWith(home + "/") ? "~" + dir.slice(home.length) : dir;
          return { label: path.slice(slash + 1), detail, value: path, boost };
        };
        if (Array.isArray(msg.index)) {
          this.indexCache = { version: msg.version as number, items: (msg.index as string[]).map((p) => toItem(p)) };
        } else if (this.indexCache?.version !== msg.version) {
          post({ type: "quickOpenResend" });
          return;
        }
        // 最近使ったファイルを先に、同じくらい一致するなら上に
        const recents = (msg.recents as string[]).map((p) => toItem(p, 20));
        const seen = new Set(recents.map((r) => r.value));
        const items = [...recents, ...this.indexCache!.items.filter((i) => !seen.has(i.value))];
        showQuickPick({
          placeholder: `ファイル名で探す（最近使ったファイル・ホームの下 ${items.length.toLocaleString()} 件）`,
          items,
          onPick: (item) => post({ type: "openPaths", paths: [item.value] }),
          onCancel: () => ws.focus(),
        });
        return;
      }
      case "openFile":
        ws.openFile(msg.path as string, msg.disk as DiskSnapshot, languageForPath);
        return;
      case "flushSession":
        return this.postSession(msg.flushId as number | undefined);
      case "saved": {
        if (!doc) return;
        ws.markSaved(doc, msg.path as string, msg.version as number, msg.base as FileBase, msg.bom as boolean, languageForPath);
        const group = this.closeAfterSave.get(doc.id);
        this.closeAfterSave.delete(doc.id);
        if (group !== undefined) ws.closeTab(group, doc.id, true);
        return;
      }
      case "saveFailed":
      case "saveCancelled":
        if (doc) this.closeAfterSave.delete(doc.id);
        return;
      case "closeDecision": {
        if (!doc) return;
        const group = this.closeAfterSave.get(doc.id) ?? 0;
        if (msg.decision === "save") return this.save(doc, false);
        this.closeAfterSave.delete(doc.id);
        if (msg.decision === "discard") ws.closeTab(group, doc.id, true);
        return;
      }
      case "checkFiles":
        post({
          type: "fileStates",
          files: ws.allDocs
            .filter((d) => d.path && d.base)
            .map((d) => ({ docId: d.id, path: d.path, base: d.base, dirty: ws.isDirty(d) })),
        });
        return;
      case "diskChanged": {
        if (!doc) return;
        const disk = msg.disk as DiskSnapshot | null;
        if (!disk) {
          if (!ws.isDirty(doc)) ws.markMissing(doc);
          return;
        }
        if (!ws.isDirty(doc)) return ws.reload(doc, disk);
        // 確認を出している最中に出し直しても、同じ文書の確認を重ねて出さない
        const asking = this.pendingDisk.has(doc.id);
        this.pendingDisk.set(doc.id, disk);
        if (asking) return;
        post({ type: "askConflict", docId: doc.id, name: ws.title(doc) });
        return;
      }
      case "conflictDecision": {
        const disk = doc && this.pendingDisk.get(doc.id);
        if (!doc || !disk) return;
        this.pendingDisk.delete(doc.id);
        if (msg.decision === "reload") ws.reload(doc, disk);
        else doc.base = disk.base; // 自分の変更を残す: 同じ書き換えについてはもう聞かない
        this.scheduleSession();
        return;
      }
      default:
        post({ type: "log", event: "bridge.unknown_message", detail: msg.type });
    }
  }
}
