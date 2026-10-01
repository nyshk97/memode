#!/usr/bin/env python3
"""docs/CHANGELOG.md を扱う補助コマンド。release.sh から呼ぶ。

  changelog.py check                         [Unreleased] に内容があるか（無ければ exit 1）
  changelog.py release <version> <date>      [Unreleased] → [<version>] - <date> に切り出す
  changelog.py notes <version> <md> <html>   [<version>] セクションから
                                             GitHub Release 用 md と Sparkle 用 HTML を書く

CHANGELOG の書式は docs/CHANGELOG.md 冒頭の「書き方」を参照。
他の自作アプリの repo にも同じファイルを置いている（APP_NAME と CHANGELOG だけ違う）。
"""
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = REPO_ROOT / "docs" / "CHANGELOG.md"
APP_NAME = "Memode"

HEADING_RE = re.compile(r"^## \[([^\]]+)\]")


def sections(text):
    """(name, heading_line_index, body_start, body_end) を返す。``` フェンス内は無視する。"""
    lines = text.split("\n")
    heads = []
    in_fence = False
    for i, line in enumerate(lines):
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING_RE.match(line)
        if m:
            heads.append((m.group(1), i))
    out = []
    for k, (name, i) in enumerate(heads):
        end = heads[k + 1][1] if k + 1 < len(heads) else len(lines)
        out.append((name, i, i + 1, end))
    return lines, out


def section_body(text, name):
    lines, secs = sections(text)
    for n, _, s, e in secs:
        if n == name:
            return "\n".join(lines[s:e]).strip()
    return None


def read():
    if not CHANGELOG.exists():
        sys.exit(f"ERROR: {CHANGELOG} がありません")
    return CHANGELOG.read_text()


def unreleased_body(text):
    body = section_body(text, "Unreleased")
    if body is None:
        sys.exit("ERROR: CHANGELOG に '## [Unreleased]' セクションがありません")
    return body


def cmd_check():
    if not unreleased_body(read()):
        sys.exit(
            "ERROR: [Unreleased] が空です。\n"
            "       git log <前回タグ>..HEAD を読んで docs/CHANGELOG.md の [Unreleased] を埋め、\n"
            "       commit してから再実行してください（書き方は CHANGELOG 冒頭）。"
        )
    print("  CHANGELOG: [Unreleased] に内容あり")


def cmd_release(version, date):
    text = read()
    body = unreleased_body(text)
    already = section_body(text, version) is not None
    # 途中失敗後の再実行: [Unreleased] が空で [version] が既にあるならリネーム済み
    if already and not body:
        print(f"  CHANGELOG: [{version}] は既に存在し [Unreleased] は空 — リネーム済み（再実行）")
        return
    if already:
        sys.exit(f"ERROR: [{version}] が既に存在するのに [Unreleased] にも内容があります。手で整理してください")
    if not body:
        sys.exit("ERROR: [Unreleased] が空です")
    lines, secs = sections(text)
    idx = next(i for n, i, _, _ in secs if n == "Unreleased")
    lines[idx:idx + 1] = ["## [Unreleased]", "", f"## [{version}] - {date}"]
    CHANGELOG.write_text("\n".join(lines))
    print(f"  CHANGELOG: [Unreleased] → [{version}] - {date}")


def inline(text):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def cmd_notes(version, md_out, html_out):
    text = read()
    body = section_body(text, version)
    if body is None:
        sys.exit(f"ERROR: CHANGELOG に [{version}] セクションがありません")
    if not body:
        sys.exit(f"ERROR: [{version}] セクションが空です")

    pathlib.Path(md_out).write_text(f"# {APP_NAME} {version}\n\n{body}\n")

    # Sparkle の Update Notes は WKWebView で描画される。固定色を当てるとダーク背景に
    # 黒文字で読めなくなるので color-scheme でシステムに任せる。
    html = [
        "<style>:root{color-scheme:light dark}"
        "body{font:-apple-system-body;line-height:1.5}"
        "h3{font-size:14px;margin:16px 0 6px}ul{margin:0;padding-left:20px}li{margin:3px 0}"
        "code{background:rgba(127,127,127,0.18);padding:1px 5px;border-radius:3px;font-size:90%}"
        "</style>"
    ]
    in_ul = False
    for line in body.split("\n"):
        line = line.rstrip()
        if line.startswith("### "):
            if in_ul:
                html.append("</ul>")
                in_ul = False
            html.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            if not in_ul:
                html.append("<ul>")
                in_ul = True
            html.append(f"<li>{inline(line[2:].strip())}</li>")
    if in_ul:
        html.append("</ul>")
    pathlib.Path(html_out).write_text("\n".join(html) + "\n")
    print(f"  CHANGELOG: [{version}] → {md_out}, {html_out}")


def main(argv):
    if len(argv) >= 1 and argv[0] == "check":
        cmd_check()
    elif len(argv) == 3 and argv[0] == "release":
        cmd_release(argv[1], argv[2])
    elif len(argv) == 4 and argv[0] == "notes":
        cmd_notes(argv[1], argv[2], argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
