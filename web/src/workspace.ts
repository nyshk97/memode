import * as monaco from "./monaco.generated";
import { languageForPath, languageName } from "./languages";
import type { DiskSnapshot, FileBase, Session, SessionDoc } from "./session";
import { TabDrag, type DragSource, type DropHit, type DropTarget } from "./tabdrag";

// タブ（文書）と、左右の分割（グループ）。
// - 文書（Doc）は Monaco の model を 1 つ持つ。同じ文書を左右両方で開くと、同じ model を共有して中身が同期する
// - グループはエディタを 1 つ持ち、タブを切り替えるときは model を差し替える（カーソルやスクロールは文書ごとに覚える）
// - グループは最大 2 つ（左右）

export interface Doc {
  id: number;
  model: monaco.editor.ITextModel;
  /** 保存先。未保存のメモ（使い捨て）は undefined */
  path?: string;
  /** 最後に保存・読み込みしたときの model の版（getAlternativeVersionId）。-1 なら未保存の変更あり */
  savedVersion: number;
  /** ファイルの先頭に BOM があったか（保存するときに付け直す） */
  bom: boolean;
  /** 外で書き換わったかを比べる目印（最後に読み込み・保存したときのもの） */
  base?: FileBase;
}

interface Group {
  root: HTMLElement;
  tabbar: HTMLElement;
  editor: monaco.editor.IStandaloneCodeEditor;
  tabs: number[];
  active: number;
  viewStates: Map<number, monaco.editor.ICodeEditorViewState | null>;
}

const editorOptions: monaco.editor.IStandaloneEditorConstructionOptions = {
  automaticLayout: true,
  fontSize: 13,
  minimap: { enabled: false },
  padding: { top: 8 },
  scrollBeyondLastLine: false,
  renderWhitespace: "selection",
  // Tab は常に半角スペース 2 つ。ファイルの字下げからの推測はしない（モデルごとに updateOptions しても、
  // エディタを作るたびに Monaco が全モデルをこの共通の設定に戻すので、ここで決める）
  tabSize: 2,
  insertSpaces: true,
  detectIndentation: false,
  unicodeHighlight: { ambiguousCharacters: false, invisibleCharacters: false },
};

/** タブとステータスバーの小さな点の色（ファイルの種類の目印）。無い言語は灰色 */
const kindColors: Record<string, string> = {
  markdown: "#5ea8ff",
  plaintext: "#b49bff",
  shell: "#7fdfa2",
  json: "#f0b45e",
  ini: "#f0b45e",
  yaml: "#f0b45e",
  xml: "#f0b45e",
  javascript: "#f5d76e",
  typescript: "#4f9dff",
  python: "#6fb7ff",
  ruby: "#ff6b6b",
  swift: "#ff8a4c",
  go: "#5fd3e8",
  rust: "#e8916a",
  html: "#ff7a59",
  css: "#c084fc",
  scss: "#f472b6",
  sql: "#8ec5ff",
  diff: "#9be37a",
};
function setKindColor(el: HTMLElement, language: string): void {
  const color = kindColors[language];
  if (color) el.style.setProperty("--kind", color);
  else el.style.removeProperty("--kind");
}

export class Workspace {
  private docs = new Map<number, Doc>();
  private groups: Group[] = [];
  private activeGroup = 0;
  private nextDocId = 1;
  private renderQueued = false;
  private drag = new TabDrag(
    (x, y, source) => this.dropTargetAt(x, y, source),
    (source, target) => this.moveTab(source, target),
  );
  /** 状態が変わったら呼ぶ（セッションの保存に使う） */
  onChange?: () => void;
  /** 未保存の変更があるファイルのタブを閉じようとしたとき（保存するか聞く） */
  onConfirmClose?: (doc: Doc, groupIndex: number) => void;
  /** 最後のタブを閉じたとき（ウィンドウごと隠す。次に出すときは空のメモ 1 枚から） */
  onLastTabClosed?: () => void;
  /** タブバーを描き直したとき（掴んで動かせる場所を Swift に送り直す） */
  onRender?: () => void;

