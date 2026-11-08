#!/usr/bin/env python3
"""Patch the Hermes v0.23 dashboard Simplified-Chinese locale.

Upstream ``web/src/i18n/zh.ts`` is missing 114 keys that exist in ``en.ts``.
This installer-time patch reads the translation table next to this script
(``dashboard-zh-extra.json``) and inserts the 111 string entries into the
matching nested groups of ``<checkout>/web/src/i18n/zh.ts``.  The three
remaining keys are arrow functions and are inserted as a small TS block into
``pluginsPage``.

The patch is idempotent: it writes a trailing ``// HERMEMORY_ZH_EXTRA`` marker
and refuses to touch a file that already carries it.  If the upstream locale
does not look like the v0.23 baseline (different key count / missing groups /
different value shape), it prints ``skip:`` and leaves the file untouched.

Usage: patch_dashboard_zh.py <checkout-dir>
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys

MARK = "HERMEMORY_ZH_EXTRA"
HERE = pathlib.Path(__file__).resolve().parent
EXTRA_FILE = HERE / "dashboard-zh-extra.json"

# v0.23 zh.ts has 652 leaf entries; cron.scheduleModes.weekdaysShort is an
# array with 7 slots, which the dashboard's key counter reports as 658 keys.
BASE_LEAF_KEYS = 652
# SHA-256 of the sorted baseline leaf-key paths, so an upstream reshuffle that
# keeps the same count still fails safely instead of producing a broken file.
BASE_KEY_SHA256 = "492e6fe09c820378af56b5415614b41c1fcb39bc84a8155bf7578c13562a99d2"
EXPECTED_EXTRA_KEYS = 111
EXPECTED_TOTAL_LEAF_KEYS = BASE_LEAF_KEYS + EXPECTED_EXTRA_KEYS + 3  # +3 functions

FUNC_BLOCK = """    updateConsentBody: (name: string, sha: string) =>
      `插件目录中 ${name} 的新版本（${sha}）新增了已安装版本没有的功能入口。只有在你信任这些内容时才应用：`,
    updateScanBody: (name: string, count: number) =>
      `安全扫描在 ${name} 的新代码中发现 ${count} 处问题。只有在你信任来源时才更新：`,
    updateScanBlocked: (name: string) =>
      `安全扫描将 ${name} 的新代码评为危险。本次更新未应用。`,
