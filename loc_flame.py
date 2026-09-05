#!/usr/bin/env python3
"""Generate an SVG icicle/flame graph of LOC per file.

Usage:
    python3 scripts/loc_flame.py [--out loc-flamegraph.svg] [--root src] [--extra build.zig,build.zig.zon,Config.zon]

Metric: non-blank lines. Excludes src/assets. Saves raw counts to /tmp/opencode/loc.json.
"""
import argparse
import hashlib
import html
import json
import pathlib

EXTS = {".zig", ".vert", ".frag", ".comp", ".glsl", ".zon"}
COLORS = ["#e76f51", "#f4a261", "#e9c46a", "#2a9d8f", "#219ebc",
          "#577590", "#9d4edd", "#ff70a6", "#70d6ff", "#95d5b2"]


def count_lines(path: pathlib.Path) -> tuple[int, int]:
    lines = path.read_text(errors="ignore").splitlines()
    blank = sum(1 for l in lines if not l.strip())
    return len(lines), len(lines) - blank


def collect(repo: pathlib.Path, roots: list[str], extras: list[str]):
    out = []
    for r in roots:
        for p in (repo / r).rglob("*"):
            if p.is_file() and p.suffix in EXTS and "assets" not in p.parts:
                total, nonblank = count_lines(p)
                out.append({"path": str(p.relative_to(repo)), "total": total, "nonblank": nonblank})
    for e in extras:
        p = repo / e
        if p.exists():
            total, nonblank = count_lines(p)
            out.append({"path": e, "total": total, "nonblank": nonblank})
    out.sort(key=lambda d: -d["nonblank"])
    return out


def build_tree(data):
    root = {"name": "all", "children": {}, "value": 0}
    for d in data:
        parts = pathlib.PurePath(d["path"]).parts
        node = root
        root["value"] += d["nonblank"]
        for p in parts:
            node = node["children"].setdefault(p, {"name": p, "children": {}, "value": 0})
            node["value"] += d["nonblank"]
    return root


def render(root, width=1600, row_h=24):
    def depth(n, d=0):
        if not n["children"]:
            return d
        return max(depth(c, d + 1) for c in n["children"].values())

    height = (depth(root) + 1) * row_h + 60
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" font-family="monospace">']
    n_files = sum(1 for _ in iter_leaves(root))
    out.append(f'<text x="10" y="20" font-size="14">LOC flame graph — non-blank lines, total {root["value"]} ({n_files} files)</text>')
    out.append("<style>rect:hover{stroke:#000;stroke-width:1.5}</style>")

    def draw(node, x, w, d, path):
        if w < 0.5:
            return
        color = COLORS[int(hashlib.md5("/".join(path).encode()).hexdigest(), 16) % len(COLORS)] if len(path) > 1 else "#dddddd"
        y = 40 + d * row_h
        pct = node["value"] / root["value"] * 100
        tip = f"{'/'.join(path)} — {node['value']} lines ({pct:.1f}%)"
        out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{row_h - 2}" fill="{color}" fill-opacity="0.85"><title>{html.escape(tip)}</title></rect>')
        if w > 60:
            out.append(f'<text x="{x + 4:.1f}" y="{y + 16}" font-size="12">{html.escape(node["name"])} {node["value"]}</text>')
        cx = x
        for k in sorted(node["children"].values(), key=lambda c: -c["value"]):
            kw = w * k["value"] / node["value"]
            draw(k, cx, kw, d + 1, path + [k["name"]])
            cx += kw

    draw(root, 10, width - 20, 0, ["all"])
    out.append("</svg>")
    return "\n".join(out), height


def iter_leaves(node):
    if not node["children"]:
        yield node
    for c in node["children"].values():
        yield from iter_leaves(c)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="loc-flamegraph.svg")
    ap.add_argument("--root", default="src")
    ap.add_argument("--extra", default="build.zig,build.zig.zon,Config.zon")
    ap.add_argument("--json", default="/tmp/opencode/loc.json")
    args = ap.parse_args()
    here = pathlib.Path(__file__).resolve().parent
    repo = here if (here / "src").is_dir() else here.parent
    data = collect(repo, [args.root], [e for e in args.extra.split(",") if e])
    if not data:
        raise SystemExit(f"no source files found under {[args.root] + [e for e in args.extra.split(',') if e]}")
    pathlib.Path(args.json).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.json).write_text(json.dumps(data, indent=1))
    svg, _ = render(build_tree(data))
    pathlib.Path(args.out).write_text(svg)
    print(f"wrote {args.out} ({len(data)} files, {sum(d['nonblank'] for d in data)} lines)")


if __name__ == "__main__":
    main()