  constructor(
    private container: HTMLElement,
    private statusbar: { language: HTMLElement; position: HTMLElement },
    private onLanguageClick: () => void,
  ) {
    statusbar.language.addEventListener("click", () => this.onLanguageClick());
    this.addGroup(this.createDoc().id);
    this.render();
  }

  // MARK: - 文書

  private createDoc(value = "", language = "plaintext", restoreId?: number): Doc {
    const model = monaco.editor.createModel(value, language);
    const doc: Doc = {
      id: restoreId ?? this.nextDocId++,
      model,
      savedVersion: model.getAlternativeVersionId(),
      bom: false,
    };
    doc.model.onDidChangeContent(() => this.queueRender());
    this.docs.set(doc.id, doc);
    return doc;
  }

  /** タブの見出し。メモは 1 行目、ファイルはファイル名。
   *  1 行目に文字（かな・漢字・英数字）が無いとき（空・`{` だけ等）は「scratch」 */
  title(doc: Doc): string {
    if (doc.path) return doc.path.split("/").pop() ?? doc.path;
    const lines = doc.model.getLinesContent();
    const first = lines.find((l) => l.trim() !== "")?.trim();
    if (!first || !/[\p{L}\p{N}]/u.test(first)) return "scratch";
    return first.length > 30 ? first.slice(0, 30) + "…" : first;
  }

  isDirty(doc: Doc): boolean {
    return !!doc.path && doc.model.getAlternativeVersionId() !== doc.savedVersion;
  }

  doc(id: number): Doc | undefined {
    return this.docs.get(id);
  }

  get allDocs(): Doc[] {
    return [...this.docs.values()];
  }

  get activeDoc(): Doc {
    const g = this.groups[this.activeGroup];
    return this.docs.get(g.active)!;
  }

  get activeEditor(): monaco.editor.IStandaloneCodeEditor {
    return this.groups[this.activeGroup].editor;
  }

  setLanguage(language: string): void {
    monaco.editor.setModelLanguage(this.activeDoc.model, language);
    this.render();
    this.onChange?.();
  }

  // MARK: - グループ

  private addGroup(docId: number): Group {
    const root = document.createElement("div");
    root.className = "group";
    const tabbar = document.createElement("div");
    tabbar.className = "tabbar";
    const host = document.createElement("div");
    host.className = "editor-host";
    root.append(tabbar, host);
    this.container.append(root);
    const doc = this.docs.get(docId)!;
    const editor = monaco.editor.create(host, { ...editorOptions, model: doc.model });
    const group: Group = { root, tabbar, editor, tabs: [docId], active: docId, viewStates: new Map() };
    editor.onDidFocusEditorWidget(() => {
      const i = this.groups.indexOf(group);
      if (i >= 0 && i !== this.activeGroup) {
        this.activeGroup = i;
        this.render();
      }
    });
    editor.onDidChangeCursorPosition(() => this.renderStatus());
    this.groups.push(group);
    return group;
  }

  private showDoc(group: Group, docId: number): void {
    if (group.active === docId && group.editor.getModel() === this.docs.get(docId)!.model) return;
    group.viewStates.set(group.active, group.editor.saveViewState());
    group.active = docId;
    group.editor.setModel(this.docs.get(docId)!.model);
    const state = group.viewStates.get(docId);
    if (state) group.editor.restoreViewState(state);
  }

  /** どのグループのタブにも無くなった文書は捨てる（メモの中身もここで消える） */
  private disposeIfUnused(docId: number): void {
    if (this.groups.some((g) => g.tabs.includes(docId))) return;
    this.docs.get(docId)?.model.dispose();
    this.docs.delete(docId);
  }

  // MARK: - 操作（メニューのショートカットから）

  newTab(): void {
    const g = this.groups[this.activeGroup];
    const doc = this.createDoc();
    g.tabs.splice(g.tabs.indexOf(g.active) + 1, 0, doc.id);
    this.showDoc(g, doc.id);
    this.afterChange();
  }