"""
FUNC_KEYS = (
    "updateConsentBody",
    "updateScanBody",
    "updateScanBlocked",
)


class ParseError(Exception):
    pass


class Obj:
    __slots__ = ("start", "end", "entries", "order")

    def __init__(self, start: int) -> None:
        self.start = start
        self.end: int | None = None
        self.entries: dict[str, "Entry"] = {}
        self.order: list["Entry"] = []


class Entry:
    __slots__ = ("key", "key_pos", "value_start", "value_end", "obj")

    def __init__(self, key: str, key_pos: int, value_start: int) -> None:
        self.key = key
        self.key_pos = key_pos
        self.value_start = value_start
        self.value_end: int | None = None
        self.obj: Obj | None = None


class Parser:
    """A tiny scanner for the object-literal subset used by i18n locale files."""

    def __init__(self, source: str) -> None:
        self.s = source
        self.n = len(source)

    def skip_ws(self, i: int) -> int:
        s, n = self.s, self.n
        while i < n:
            c = s[i]
            if c in " \t\r\n":
                i += 1
            elif s.startswith("//", i):
                j = s.find("\n", i)
                i = n if j < 0 else j + 1
            elif s.startswith("/*", i):
                j = s.find("*/", i + 2)
                if j < 0:
                    raise ParseError("unterminated comment")
                i = j + 2
            else:
                break
        return i

    def skip_string(self, i: int) -> int:
        s, n = self.s, self.n
        quote = s[i]
        i += 1
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
            elif c == quote:
                return i + 1
            elif quote == "`" and c == "$" and i + 1 < n and s[i + 1] == "{":
                i = self.skip_template_expr(i + 2)
            else:
                i += 1
        raise ParseError("unterminated string")

    def skip_template_expr(self, i: int) -> int:
        s, n = self.s, self.n
        depth = 1
        while i < n:
            c = s[i]
            if c in "\"'`":
                i = self.skip_string(i)
            elif c == "{":
                depth += 1
                i += 1
            elif c == "}":
                depth -= 1
                i += 1
                if depth == 0:
                    return i
            else:
                i += 1
        raise ParseError("unterminated template expression")

    def skip_value(self, i: int) -> int:
        s, n = self.s, self.n
        depth = 0
        while i < n:
            c = s[i]
            if c in "\"'`":
                i = self.skip_string(i)
                continue
            if s.startswith("//", i) or s.startswith("/*", i):
                i = self.skip_ws(i)
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return i
                depth -= 1
            elif c == "," and depth == 0:
                return i
            i += 1
        return i

    def parse_key(self, i: int) -> tuple[str, int]:
        s, n = self.s, self.n
        if s[i] in "\"'":
            quote = s[i]
            j = i + 1
            out: list[str] = []
            while j < n:
                c = s[j]
                if c == "\\":
                    out.append(s[j : j + 2])
                    j += 2
                elif c == quote:
                    return "".join(out), j + 1
                else:
                    out.append(c)
                    j += 1
            raise ParseError("bad quoted key")
        m = re.match(r"[A-Za-z_$][\w$]*", s[i:])
        if not m:
            raise ParseError(f"bad key at offset {i}")
        return m.group(0), i + len(m.group(0))

    def parse_object(self, i: int) -> tuple[Obj, int]:
        s = self.s
        i = self.skip_ws(i)
        if i >= self.n or s[i] != "{":
            raise ParseError("expected {")
        obj = Obj(i)
        i += 1
        while True:
            i = self.skip_ws(i)
            if i >= self.n:
                raise ParseError("unexpected EOF in object")
            if s[i] == "}":
                obj.end = i + 1
                return obj, i + 1
            key_pos = i
            key, i = self.parse_key(i)
            i = self.skip_ws(i)
            if i >= self.n or s[i] != ":":
                raise ParseError(f"expected : after {key}")
            i = self.skip_ws(i + 1)
            entry = Entry(key, key_pos, i)
            if s[i] == "{":
                child, i = self.parse_object(i)
                entry.obj = child
            else:
                i = self.skip_value(i)
            entry.value_end = i
            if key in obj.entries:
                raise ParseError(f"duplicate key {key}")
            obj.entries[key] = entry
            obj.order.append(entry)
            i = self.skip_ws(i)
            if i < self.n and s[i] == ",":
                i += 1
                continue
            if i < self.n and s[i] == "}":
                obj.end = i + 1
                return obj, i + 1
            raise ParseError(f"expected , or }} after {key}")


def parse_locale(source: str) -> Obj:
    m = re.search(r"export\s+const\s+zh\s*:\s*Translations\s*=\s*", source)
    if not m:
        raise ParseError("export const zh: Translations = { not found")
    parser = Parser(source)
    root, _ = parser.parse_object(parser.skip_ws(m.end()))
    tail = parser.skip_ws(root.end)
    if source[tail:tail + 1] != ";":
        raise ParseError("locale does not end with };")
    return root


def leaves(obj: Obj, prefix: str = "") -> list[str]:
    out: list[str] = []
    for entry in obj.order:
        path = prefix + entry.key
        if entry.obj is None:
            out.append(path)
        else:
            out.extend(leaves(entry.obj, path + "."))
    return out


def scalar_line(key: str, value: str, indent: str) -> list[str]:
    literal = json.dumps(value, ensure_ascii=False)
    one = f"{indent}{key}: {literal},"
    if len(one) <= 100:
        return [one]
    return [f"{indent}{key}:", f"{indent}  {literal},"]


def render_object(key: str, subtree: dict, indent: str) -> list[str]:
    lines = [f"{indent}{key}: {{"]
    for child_key, child in subtree.items():
        if isinstance(child, dict):
            lines.extend(render_object(child_key, child, indent + "  "))
        else:
            lines.extend(scalar_line(child_key, child, indent + "  "))
    lines.append(f"{indent}}},")
    return lines


def group_subtree(extra: dict[str, str], group: str) -> dict:
    tree: dict = {}
    prefix = group + "."
    for dotted, value in extra.items():
        if not dotted.startswith(prefix):
            continue
        parts = dotted[len(prefix):].split(".")
        node = tree
        for part in parts[:-1]:
            node = node.setdefault(part, {})
            if not isinstance(node, dict):
                raise ParseError(f"conflicting key {dotted}")
        node[parts[-1]] = value
    return tree


def brace_indent(source: str, obj: Obj) -> tuple[int, str]:
    """Return (line start, indent) of the line holding this object's closing brace."""
    brace = obj.end - 1
    line_start = source.rfind("\n", 0, brace) + 1
    prefix = source[line_start:brace]
    if prefix.strip():
        raise ParseError("closing brace is not alone on its line")
    return line_start, prefix


