#!/usr/bin/env python3
"""Regenerate the README images (hero + terminal capture) in light and dark. Stdlib only."""
import html
import os

HERE = os.path.dirname(os.path.abspath(__file__))

THEMES = {
    "dark": dict(bg="#0d1117", panel="#161b22", line="#30363d", text="#e6edf3", dim="#8b949e",
                 ok="#3fb950", warn="#d29922", bad="#f85149", accent="#58a6ff"),
    "light": dict(bg="#ffffff", panel="#f6f8fa", line="#d0d7de", text="#1f2328", dim="#656d76",
                  ok="#1a7f37", warn="#9a6700", bad="#cf222e", accent="#0969da"),
}
FONT = "ui-sans-serif, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace"


def box(x, y, w, h, label, sub, c, stroke):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{c["panel"]}" stroke="{stroke}" stroke-width="1.5"/>'
            f'<text x="{x + w / 2}" y="{y + 30}" text-anchor="middle" font-family="{FONT}" font-size="17" font-weight="600" fill="{c["text"]}">{label}</text>'
            f'<text x="{x + w / 2}" y="{y + 52}" text-anchor="middle" font-family="{FONT}" font-size="12.5" fill="{c["dim"]}">{sub}</text>')


def arrow(x1, y1, x2, y2, color, dashed=False):
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2 - 7}" y2="{y2}" stroke="{color}" stroke-width="1.8"{dash}/>'
            f'<path d="M{x2 - 8},{y2 - 5} L{x2},{y2} L{x2 - 8},{y2 + 5} Z" fill="{color}"/>')


def hero(c):
    W, H = 1200, 330
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
         f'aria-label="hermes-safe-update: snapshot, hermes update, battery, then verified success or verified rollback">',
         f'<rect width="{W}" height="{H}" rx="16" fill="{c["bg"]}" stroke="{c["line"]}"/>',
         f'<text x="60" y="78" font-family="{MONO}" font-size="38" font-weight="700" fill="{c["text"]}">hermes-safe-update</text>',
         f'<text x="60" y="112" font-family="{FONT}" font-size="18" fill="{c["dim"]}">'
         'Run <tspan font-family="' + MONO + f'" fill="{c["text"]}">hermes update</tspan>. Prove the agent still answers. Roll back if it does not.</text>']
    y = 170
    s.append(box(60, y, 190, 70, "snapshot", "commit + configs + units", c, c["line"]))
    s.append(arrow(250, y + 35, 300, y + 35, c["dim"]))
    s.append(box(300, y, 190, 70, "hermes update", "the stock updater", c, c["line"]))
    s.append(arrow(490, y + 35, 540, y + 35, c["dim"]))
    s.append(box(540, y, 190, 70, "battery", "gateway · platforms · turn", c, c["accent"]))
    # success branch
    s.append(arrow(730, y + 20, 800, y - 2, c["ok"]))
    s.append(f'<rect x="800" y="{y - 32}" width="330" height="56" rx="10" fill="none" stroke="{c["ok"]}" stroke-width="1.5"/>')
    s.append(f'<text x="822" y="{y + 2}" font-family="{MONO}" font-size="16" font-weight="700" fill="{c["ok"]}">✓ VERIFIED SUCCESS</text>')
    # rollback branch
    s.append(arrow(730, y + 50, 800, y + 82, c["warn"]))
    s.append(f'<rect x="800" y="{y + 54}" width="330" height="56" rx="10" fill="none" stroke="{c["warn"]}" stroke-width="1.5"/>')
    s.append(f'<text x="822" y="{y + 82}" font-family="{MONO}" font-size="16" font-weight="700" fill="{c["warn"]}">↺ VERIFIED ROLLBACK</text>')
    s.append(f'<text x="822" y="{y + 101}" font-family="{FONT}" font-size="12.5" fill="{c["dim"]}">restore snapshot, run the battery again</text>')
    s.append("</svg>")
    return "".join(s)


# A real run from tests/e2e.sh (the platform scenario: the API server never comes up after the update),
# trimmed to the lines that tell the story.
TERMINAL = [
    ("dim", "$ hermes-safe-update -y"),
    ("text", "gateway     : [default] running, pid 931601, platforms: api_server, webhook"),
    ("text", "--- battery (preflight) ---"),
    ("ok", "  ✓ platforms [default]: api_server, webhook connected"),
    ("text", "snapshot 20261001-184215: 73f2d1f3a6 on main, 2 file(s) copied"),
    ("text", "=== upstream `hermes update` ==="),
    ("dim", "    ✓ Update complete! (git.73f2d1f → git.cbfdea9) [main @ cbfdea97]"),
    ("dim", "      ✓ Restarted hermes-gateway"),
    ("dim", "      ✓ default (pid 934614) @ cbfdea97 — up to date"),
    ("text", "--- battery (update) ---"),
    ("ok", "  ✓ gateway [default]: running on cbfdea97ea (pid 934614)"),
    ("ok", "  ✓ gateway [default]: same process after the settle window"),
    ("bad", "  ✗ platforms [default]: connected before the update but not now: api_server"),
    ("warn", "=== ROLLBACK to snapshot 20261001-184215 (73f2d1f3a6): the battery failed on the new code ==="),
    ("dim", "    ✓ User service restarted (PID 936903)"),
    ("ok", "  ✓ gateway [default]: running on 73f2d1f3a6 (pid 936903)"),
    ("ok", "  ✓ platforms [default]: api_server, webhook connected"),
    ("warn", "=== VERIFIED ROLLBACK: back on 73f2d1f3a6, battery green ==="),
]


def terminal(c):
    lh, pad_top = 21, 52
    W, H = 1200, pad_top + lh * len(TERMINAL) + 24
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
         'aria-label="Terminal output of a run where the update broke the API server and was rolled back">',
         f'<rect width="{W}" height="{H}" rx="12" fill="{c["bg"]}" stroke="{c["line"]}"/>',
         f'<rect width="{W}" height="34" rx="12" fill="{c["panel"]}"/><rect y="22" width="{W}" height="12" fill="{c["panel"]}"/>',
         f'<line x1="0" y1="34" x2="{W}" y2="34" stroke="{c["line"]}"/>']
    for i, col in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        s.append(f'<circle cx="{22 + i * 20}" cy="17" r="6" fill="{col}"/>')
    s.append(f'<text x="{W / 2}" y="22" text-anchor="middle" font-family="{FONT}" font-size="12.5" fill="{c["dim"]}">'
             'the update broke the API server; upstream said "up to date"</text>')
    for i, (kind, text) in enumerate(TERMINAL):
        s.append(f'<text x="22" y="{pad_top + i * lh + 8}" font-family="{MONO}" font-size="14" fill="{c[kind]}" '
                 f'xml:space="preserve">{html.escape(text)}</text>')
    s.append("</svg>")
    return "".join(s)


for theme, colors in THEMES.items():
    for name, fn in (("hero", hero), ("rollback", terminal)):
        with open(os.path.join(HERE, f"{name}-{theme}.svg"), "w", encoding="utf-8") as f:
            f.write(fn(colors))
print("ok")