  /** タブを閉じる。最後の 1 枚なら、分割中はそのグループごと閉じ、分割していなければ空のメモを 1 枚作ってウィンドウを隠す。
   *  メモは確認なしで消える。未保存の変更があるファイルは、ほかのグループでも開いていなければ保存するか聞く */
  closeTab(groupIndex = this.activeGroup, docId?: number, force = false): void {
    const g = this.groups[groupIndex];
    if (!g) return;
    const id = docId ?? g.active;
    const at = g.tabs.indexOf(id);
    if (at < 0) return;
    const doc = this.docs.get(id)!;
    const openElsewhere = this.groups.some((other) => other !== g && other.tabs.includes(id));
    if (!force && !openElsewhere && this.isDirty(doc) && this.onConfirmClose) {
      return this.onConfirmClose(doc, groupIndex);
    }
    g.tabs.splice(at, 1);
    g.viewStates.delete(id);
    let lastClosed = false;
    if (g.tabs.length === 0) {
      if (this.groups.length > 1) {
        this.removeGroup(groupIndex);
      } else {
        const doc = this.createDoc();
        g.tabs.push(doc.id);
        this.showDoc(g, doc.id);
        lastClosed = true;
      }
    } else if (g.active === id) {
      this.showDoc(g, g.tabs[Math.min(at, g.tabs.length - 1)]);
    }
    this.disposeIfUnused(id);
    this.afterChange();
    if (lastClosed) this.onLastTabClosed?.();
  }

  /** Cmd+1〜8 は n 枚目、Cmd+9 は最後のタブ */
  selectTab(n: number): void {
    const g = this.groups[this.activeGroup];
    const id = n === 9 ? g.tabs[g.tabs.length - 1] : g.tabs[n - 1];
    if (id === undefined) return;
    this.showDoc(g, id);
    this.afterChange();
  }

  cycleTab(delta: number): void {
    const g = this.groups[this.activeGroup];
    const at = g.tabs.indexOf(g.active);
    this.showDoc(g, g.tabs[(at + delta + g.tabs.length) % g.tabs.length]);
    this.afterChange();
  }

  /** 分割していなければ、今の文書を右にも開く。分割中なら右を閉じ、右にしか無いタブは左へ移す（中身は消さない） */
  toggleSplit(): void {
    if (this.groups.length === 1) {
      const left = this.groups[0];
      const right = this.addGroup(left.active);
      const state = left.editor.saveViewState();
      if (state) right.editor.restoreViewState(state);
      this.activeGroup = 1;
    } else {
      this.removeGroup(1);
    }
    this.afterChange();
  }

  /** タブをドラッグして落とした: 同じグループなら並べ替え、反対側なら移す（元からは消える。元が空になれば分割を閉じる）、
   *  分割していなければ右に分割して移す（1 枚しか無ければ Cmd+\ と同じく左右の両方で開く） */
  moveTab(source: DragSource, target: DropTarget): void {
    const src = this.groups[source.group];
    const id = source.docId;
    const at = src?.tabs.indexOf(id) ?? -1;
    if (!src || at < 0) return;
    const state = id === src.active ? src.editor.saveViewState() : src.viewStates.get(id) ?? null;

    if (target.kind === "split") {
      if (this.groups.length !== 1) return;
      if (src.tabs.length > 1) this.detach(src, id);
      const right = this.addGroup(id);
      if (state) right.editor.restoreViewState(state);
      this.activeGroup = 1;
      return this.afterChange();
    }

    const dst = this.groups[target.group];
    if (!dst) return;
    let index = target.kind === "tabs" ? target.index : dst.tabs.length;
    if (dst === src) {
      src.tabs.splice(at, 1);
      if (at < index) index--;
      src.tabs.splice(index, 0, id);
      this.showDoc(src, id);
    } else {
      // 反対側でも同じ文書を開いていたら、そのタブを落とした場所へ動かす
      const existing = dst.tabs.indexOf(id);
      if (existing >= 0) {
        dst.tabs.splice(existing, 1);
        if (existing < index) index--;
      }
      dst.tabs.splice(index, 0, id);
      if (state && dst.active !== id) dst.viewStates.set(id, state);
      this.showDoc(dst, id);
      this.detach(src, id);
    }
    this.activeGroup = this.groups.indexOf(dst);
    this.afterChange();
  }