def collect(
    obj: Obj,
    subtree: dict,
    source: str,
    additions: dict[int, list[str]],
    satisfied: set[str],
    prefix: str,
) -> None:
    line_start, indent = brace_indent(source, obj)
    child_indent = indent + "  "
    lines = additions.setdefault(line_start, [])
    for key, value in subtree.items():
        path = prefix + key
        existing = obj.entries.get(key)
        if isinstance(value, dict):
            if existing is None:
                lines.extend(render_object(key, value, child_indent))
                satisfied.update(collect_new_keys(value, path))
            elif existing.obj is None:
                raise ParseError(f"{path} is not an object upstream")
            else:
                collect(existing.obj, value, source, additions, satisfied, path + ".")
        else:
            if existing is not None:
                if existing.obj is not None:
                    raise ParseError(f"{path} is not a string upstream")
                satisfied.add(path)
                continue
            lines.extend(scalar_line(key, value, child_indent))
            satisfied.add(path)


def collect_new_keys(subtree: dict, prefix: str) -> set[str]:
    out: set[str] = set()
    for key, value in subtree.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            out.update(collect_new_keys(value, path))
        else:
            out.add(path)
    return out


def apply_insertions(source: str, insertions: dict[int, list[str]]) -> str:
    out = source
    for pos in sorted(insertions, reverse=True):
        text = "".join(line + "\n" for line in insertions[pos])
        out = out[:pos] + text + out[pos:]
    return out


def patch_locale(source: str, extra: dict[str, str]) -> tuple[str, str]:
    root = parse_locale(source)
    if MARK in source:
        return source, "already patched"

    current = sorted(leaves(root))
    fingerprint = hashlib.sha256("\n".join(current).encode("utf-8")).hexdigest()
    if len(current) != BASE_LEAF_KEYS or fingerprint != BASE_KEY_SHA256:
        raise ParseError(
            "unexpected zh.ts baseline: "
            f"{len(current)} keys, sha256 {fingerprint[:12]}…, expected v0.23 layout"
        )
    if len(extra) != EXPECTED_EXTRA_KEYS:
        raise ParseError(
            f"dashboard-zh-extra.json has {len(extra)} entries, expected {EXPECTED_EXTRA_KEYS}"
        )

    additions: dict[int, list[str]] = {}
    satisfied: set[str] = set()
    groups = []
    for dotted in extra:
        group = dotted.split(".", 1)[0]
        if group not in groups:
            groups.append(group)

    for group in groups:
        entry = root.entries.get(group)
        if entry is None or entry.obj is None:
            raise ParseError(f"top-level group {group} missing upstream")
        collect(
            entry.obj,
            group_subtree(extra, group),
            source,
            additions,
            satisfied,
            group + ".",
        )

    plugins = root.entries.get("pluginsPage")
    if plugins is None or plugins.obj is None:
        raise ParseError("pluginsPage group missing upstream")
    for key in FUNC_KEYS:
        if key in plugins.obj.entries:
            raise ParseError(f"pluginsPage.{key} already exists upstream")
    plugin_line_start, plugin_indent = brace_indent(source, plugins.obj)
    # Functions belong at the front of pluginsPage's new block.
    additions.setdefault(plugin_line_start, [])
    additions[plugin_line_start] = FUNC_BLOCK.rstrip("\n").splitlines() + additions[plugin_line_start]
    satisfied.update(f"pluginsPage.{key}" for key in FUNC_KEYS)

    expected = set(extra) | {f"pluginsPage.{key}" for key in FUNC_KEYS}
    missing = expected - satisfied
    if missing:
        raise ParseError(f"could not place {len(missing)} keys: {sorted(missing)[:3]}")

    root_line_start, root_indent = brace_indent(source, root)
    additions.setdefault(root_line_start, [])
    additions[root_line_start].insert(0, f"{root_indent or '  '}// {MARK}")

    patched = apply_insertions(source, additions)

    # Re-parse the result before touching the file.
    new_root = parse_locale(patched)
    new_leaves = leaves(new_root)
    if len(new_leaves) != EXPECTED_TOTAL_LEAF_KEYS:
        raise ParseError(
            f"post-patch key count {len(new_leaves)}, expected {EXPECTED_TOTAL_LEAF_KEYS}"
        )
    if not expected.issubset(set(new_leaves)):
        raise ParseError("post-patch validation lost keys")
    return patched, "patched"


