// 上に出る、絞り込み付きの一覧（言語の選択。Phase 6 の Cmd+P でも使う）

export interface PickItem {
  label: string;
  detail?: string;
  value: string;
  /** 同じくらい一致したときに上に出す（最近使ったファイル） */
  boost?: number;
}

/** 文字が順に含まれていれば一致（あいまい検索）。連続して一致するほど・先頭に近いほど点が高い */
export function fuzzyScore(query: string, text: string): number | undefined {
  if (!query) return 0;
  const q = query.toLowerCase();
  const t = text.toLowerCase();
  let score = 0;
  let ti = 0;
  let prev = -2;
  for (const ch of q) {
    const found = t.indexOf(ch, ti);
    if (found < 0) return undefined;
    score += found === prev + 1 ? 5 : 1;
    if (found === 0) score += 3;
    prev = found;
    ti = found + 1;
  }
  return score - t.length * 0.01;
}

let current: { close(): void; shown(): PickItem[]; all(): PickItem[] } | undefined;

/** 自走の検証で読む */
export function quickPickDebug() {
  const all = current?.all() ?? [];
  return {
    open: current !== undefined,
    labels: current?.shown().slice(0, 10).map((i) => i.label) ?? [],
    count: all.length,
    // 少ないときだけ全部（自走の検証で「入っている・入っていない」を見る）
    allPaths: all.length <= 500 ? all.map((i) => i.value) : [],
  };
}

export function isQuickPickOpen(): boolean {
  return current !== undefined;
}

/** 選んだら onPick、Esc や外のクリックで閉じたら onCancel */
export function showQuickPick(opts: {
  placeholder: string;
  items: PickItem[];
  onPick(item: PickItem): void;
  onCancel(): void;
}): void {
  current?.close();
  const root = document.createElement("div");
  root.className = "quickpick";
  const input = document.createElement("input");
  input.placeholder = opts.placeholder;
  input.spellcheck = false;
  const list = document.createElement("div");
  list.className = "quickpick-list";
  root.append(input, list);
  document.body.append(root);

  let shown: PickItem[] = [];
  let selected = 0;
  const maxItems = 50;

  const render = () => {
    const q = input.value.trim();
    shown = opts.items
      .map((item) => {
        // ファイル名で一致するものを上に。パス（detail）まで含めても一致すれば候補に残す
        const byLabel = fuzzyScore(q, item.label);
        const byAll = fuzzyScore(q, (item.detail ? item.detail + "/" : "") + item.label);
        const base = byLabel !== undefined ? byLabel + 100 : byAll;
        const score = base === undefined ? undefined : base + (item.boost ?? 0);
        return { item, score };
      })
      .filter((x) => x.score !== undefined)
      .sort((a, b) => (q ? b.score! - a.score! : 0))
      .slice(0, maxItems)
      .map((x) => x.item);
    selected = Math.min(selected, Math.max(0, shown.length - 1));
    list.replaceChildren(
      ...shown.map((item, i) => {
        const row = document.createElement("div");
        row.className = "quickpick-item" + (i === selected ? " selected" : "");
        const label = document.createElement("span");
        label.textContent = item.label;
        row.append(label);
        if (item.detail) {
          const detail = document.createElement("span");
          detail.className = "detail";
          detail.textContent = item.detail;
          row.append(detail);
        }
        row.addEventListener("mousedown", (e) => {
          e.preventDefault();
          finish(item);
        });
        return row;
      }),
    );
    list.children[selected]?.scrollIntoView({ block: "nearest" });
  };

  const close = () => {
    root.remove();
    document.removeEventListener("mousedown", outside, true);
    current = undefined;
  };
  const finish = (item?: PickItem) => {
    close();
    if (item) opts.onPick(item);
    else opts.onCancel();
  };
  const outside = (e: MouseEvent) => {
    if (!root.contains(e.target as Node)) finish();
  };

  input.addEventListener("input", () => {
    selected = 0;
    render();
  });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing) return;
    if (e.key === "ArrowDown") selected = Math.min(selected + 1, shown.length - 1);
    else if (e.key === "ArrowUp") selected = Math.max(selected - 1, 0);
    else if (e.key === "Enter") return finish(shown[selected]);
    else if (e.key === "Escape") return finish();
    else return;
    e.preventDefault();
    render();
  });
  document.addEventListener("mousedown", outside, true);
  current = { close, shown: () => shown, all: () => opts.items };
  render();
  input.focus();
}