  /** グループからタブを外す（文書は捨てない）。空になったらグループごと閉じる */
  private detach(g: Group, id: number): void {
    const at = g.tabs.indexOf(id);
    g.tabs.splice(at, 1);
    if (g.tabs.length === 0) return this.removeGroup(this.groups.indexOf(g));
    if (g.active === id) this.showDoc(g, g.tabs[Math.min(at, g.tabs.length - 1)]);
    g.viewStates.delete(id);
  }

  /** ドラッグ中のマウスの下に落とし先があるか。落としても何も変わらない場所は null */
  private dropTargetAt(x: number, y: number, source: DragSource): DropHit | null {
    const inside = (r: DOMRect) => x >= r.left && x < r.right && y >= r.top && y < r.bottom;
    for (const [gi, g] of this.groups.entries()) {
      const bar = g.tabbar.getBoundingClientRect();
      if (inside(bar)) {
        const tabEls = [...g.tabbar.querySelectorAll<HTMLElement>(".tab")].map((el) => el.getBoundingClientRect());
        let index = tabEls.findIndex((r) => x < r.left + r.width / 2);
        if (index < 0) index = tabEls.length;
        if (gi === source.group) {
          const at = g.tabs.indexOf(source.docId);
          if (index === at || index === at + 1) return null;
        }
        const ref = tabEls[Math.min(index, tabEls.length - 1)];
        const lineX = index < tabEls.length ? ref.left - 2.5 : ref.right + 0.5;
        return {
          target: { kind: "tabs", group: gi, index },
          rect: { left: lineX, top: ref.top, width: 2, height: ref.height },
          style: "line",
        };
      }
      const host = g.editor.getContainerDomNode().getBoundingClientRect();
      if (!inside(host)) continue;
      if (this.groups.length === 1) {
        // 分割していないときは右半分に落とすと分割する
        if (x < host.left + host.width / 2) return null;
        const half = host.width / 2;
        return { target: { kind: "split" }, rect: { left: host.left + half, top: host.top, width: half, height: host.height }, style: "area" };
      }
      if (gi === source.group) return null;
      return { target: { kind: "group", group: gi }, rect: host, style: "area" };
    }
    return null;
  }

  private removeGroup(index: number): void {
    const [removed] = this.groups.splice(index, 1);
    const other = this.groups[0];
    for (const id of removed.tabs) {
      if (!other.tabs.includes(id)) other.tabs.push(id);
    }
    if (removed.tabs.length > 0) this.showDoc(other, removed.active);
    removed.editor.dispose();
    removed.root.remove();
    this.activeGroup = 0;
  }

  focus(): void {
    this.activeEditor.focus();
  }

  // MARK: - 保存・ファイル

  /** 保存できたとき。メモだったものはファイルのタブになる（言語が plaintext なら拡張子から決める） */
  markSaved(doc: Doc, path: string, version: number, base: FileBase, bom: boolean): void {
    doc.path = path;
    doc.savedVersion = version;
    doc.base = base;
    doc.bom = bom;
    if (doc.model.getLanguageId() === "plaintext") {
      const lang = languageForPath(path, doc.model.getLineContent(1));
      if (lang !== "plaintext") monaco.editor.setModelLanguage(doc.model, lang);
    }
    this.render();
    this.onChange?.();
  }

  /** ディスクの中身で置き換える（外で書き換わった・読み直すを選んだ） */
  reload(doc: Doc, disk: DiskSnapshot): void {
    if (doc.model.getValue() !== disk.content) doc.model.setValue(disk.content);
    doc.savedVersion = doc.model.getAlternativeVersionId();
    doc.base = disk.base;
    doc.bom = disk.bom;
    this.render();
    this.onChange?.();
  }

