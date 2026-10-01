import * as monaco from "./monaco.generated";
import EditorWorker from "../node_modules/monaco-editor/esm/vs/editor/editor.worker.js?worker";
import { install, post, type EditorHost } from "./bridge";
import { allLanguages, languageForPath } from "./languages";
import { themes } from "./languagedefs";
import { quickPickDebug, showQuickPick } from "./quickpick";
import { Workspace } from "./workspace";
import { FileController } from "./files";
import { DragRegions } from "./dragregions";
import "./style.css";

// 言語サービス（TS・JSON 等）は入れていないので、worker はエディタ本体の 1 種類だけ。
// worker から返事が来たかを覚えておく（独自の URL スキームで worker が動くかの確認用）
let workerAlive = false;
self.MonacoEnvironment = {
  getWorker: () => {
    const worker = new EditorWorker();
    worker.addEventListener("message", () => (workerAlive = true));
    worker.addEventListener("error", (e) => post({ type: "log", event: "worker.error", detail: String(e.message) }));
    return worker;
  },
};

const dark = window.matchMedia("(prefers-color-scheme: dark)");
const applyTheme = () => monaco.editor.setTheme(dark.matches ? themes.dark : themes.light);
applyTheme();
dark.addEventListener("change", applyTheme);

const chooseLanguage = () => {
  const current = workspace.activeDoc.model.getLanguageId();
  showQuickPick({
    placeholder: "言語を選ぶ",
    items: allLanguages().map((l) => ({ label: l.name, detail: l.id === current ? "（いまの言語）" : l.id, value: l.id })),
    onPick: (item) => {
      workspace.setLanguage(item.value);
      workspace.focus();
    },
    onCancel: () => workspace.focus(),
  });
};

const workspace = new Workspace(
  document.getElementById("groups")!,
  { language: document.getElementById("status-language")!, position: document.getElementById("status-position")! },
  chooseLanguage,
);

const files = new FileController(workspace);
workspace.onLastTabClosed = () => post({ type: "action", action: "hide_panel" });
const dragRegions = new DragRegions(document.getElementById("groups")!);
workspace.onRender = () => dragRegions.update();
dragRegions.update();

// ステータスバーの「元に戻す」。ウィンドウの位置とサイズを既定に戻す（メニューの同じ項目と同じ経路）
document.getElementById("status-reset-frame")!.addEventListener("click", () => {
  post({ type: "action", action: "reset_window_frame" });
});

// ステータスバーの右端の版。押すとアップデートを確認する（dev 版は Sparkle が無いので押せない）
const statusVersion = document.getElementById("status-version")!;
let canCheckForUpdates = false;
statusVersion.addEventListener("click", () => {
  if (canCheckForUpdates) post({ type: "action", action: "check_for_updates" });
});

const host: EditorHost = {
  focus: () => workspace.focus(),
  setContent(value, language) {
    const model = workspace.activeDoc.model;
    model.setValue(value);
    if (language) workspace.setLanguage(language);
  },
  command(name, index) {
    switch (name) {
      case "new_tab":
        return workspace.newTab();
      case "close_tab":
        return workspace.closeTab();
      case "select_tab":
        return workspace.selectTab(index ?? 1);
      case "next_tab":
        return workspace.cycleTab(1);
      case "previous_tab":
        return workspace.cycleTab(-1);
      case "toggle_split":
        return workspace.toggleSplit();
      case "choose_language":
        return chooseLanguage();
      case "save":
        return files.save(workspace.activeDoc, false);
      case "save_as":
        return files.save(workspace.activeDoc, true);
      default:
        post({ type: "log", event: "command.unknown", detail: name });
    }
  },
  setAppInfo({ version, dev, update }) {
    canCheckForUpdates = !dev;
    statusVersion.textContent = dev ? "dev" : update ? `v${update} に更新` : `v${version}`;
    statusVersion.title = dev ? `dev 版（v${version}）はアップデートしない` : update ? `v${version} → v${update}` : "アップデートを確認";
    statusVersion.classList.toggle("clickable", !dev);
    statusVersion.classList.toggle("update", !dev && !!update);
  },
  handleFileMessage: (msg) => files.handle(msg),
  detectLanguage: (path, content) => languageForPath(path, content),
  debugState() {
    const editor = workspace.activeEditor;
    const selections = editor.getSelections() ?? [];
    return {
      value: editor.getValue(),
      cursorCount: selections.length,
      cursors: selections.map((s) => ({ line: s.positionLineNumber, column: s.positionColumn })),
      focused: editor.hasTextFocus(),
      workspace: workspace.debugInfo(),
      quickPick: quickPickDebug(),
      tokenClassCount: new Set(
        Array.from(document.querySelectorAll(".group.active .view-line span span")).map((el) => el.className),
      ).size,
      workerLoaded: workerAlive,
      statusVersion: { text: statusVersion.textContent ?? "", clickable: canCheckForUpdates },
    };
  },
};

window.addEventListener("error", (e) => post({ type: "log", event: "js.error", detail: String(e.message) }));
install(host);
workspace.focus();
