import { post } from "./bridge";
import type { Workspace } from "./workspace";

export interface CaretInfo {
  /** キャレットのある行の矩形（ページの左上からの位置。CSS px） */
  x: number;
  y: number;
  height: number;
  /** この位置を測ったときのページの大きさ（Swift はウィンドウの大きさと合っているときだけ使う） */
  viewportWidth: number;
  viewportHeight: number;
  /** 左右に分割しているか（分割しているときは広げたサイズで出す） */
  split: boolean;
}

/** キャレットの位置を Swift に知らせる。小さいサイズのとき、キャレットがマウスのそばに来るようにウィンドウを置くために使う。
 *  キャレットが見えていない（スクロールで外れた）ときは、エディタの文字を書く面の左上を送る。変わったときだけ送る */
export class CaretReporter {
  private last = "";
  private queued = false;
  /** 小さくした直後は、大きさが変わり終わるまでキャレットが見える所へスクロールし直す */
  private revealUntil = 0;

  constructor(private workspace: Workspace) {
    window.addEventListener("resize", () => this.update());
  }

  /** キャレットが見えていなければ、見える所までスクロールする（Swift がウィンドウを小さくしたとき） */
  reveal(): void {
    this.revealUntil = performance.now() + 600;
    this.revealNow();
  }

  update(): void {
    if (this.revealUntil > performance.now()) this.revealNow();
    if (this.queued) return;
    this.queued = true;
    requestAnimationFrame(() => {
      this.queued = false;
      const info = this.measure();
      const json = JSON.stringify(info);
      if (json === this.last) return;
      this.last = json;
      post({ type: "caret", ...info });
    });
  }

  private revealNow(): void {
    const editor = this.workspace.activeEditor;
    const pos = editor.getPosition();
    if (!pos) return;
    editor.layout();
    editor.revealPositionInCenterIfOutsideViewport(pos);
  }

  measure(): CaretInfo {
    const editor = this.workspace.activeEditor;
    // 出すときのアニメーション（body を少し縮めた状態から戻す。style.css の appear）の途中でも、縮める前の位置で測る
    const body = document.body.getBoundingClientRect();
    const sx = body.width > 0 ? document.body.offsetWidth / body.width : 1;
    const sy = body.height > 0 ? document.body.offsetHeight / body.height : 1;
    const raw = editor.getDomNode()!.getBoundingClientRect();
    const node = { left: (raw.left - body.left) * sx, top: (raw.top - body.top) * sy };
    const layout = editor.getLayoutInfo();
    const pos = editor.getPosition();
    const visible = pos ? editor.getScrolledVisiblePosition(pos) : null;
    const base = { viewportWidth: window.innerWidth, viewportHeight: window.innerHeight, split: this.workspace.isSplit };
    if (
      visible &&
      visible.top >= 0 &&
      visible.top + visible.height <= layout.height &&
      visible.left >= layout.contentLeft &&
      visible.left <= layout.width
    ) {
      return { x: Math.round(node.left + visible.left), y: Math.round(node.top + visible.top), height: Math.round(visible.height), ...base };
    }
    // 見えていない: 文字を書く面の左上（padding.top の分だけ下）
    const lineHeight = visible?.height ?? 18;
    return { x: Math.round(node.left + layout.contentLeft), y: Math.round(node.top + 8), height: Math.round(lineHeight), ...base };
  }
}