  /** ファイルをタブで開く。すでに開いていればそのタブにする（未保存の変更が無ければディスクの中身で読み直す）。
   *  いま見ているのが空のメモなら、そのタブを置き換える */
  openFile(path: string, disk: DiskSnapshot): void {
    const g = this.groups[this.activeGroup];
    const existing = this.allDocs.find((d) => d.path === path);
    if (existing) {
      if (!this.isDirty(existing) && disk.base && existing.base?.hash !== disk.base.hash) this.reload(existing, disk);
      if (!g.tabs.includes(existing.id)) g.tabs.splice(g.tabs.indexOf(g.active) + 1, 0, existing.id);
      this.showDoc(g, existing.id);
      return this.afterChange();
    }
    const doc = this.createDoc(disk.content, languageForPath(path, disk.content));
    doc.path = path;
    doc.base = disk.base;
    doc.bom = disk.bom;
    const current = this.docs.get(g.active)!;
    const replaceEmpty =
      !current.path && current.model.getValueLength() === 0 && !this.groups.some((o) => o !== g && o.tabs.includes(current.id));
    if (replaceEmpty) {
      g.tabs[g.tabs.indexOf(current.id)] = doc.id;
      g.viewStates.delete(current.id);
    } else {
      g.tabs.splice(g.tabs.indexOf(g.active) + 1, 0, doc.id);
    }
    this.showDoc(g, doc.id);
    if (replaceEmpty) this.disposeIfUnused(current.id);
    this.afterChange();
  }

  /** ファイルが消えた: 中身は残し、未保存の変更ありにする（保存すれば作り直せる） */
  markMissing(doc: Doc): void {
    doc.savedVersion = -1;
    this.render();
    this.onChange?.();
  }

  // MARK: - セッション

  snapshot(): Session {
    return {
      version: 1,
      activeGroup: this.activeGroup,
      groups: this.groups.map((g) => {
        const viewStates: Record<string, unknown> = {};
        for (const id of g.tabs) {
          const state = id === g.active ? g.editor.saveViewState() : g.viewStates.get(id);
          if (state) viewStates[String(id)] = state;
        }
        return { tabs: [...g.tabs], active: g.active, viewStates };
      }),
      docs: this.allDocs.map((d) => {
        const dirty = this.isDirty(d);
        const out: SessionDoc = { id: d.id, language: d.model.getLanguageId(), dirty };
        if (d.path) out.path = d.path;
        if (!d.path || dirty) out.content = d.model.getValue();
        if (d.bom) out.bom = true;
        if (d.base) out.base = d.base;
        return out;
      }),
    };
  }

  /** 前回のセッションに置き換える。ファイルのタブは、未保存の変更が無ければディスクの中身を使う。
   *  読めなくなったファイルで未保存の変更も無いタブは捨てる（戻す中身が無い） */
  restore(session: Session, log: (event: string, detail: string) => void): void {
    for (const g of this.groups) {
      g.editor.dispose();
      g.root.remove();
    }
    for (const d of this.docs.values()) d.model.dispose();
    this.groups = [];
    this.docs.clear();

    for (const sd of session.docs) {
      let content = sd.content;
      if (sd.path && !sd.dirty) {
        if (!sd.disk) {
          log("session.drop_tab", `${sd.path} ${sd.diskError ?? ""}`);
          continue;
        }
        content = sd.disk.content;
      }
      // 色付けできる言語が増えたときのために、plaintext のファイルだけは名前から決め直す
      const language = sd.path && sd.language === "plaintext" ? languageForPath(sd.path, content) : sd.language;
      const doc = this.createDoc(content ?? "", language, sd.id);
      doc.path = sd.path;
      if (sd.path && !sd.dirty) {
        doc.base = sd.disk!.base;
        doc.bom = sd.disk!.bom;
      } else {
        doc.base = sd.base;
        doc.bom = sd.bom ?? false;
        if (sd.dirty) doc.savedVersion = -1;
      }
    }
    this.nextDocId = Math.max(0, ...this.docs.keys()) + 1;

    for (const sg of session.groups) {
      const tabs = sg.tabs.filter((id) => this.docs.has(id));
      if (tabs.length === 0 || this.groups.length >= 2) continue;
      const active = tabs.includes(sg.active) ? sg.active : tabs[0];
      const g = this.addGroup(active);
      g.tabs = tabs;
      for (const [id, state] of Object.entries(sg.viewStates ?? {})) {
        g.viewStates.set(Number(id), state as monaco.editor.ICodeEditorViewState);
      }
      const state = g.viewStates.get(active);
      if (state) g.editor.restoreViewState(state);
    }
    if (this.groups.length === 0) this.addGroup(this.createDoc().id);
    this.activeGroup = Math.min(Math.max(0, session.activeGroup), this.groups.length - 1);
    // 文書がどのタブにも無ければ捨てる
    for (const id of [...this.docs.keys()]) this.disposeIfUnused(id);
    this.render();
    this.focus();
    log("session.restored", `docs=${this.docs.size} groups=${this.groups.length}`);
  }

