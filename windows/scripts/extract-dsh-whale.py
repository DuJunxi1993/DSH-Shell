#!/usr/bin/env python3
"""Extract dsh's whale from the installed dsh, and rasterise it into a mask.

    python scripts/extract-dsh-whale.py

Run before `make-icon.py` when dsh has been upgraded. It reads two things from
dsh and nothing else:

  * `FISH_LOGO_PATH` from `dsh-client-ui-primitives/lib/types/FishLogo.d.ts`
  * `FISH_LOGO_VIEWBOX` from `dsh-client-ui-primitives/lib/index.js`

and writes:

  * `scripts/dsh_whale_geometry.py` — the path and canvas, committed
  * `src-tauri/icons/dsh-whale.png` — the mask `make-icon.py` consumes, committed

## Why the output is committed

The build must not depend on dsh being installed. `dsh` is resolved through PATH
at runtime and the app is expected to work on a machine where the CLI is absent or
somewhere unusual, so the geometry lives in git and this script only *refreshes*
it. With no dsh found it still rasterises the committed geometry — which is why
the mask is reproducible on any machine, and why an unchanged extraction produces
no diff.

This mirrors `macos/tools/extract-dsh-logo.swift`, and the reason is the one in
its header: copying dsh's mark by hand means a dsh upgrade silently leaves the
app showing the old one, and nobody notices until someone compares it against the
web UI. That is exactly what happened to the PNG this replaced.

## The viewBox is the canvas, and the bounding box is not

`FISH_LOGO_VIEWBOX` is `23.16 x 17.04`. The path's own extremes are wider than
that — its minimum x is negative — so its bounding box comes out 23.3967 x
17.1921. Fitting the bounds instead of the viewBox draws the whale a couple of
percent larger than the web UI does and nudges it off centre, which is the trap
`docs/cross-platform-lessons.md` §1 records. This script only ever uses the
viewBox.

## The `.d.ts` has no numbers

`FishLogo.d.ts` declares `FISH_LOGO_VIEWBOX` as `{width: number; height: number}`
and never fills the values in, so both files are needed and a script that reads
one for both gets an empty result rather than an error.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEOMETRY = ROOT / "scripts" / "dsh_whale_geometry.py"
MASK = ROOT / "src-tauri" / "icons" / "dsh-whale.png"

# The mask is square with the viewBox letterboxed inside it, so the mark sits in
# the middle ~73% of it. `make-icon.py` crops to the ink before sizing, which is
# what keeps that padding from making the mark look small.
#
# 1024 rather than the 256 this replaced: `make-icon.py` scales the ink to 72% of a
# 1024 plate, so a 256px source was being interpolated upward roughly 3x.
MASK_SIZE = 1024

# The two files that hold the two halves of the answer.
DECLARATION = "types/FishLogo.d.ts"
BUNDLE = "index.js"


def candidate_lib_dirs() -> list[Path]:
    """Where `dsh-client-ui-primitives/lib` might be, most likely first.

    Two layouts, because Windows and macOS install the package differently and
    only one of them is obvious:

    * `macOS` resolves `bin/dsh` as a **symlink** into the package, so macOS's
      extractor walks up from the resolved executable and finds the primitives
      package as a sibling dependency.
    * On Windows the shim is `dsh.cmd` in the npm prefix and is not a symlink, so
      the package sits one level deeper — under `@deepseek-ai/dsh/node_modules/`.

    Both are probed, at every plausible root, rather than guessing which machine
    this is. The order is the one macOS and `ShellSettings.defaultBinaryPath()`
    use: the script should find the dsh the app would actually use, not whichever
    one happens to be first on PATH.
    """
    roots: list[Path] = []

    for key in ("NPM_CONFIG_PREFIX", "npm_config_prefix"):
        prefix = os.environ.get(key)
        if prefix:
            roots.append(Path(prefix))

    # `%APPDATA%\npm` is where a default Windows npm install puts its global tree.
    appdata = os.environ.get("APPDATA")
    if appdata:
        roots.append(Path(appdata) / "npm")

    shim = shutil.which("dsh.cmd") or shutil.which("dsh")
    if shim:
        here = Path(shim).resolve().parent
        for _ in range(6):
            roots.append(here)
            if here.parent == here:
                break
            here = here.parent

    package = Path("node_modules") / "@deepseek-ai"
    shapes = (
        package / "dsh-client-ui-primitives" / "lib",
        package / "dsh" / "node_modules" / "@deepseek-ai" / "dsh-client-ui-primitives" / "lib",
    )

    out: list[Path] = []
    for root in roots:
        for shape in shapes:
            candidate = root / shape
            if candidate.is_dir() and candidate not in out:
                out.append(candidate)
    return out


def parse_geometry(lib: Path) -> tuple[str, float, float, str] | None:
    """`(path_data, view_width, view_height, source)` or `None` if unreadable."""
    declaration = lib / DECLARATION
    bundle = lib / BUNDLE
    if not declaration.is_file() or not bundle.is_file():
        return None

    text = declaration.read_text(encoding="utf-8")
    # Match the assignment, not the bare name: the doc comment above the
    # declaration links to `{@link FISH_LOGO_PATH}` and comes first, so searching
    # for the identifier alone finds a comment with no quotes in it.
    match = re.search(r'const FISH_LOGO_PATH\s*=\s*"([^"]+)"', text)
    if not match or not match.group(1):
        return None
    path_data = match.group(1)

    # The viewBox values are in the bundled JS, because the declaration types them
    # as `number` and never fills them in.
    bundled = bundle.read_text(encoding="utf-8")
    anchor = bundled.find("FISH_LOGO_VIEWBOX = {")
    if anchor < 0:
        return None
    tail = bundled[anchor : anchor + 240]

    width = re.search(r"width:\s*([0-9.]+)", tail)
    height = re.search(r"height:\s*([0-9.]+)", tail)
    if not width or not height:
        return None

    return path_data, float(width.group(1)), float(height.group(1)), declaration.as_posix()


def render_geometry_module(path_data: str, width: float, height: float, source: str) -> str:
    """The committed geometry, as a Python module.

    A module rather than a data file so `make-icon.py` and the mask rasteriser can
    import it without a parser, and so a syntax error is a loud failure instead of
    an empty whale.
    """
    return f'''"""dsh's whale geometry — generated, do not edit.

