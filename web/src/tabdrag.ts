// タブのドラッグ&ドロップ（並べ替え・左右のグループへ移す・分割する）。
// HTML のドラッグ&ドロップ（draggable）は使わず、mousedown → mousemove → mouseup を自分で追う。
// タブの mousedown は preventDefault してエディタからフォーカスを奪わないようにしているので、draggable だと始まらない

/** どこに落とすか。tabs はタブバーの index 番目の前、group はそのグループの末尾、split は分割して右へ */
export type DropTarget =
  | { kind: "tabs"; group: number; index: number }
  | { kind: "group"; group: number }
  | { kind: "split" };

export interface DragSource {
  group: number;
  docId: number;
}

export interface DropHit {
  target: DropTarget;
  /** 落とし先の目印を出す場所（ページの左上から）。line はタブの間の縦線、area はエディタに重ねる面 */
  rect: { left: number; top: number; width: number; height: number };
  style: "line" | "area";
}

/** これだけ動かしたらドラッグとみなす（タブを押しただけで切り替えるときと区別する） */
const threshold = 4;

export class TabDrag {
  private pending?: { source: DragSource; ghost: HTMLElement; x: number; y: number; offsetX: number; offsetY: number };
  private dragging = false;
  private marker = document.createElement("div");

  constructor(
    private hitTest: (x: number, y: number, source: DragSource) => DropHit | null,
    private onDrop: (source: DragSource, target: DropTarget) => void,
  ) {
    this.marker.className = "drop-marker";
    document.body.append(this.marker);
    window.addEventListener("mousemove", (e) => this.move(e), true);
    window.addEventListener("mouseup", (e) => this.up(e), true);
    window.addEventListener(
      "keydown",
      (e) => {
        if (!this.dragging || e.key !== "Escape") return;
        e.preventDefault();
        e.stopPropagation();
        this.end();
      },
      true,
    );
  }

  /** タブの mousedown から呼ぶ。タブはこのあと描き直されるので、見た目はここで写しておく */
  begin(e: MouseEvent, source: DragSource, tab: HTMLElement): void {
    const r = tab.getBoundingClientRect();
    const ghost = tab.cloneNode(true) as HTMLElement;
    ghost.classList.add("tab-ghost", "active");
    ghost.classList.remove("dirty");
    ghost.style.width = `${r.width}px`;
    this.pending = { source, ghost, x: e.clientX, y: e.clientY, offsetX: e.clientX - r.left, offsetY: e.clientY - r.top };
  }

  private move(e: MouseEvent): void {
    const p = this.pending;
    if (!p) return;
    if (!this.dragging) {
      if (Math.abs(e.clientX - p.x) < threshold && Math.abs(e.clientY - p.y) < threshold) return;
      this.dragging = true;
      document.body.append(p.ghost);
      document.body.classList.add("tab-dragging");
    }
    e.preventDefault();
    e.stopPropagation();
    p.ghost.style.transform = `translate(${e.clientX - p.offsetX}px, ${e.clientY - p.offsetY}px)`;
    const hit = this.hitTest(e.clientX, e.clientY, p.source);
    if (!hit) {
      this.marker.style.display = "none";
      return;
    }
    const { rect, style } = hit;
    this.marker.className = `drop-marker ${style}`;
    Object.assign(this.marker.style, {
      display: "block",
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
    });
  }

  private up(e: MouseEvent): void {
    const p = this.pending;
    if (!p) return;
    const hit = this.dragging ? this.hitTest(e.clientX, e.clientY, p.source) : null;
    if (this.dragging) {
      e.preventDefault();
      e.stopPropagation();
    }
    this.end();
    if (hit) this.onDrop(p.source, hit.target);
  }

  private end(): void {
    this.pending?.ghost.remove();
    this.pending = undefined;
    this.dragging = false;
    this.marker.style.display = "none";
    document.body.classList.remove("tab-dragging");
  }
}