  private afterChange(): void {
    this.render();
    this.focus();
    this.onChange?.();
  }

  // MARK: - 表示

  private queueRender(): void {
    if (this.renderQueued) return;
    this.renderQueued = true;
    requestAnimationFrame(() => {
      this.renderQueued = false;
      this.render();
      this.onChange?.();
    });
  }

  render(): void {
    this.container.classList.toggle("split", this.groups.length > 1);
    this.groups.forEach((g, gi) => {
      g.root.classList.toggle("active", gi === this.activeGroup);
      g.tabbar.replaceChildren(
        ...g.tabs.map((id) => {
          const doc = this.docs.get(id)!;
          const tab = document.createElement("div");
          tab.className = "tab" + (id === g.active ? " active" : "") + (this.isDirty(doc) ? " dirty" : "");
          tab.title = doc.path ?? this.title(doc);
          const kind = document.createElement("span");
          kind.className = "kind";
          setKindColor(kind, doc.model.getLanguageId());
          const label = document.createElement("span");
          label.className = "label";
          label.textContent = this.title(doc);
          const close = document.createElement("span");
          close.className = "close";
          close.textContent = "×";
          close.addEventListener("mousedown", (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.closeTab(this.groups.indexOf(g), id);
          });
          tab.append(kind, label, close);
          tab.addEventListener("mousedown", (e) => {
            e.preventDefault();
            const index = this.groups.indexOf(g);
            if (e.button === 1) return this.closeTab(index, id);
            if (e.button === 0) this.drag.begin(e, { group: index, docId: id }, tab);
            this.activeGroup = index;
            this.showDoc(g, id);
            this.afterChange();
          });
          return tab;
        }),
      );
      g.tabbar.querySelector(".tab.active")?.scrollIntoView({ block: "nearest", inline: "nearest" });
    });
    this.renderStatus();
    this.onRender?.();
  }

  private renderStatus(): void {
    const doc = this.activeDoc;
    this.statusbar.language.textContent = languageName(doc.model.getLanguageId());
    setKindColor(this.statusbar.language, doc.model.getLanguageId());
    const pos = this.activeEditor.getPosition();
    const cursors = this.activeEditor.getSelections()?.length ?? 1;
    this.statusbar.position.textContent =
      (pos ? `行 ${pos.lineNumber}、列 ${pos.column}` : "") + (cursors > 1 ? `（カーソル ${cursors}）` : "");
  }

  /** 自走の検証で読む */
  debugInfo() {
    return {
      activeGroup: this.activeGroup,
      groups: this.groups.map((g) => ({
        active: g.tabs.indexOf(g.active),
        tabs: g.tabs.map((id) => {
          const d = this.docs.get(id)!;
          return { id, title: this.title(d), language: d.model.getLanguageId(), path: d.path ?? null, dirty: this.isDirty(d) };
        }),
      })),
      docCount: this.docs.size,
    };
  }
}