NAV_LABELS = {
    'label: "Files"': 'label: "文件"',
    'label: "Channels"': 'label: "渠道"',
    'label: "Webhooks"': 'label: "回调"',
    'label: "Pairing"': 'label: "配对"',
}


SESSIONS_TEXT = {
    '<span className="text-xs text-muted-foreground">Total</span>':
        '<span className="text-xs text-muted-foreground">总数</span>',
    '<span className="text-xs text-muted-foreground">Active in store</span>':
        '<span className="text-xs text-muted-foreground">存储中活跃</span>',
    '<span className="text-xs text-muted-foreground">Archived</span>':
        '<span className="text-xs text-muted-foreground">已归档</span>',
    '<span className="text-xs text-muted-foreground">Messages</span>':
        '<span className="text-xs text-muted-foreground">消息</span>',
    '<span className="text-xs text-muted-foreground">Sources</span>':
        '<span className="text-xs text-muted-foreground">来源</span>',
    'return "Any chat source";': 'return "全部来源";',
    "Prune old sessions": "清理旧会话",
    "Import sessions": "导入会话",
}


def patch_sessions_page(checkout: pathlib.Path) -> None:
    """会话页的统计/按钮是硬编码 JSX 文本，不在 zh.ts 里；按字面量替换，天然幂等。"""
    page = checkout / "web" / "src" / "pages" / "SessionsPage.tsx"
    if not page.is_file():
        return
    text = page.read_text(encoding="utf-8")
    hits = 0
    for old, new in SESSIONS_TEXT.items():
        if old in text:
            text = text.replace(old, new)
            hits += 1
    if hits:
        page.write_text(text, encoding="utf-8")
        print(f"patched: SessionsPage.tsx strings x{hits}")


def patch_shell_texts(checkout: pathlib.Path) -> None:
    """侧栏硬编码英文标签 + 默认语言（都不在 zh.ts 里，改源码常量，天然幂等）。"""
    app = checkout / "web" / "src" / "App.tsx"
    if app.is_file():
        text = app.read_text(encoding="utf-8")
        hits = 0
        for old, new in NAV_LABELS.items():
            if old in text:
                text = text.replace(old, new)
                hits += 1
        if hits:
            app.write_text(text, encoding="utf-8")
            print(f"patched: App.tsx nav labels x{hits}")
    patch_sessions_page(checkout)
    ctx = checkout / "web" / "src" / "i18n" / "context.tsx"
    if ctx.is_file():
        text = ctx.read_text(encoding="utf-8")
        if "HERMEMORY_ZH_DEFAULT" not in text:
            old = '  return "en";\n}'
            if old in text:
                ctx.write_text(text.replace(old, '  return "zh"; // HERMEMORY_ZH_DEFAULT\n}', 1), encoding="utf-8")
                print("patched: context.tsx default locale -> zh")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_dashboard_zh.py <checkout-dir>", file=sys.stderr)
        return 2
    checkout = pathlib.Path(sys.argv[1]).resolve()
    patch_shell_texts(checkout)
    locale = checkout / "web" / "src" / "i18n" / "zh.ts"
    if not locale.is_file():
        print(f"skip: no {locale}")
        return 1
    try:
        extra = json.loads(EXTRA_FILE.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"skip: cannot read {EXTRA_FILE.name}: {exc}")
        return 1
    if not isinstance(extra, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in extra.items()
    ):
        print("skip: dashboard-zh-extra.json must be an object of strings")
        return 1
    try:
        source = locale.read_text(encoding="utf-8")
        if MARK in source:
            print(f"already patched: {locale} ({len(leaves(parse_locale(source)))} leaf keys)")
            return 0
        patched, status = patch_locale(source, extra)
    except ParseError as exc:
        print(f"skip: {exc} (zh.ts left untouched)")
        return 1
    except Exception as exc:
        print(f"skip: unexpected error: {exc} (zh.ts left untouched)")
        return 1
    if status == "patched":
        tmp = locale.with_name(locale.name + ".hm-zh-extra.tmp")
        tmp.write_text(patched, encoding="utf-8")
        os.replace(tmp, locale)
        print(f"patched: {locale} (+{len(extra)} strings, +3 functions, marker {MARK})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
