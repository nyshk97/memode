// Swift と JS の受け渡し。エディタの実装（Monaco / CodeMirror）には依存しない。
// Swift → JS: window.memode.receive(msg)
// JS → Swift: window.webkit.messageHandlers.memode.postMessage(msg)

export type FromSwift =
  | { type: "focus" }
  /** 隠れていたパネルを出したとき（中身の出現アニメーション。ウィンドウのフェードは Swift 側） */
  | { type: "appear" }
  | { type: "setContent"; value: string; language?: string }
  /** 今の版と、見つかった新しい版（ステータスバーの右端に出す） */
  | { type: "appInfo"; version: string; dev: boolean; update: string | null }
  /** メニューの操作（new_tab・close_tab・select_tab・next_tab・previous_tab・toggle_split・choose_language・save・save_as） */
  | { type: "command"; name: string; index?: number }
  /** 保存・セッション・ファイルまわり（main.ts の handleFileMessage が受ける） */
  | { type: "restore" | "openFile" | "quickOpen" | "flushSession" | "saved" | "saveFailed" | "saveCancelled" | "closeDecision" | "checkFiles" | "diskChanged" | "conflictDecision"; [key: string]: unknown };

export type ToSwift =
  | { type: "ready" }
  | { type: "log"; event: string; detail?: string }
  /** メニューのキーに届かないショートカット（Ctrl+Tab）を Swift のメニュー操作に回す。
   *  hide_panel はメニューに無い操作で、最後のタブを閉じたときにウィンドウを隠す。
   *  ステータスバーのボタン（check_for_updates・reset_window_frame）もここを通る */
  | { type: "action"; action: string }
  /** 掴んでウィンドウを動かせる場所（タブバーの空き）。ページの左上からの位置 */
  | { type: "dragRegions"; rects: { x: number; y: number; width: number; height: number }[] }
  /** 保存・セッション・ファイルまわり（Swift の DocumentService が受ける） */
  | { type: "session" | "sessionSkipped" | "openPaths" | "quickOpenResend" | "save" | "confirmClose" | "fileStates" | "askConflict"; [key: string]: unknown };

/** 自走の検証で Swift から読む状態。Phase 2 の確認項目に合わせて増やす */
export interface DebugState {
  value: string;
  cursorCount: number;
  /** 各カーソル（選択）の位置。1 始まり */
  cursors: { line: number; column: number }[];
  focused: boolean;
  /** タブと分割の状態 */
  workspace: unknown;
  /** Cmd+P・言語の選択の一覧 */
  quickPick: unknown;
  /** 表示中の行に付いている色分けのクラスの種類（ハイライトが効いていれば 2 以上） */
  tokenClassCount: number;
  /** Monaco の worker を読み込めたか */
  workerLoaded: boolean;
  /** ステータスバーの版の表示 */
  statusVersion: { text: string; clickable: boolean };
}

export interface EditorHost {
  focus(): void;
  appear(): void;
  setContent(value: string, language?: string): void;
  command(name: string, index?: number): void;
  setAppInfo(info: Extract<FromSwift, { type: "appInfo" }>): void;
  handleFileMessage(msg: Extract<FromSwift, { [key: string]: unknown }>): void;
  debugState(): DebugState;
  /** エディタに文字を打てる状態か（mycast から貼るとき、フォーカスが戻ってから貼る） */
  editorFocused(): boolean;
  /** ファイルの名前と中身から決まる言語（dev 版の自走の検証用） */
  detectLanguage(path: string, content?: string): string;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { memode?: { postMessage(msg: unknown): void } } };
    memode: {
      receive(msg: FromSwift): void;
      debugState(): DebugState;
      editorFocused(): boolean;
      detectLanguage(path: string, content?: string): string;
    };
  }
}

export function post(msg: ToSwift): void {
  // ブラウザで単体で開いたとき（vite dev）は Swift が居ないので console に出す
  const handler = window.webkit?.messageHandlers?.memode;
  if (handler) handler.postMessage(msg);
  else console.log("[memode → swift]", msg);
}

export function install(host: EditorHost): void {
  window.memode = {
    receive(msg) {
      switch (msg.type) {
        case "focus":
          host.focus();
          break;
        case "appear":
          host.appear();
          break;
        case "setContent":
          host.setContent(msg.value, msg.language);
          break;
        case "command":
          host.command(msg.name, msg.index);
          break;
        case "appInfo":
          host.setAppInfo(msg);
          break;
        default:
          host.handleFileMessage(msg as Extract<FromSwift, { [key: string]: unknown }>);
      }
    },
    debugState: () => host.debugState(),
    editorFocused: () => host.editorFocused(),
    detectLanguage: (path, content) => host.detectLanguage(path, content),
  };
  // Ctrl+Tab は macOS のメニューのキーとしては届かないので、ここで拾って Swift に回す
  window.addEventListener(
    "keydown",
    (e) => {
      if (e.key === "Tab" && e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        e.stopPropagation();
        post({ type: "action", action: e.shiftKey ? "previous_tab" : "next_tab" });
      }
    },
    true,
  );
  // Swift はこれを受けてから、ためておいた要求を流す
  post({ type: "ready" });
}
