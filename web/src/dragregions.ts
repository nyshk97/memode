import { post } from "./bridge";

type Rect = { x: number; y: number; width: number; height: number };

/** ウィンドウを掴んで動かせる場所（各タブバーのタブの右の空き）を Swift に知らせる。
 *  mousedown を JS から Swift に回してから動かし始めると間に合わないので、Swift が場所を覚えておき、
 *  mousedown のときに自分で判定する（PopupPanel.sendEvent）。変わったときだけ送る */
export class DragRegions {
  private last = "";
  private queued = false;

  constructor(private container: HTMLElement) {
    window.addEventListener("resize", () => this.update());
  }

  update(): void {
    if (this.queued) return;
    this.queued = true;
    requestAnimationFrame(() => {
      this.queued = false;
      const rects = this.rects();
      const json = JSON.stringify(rects);
      if (json === this.last) return;
      this.last = json;
      post({ type: "dragRegions", rects });
    });
  }

  rects(): Rect[] {
    const out: Rect[] = [];
    for (const bar of this.container.querySelectorAll<HTMLElement>(".tabbar")) {
      // タブがはみ出して横にスクロールしているときは空きが無い
      if (bar.scrollWidth > bar.clientWidth) continue;
      const r = bar.getBoundingClientRect();
      const tabs = bar.querySelectorAll(".tab");
      const left = Math.ceil(tabs.length > 0 ? tabs[tabs.length - 1].getBoundingClientRect().right : r.left);
      const right = Math.floor(r.right);
      if (right - left < 1) continue;
      out.push({ x: left, y: Math.round(r.top), width: right - left, height: Math.round(r.height) });
    }
    return out;
  }
}