Regenerate with `python scripts/extract-dsh-whale.py` from a machine that has dsh
installed. This file is committed so the icon builds without it.

Source: {source}

`width` / `height` are dsh's own `FISH_LOGO_VIEWBOX` — the canvas its `FishLogo`
component declares. It is deliberately *not* the path's bounding box: the path
overshoots the canvas (its minimum x is negative), so the bounds would render the
whale slightly larger and off centre. See `docs/cross-platform-lessons.md` §1.
"""

from __future__ import annotations

#: dsh's `FISH_LOGO_VIEWBOX.width` — the canvas, in SVG user units.
VIEW_WIDTH = {width}

#: dsh's `FISH_LOGO_VIEWBOX.height`.
VIEW_HEIGHT = {height}

#: The raw `d` attribute of dsh's `FISH_LOGO_PATH`. Uses only `M`, `L`, `C`, `Z`.
PATH_DATA = (
{_wrap(path_data)}
)
'''


def _wrap(path_data: str, limit: int = 88) -> str:
    """Split the path into quoted chunks, one Python line each.

    A single 3448-character literal would be one unreadable line and would defeat
    every diff — and this file exists partly so a changed whale is *visible* in a
    diff.
    """
    chunks = [path_data[i : i + limit] for i in range(0, len(path_data), limit)]
    return "\n".join(f'    "{chunk}"' for chunk in chunks)


def read_committed() -> tuple[str, float, float, str] | None:
    """The previously committed geometry, as a fallback when dsh is absent."""
    if not GEOMETRY.is_file():
        return None
    namespace: dict[str, object] = {}
    try:
        exec(compile(GEOMETRY.read_text(encoding="utf-8"), str(GEOMETRY), "exec"), namespace)
    except SyntaxError:
        return None
    try:
        return (
            str(namespace["PATH_DATA"]),
            float(namespace["VIEW_WIDTH"]),  # type: ignore[arg-type]
            float(namespace["VIEW_HEIGHT"]),  # type: ignore[arg-type]
            "the committed geometry (dsh not found)",
        )
    except (KeyError, TypeError, ValueError):
        return None


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import svg_path_fill

    found = None
    for lib in candidate_lib_dirs():
        found = parse_geometry(lib)
        if found:
            print(f"extract-dsh-whale: read {lib.parent.parent.parent.name} at {lib}")
            break
        found = None
    if not found:
        print("extract-dsh-whale: dsh not found; using the committed geometry")

    geometry = found or read_committed()
    if not geometry:
        print(
            "extract-dsh-whale: no dsh and no committed geometry to fall back on",
            file=sys.stderr,
        )
        return 1

    path_data, width, height, source = geometry
    if found:
        rendered = render_geometry_module(path_data, width, height, source)
        if GEOMETRY.is_file() and GEOMETRY.read_text(encoding="utf-8") == rendered:
            print("extract-dsh-whale: geometry unchanged")
        else:
            GEOMETRY.write_text(rendered, encoding="utf-8")
            print(f"extract-dsh-whale: wrote {GEOMETRY.relative_to(ROOT)}")

    commands = svg_path_fill.parse(path_data)
    if not svg_path_fill.has_geometry(commands):
        print("extract-dsh-whale: parsed no subpaths; refusing to write a blank mask", file=sys.stderr)
        return 1
    subpaths = sum(1 for command, _ in commands if command == "M")
    print(f"extract-dsh-whale: {subpaths} subpaths on a {width} x {height} canvas")

    mask = svg_path_fill.render(commands, width, height, MASK_SIZE)
    MASK.parent.mkdir(parents=True, exist_ok=True)
    mask.save(MASK)
    print(f"extract-dsh-whale: wrote {MASK.relative_to(ROOT)} ({MASK_SIZE}x{MASK_SIZE})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
