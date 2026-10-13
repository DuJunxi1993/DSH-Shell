#!/usr/bin/env python3
"""Fill an SVG path into an anti-aliased coverage mask, with Pillow only.

Written for dsh's whale, which has no `A`/`Q` arcs and no lowercase commands:
`M`, `L`, `C`, `Z` and nothing else. That is the whole grammar this module
accepts, and it refuses anything else rather than guessing — a path it
mis-parses would render as a plausible-looking wrong whale, which is exactly the
failure this file exists to end.

## Why not a real SVG library

The icon is built at most a few times a year, on a machine that may have none of
`cairosvg`, `resvg`, `rsvg-convert`, `inkscape` or ImageMagick. Pillow is already
required by `make-icon.py`, so the only new dependency is code.

The macOS shell made the same call for the same reason:
`macos/Sources/DSHShellCore/Services/SVGPathGeometry.swift` is its own parser,
and `macos/tools/extract-dsh-logo.swift` its own extractor.

## Why nonzero winding and not `ImageDraw.polygon`

The whale is four subpaths — one outline and three holes. Filling them in order
and hoping the outline happens to come first would work until dsh reorders them.
Winding is what an SVG fill actually means, so it is what this implements: each
scanline collects edge crossings, and a span is filled when the running winding
number is non-zero. That handles holes, nesting, and the outline's slight
overshoot past the viewBox without special cases.

## Anti-aliasing

By supersampling, not by blurring: the path is rasterised at `scale` times the
requested size and box-filtered down. An edge that lands mid-pixel becomes a
fractional coverage value, which is what a mask wants. No smoothing kernel is
applied here — `make-icon.py` applies its own blur, and two blurs would compound.
"""

from __future__ import annotations

import re

from PIL import Image

# One command letter, or one number. Matches the grammar dsh's path uses; a
# number may be signed and may be an exponent, which is what `float()` accepts but
# a naive `split()` does not.
_TOKEN = re.compile(r"[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")

# Parameter count per command. `Z` takes none.
_ARITY = {"M": 2, "L": 2, "C": 6, "Z": 0}

# How many line segments each cubic is flattened into. Fixed rather than
# curvature-adaptive: the whale's curves are all a few user units long at a
# 23-unit viewBox, so a fixed count is uniform in the only thing that matters
# (chord error in final pixels) and keeps the rasteriser deterministic.
_CURVE_STEPS = 24


class PathError(ValueError):
    """The path uses grammar this module does not implement."""


def parse(path_data: str) -> list[tuple[str, list[float]]]:
    """Split `d` into commands, expanding implicit repetitions.

    Returns `[("M", [x, y]), ("C", [x1, y1, x2, y2, x, y]), ("Z", []), ...]`.

    Implicit repetition is real SVG: `M x y x2 y2` is a moveto followed by a
    lineto, and `C` can repeat. dsh's path uses one such repetition, so a parser
    that reads only one parameter set per letter silently drops geometry — the
    whale comes out with a straight edge where a curve should be.
    """
    tokens = _TOKEN.findall(path_data)
    commands: list[tuple[str, list[float]]] = []
    index = 0
    cmd: str | None = None

    while index < len(tokens):
        token = tokens[index]
        if token.isalpha():
            cmd = token.upper()
            if cmd not in _ARITY:
                raise PathError(f"unsupported command {token!r}")
            index += 1
            if cmd == "Z":
                commands.append(("Z", []))
                cmd = None
                continue
        elif cmd is None:
            raise PathError(f"coordinates before any command: {token!r}")

        arity = _ARITY[cmd]
        if index + arity > len(tokens):
            raise PathError(f"{cmd} wants {arity} numbers, path ends early")
        raw = tokens[index:index + arity]
        try:
            numbers = [float(value) for value in raw]
        except ValueError as error:  # pragma: no cover - guarded by the regex
            raise PathError(f"{cmd} got a non-number: {raw!r}") from error
        commands.append((cmd, numbers))
        index += arity

        # A repeated `M` parameter set means `L`, per the SVG spec. Anything else
        # keeps its own command.
        if cmd == "M":
            cmd = "L"

    return commands


def contours(commands: list[tuple[str, list[float]]]) -> list[list[tuple[float, float]]]:
    """Flatten the commands into closed polygons, in SVG user units.

    Every contour is closed even when the path did not say `Z`, because a fill
    treats the implicit closing line as part of the shape. Leaving it open would
    drop the edge between the last point and the start, which shows up as a notch
    in the outline.
    """
    out: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    cursor: tuple[float, float] = (0.0, 0.0)
    start: tuple[float, float] = (0.0, 0.0)

    def flush() -> None:
        if len(current) >= 3:
            out.append(current.copy())
        current.clear()

    for cmd, args in commands:
        if cmd == "M":
            flush()
            cursor = start = (args[0], args[1])
            current.append(cursor)
        elif cmd == "L":
            cursor = (args[0], args[1])
            current.append(cursor)
        elif cmd == "C":
            x1, y1, x2, y2, x, y = args
            for step in range(1, _CURVE_STEPS + 1):
                t = step / _CURVE_STEPS
                u = 1.0 - t
                # Cubic Bézier, in the standard basis.
                bx = (u * u * u * cursor[0] + 3 * u * u * t * x1
                      + 3 * u * t * t * x2 + t * t * t * x)
                by = (u * u * u * cursor[1] + 3 * u * u * t * y1
                      + 3 * u * t * t * y2 + t * t * t * y)
                current.append((bx, by))
            cursor = (x, y)
        elif cmd == "Z":
            current.append(start)
            flush()
            cursor = start

    flush()
    return out


def render(
    commands: list[tuple[str, list[float]]],
    view_width: float,
    view_height: float,
    size: int,
    supersample: int = 3,
) -> Image.Image:
    """Rasterise to an `L`-mode coverage mask of `size` x `size`.

    The viewBox is **letterboxed** into the square rather than stretched: the
    whale's canvas is wider than it is tall (23.16 x 17.04), and squaring it in
    the raster would squash the mark before `make-icon.py` ever sees it.

    The mapping is `x / view_width`, `y / view_height` — the viewBox, not the
    path's bounding box. dsh's path overshoots the canvas (its minimum x is
    negative), so fitting the bounds would draw the whale a couple of percent
    larger than the web UI does. There is no y flip: SVG user space grows down
    and so does a raster.
    """
    if size <= 0:
        raise PathError("size must be positive")

    big = size * supersample
    scale = min(big / view_width, big / view_height)
    offset_x = (big - view_width * scale) / 2.0
    offset_y = (big - view_height * scale) / 2.0

    def project(point: tuple[float, float]) -> tuple[float, float]:
        return (point[0] * scale + offset_x, point[1] * scale + offset_y)

    polygons = [[project(p) for p in contour] for contour in contours(commands)]

    # Edge list: (y_top, y_bottom, x_at_y_top, dx/dy, direction). Direction is
    # what makes this winding and not even-odd.
    edges: list[tuple[float, float, float, float, int]] = []
    for polygon in polygons:
        for i, (x0, y0) in enumerate(polygon):
            x1, y1 = polygon[(i + 1) % len(polygon)]
            if y0 == y1:
                continue  # horizontal edges never cross a scanline
            direction = 1 if y1 > y0 else -1
            top, bottom = (y0, y1) if y1 > y0 else (y1, y0)
            slope = (x1 - x0) / (y1 - y0)
            edges.append((top, bottom, x0, slope, direction))

    # One flat buffer, written a span at a time.
    #
    # Per-pixel assignment through `Image.load()` is the obvious way to write this
    # and it is unusably slow: the whale covers several million pixels at 3x
    # supersampling, and each `pixels[x, y] = 255` is a Python-level call. Slice
    # assignment on a `bytearray` does the same work in C, and the whole raster is
    # one allocation rather than one per row.
    buffer = bytearray(big * big)
    span_bytes = bytes([255]) * big
    for row in range(big):
        y = row + 0.5  # sample at the pixel centre
        crossings: list[tuple[float, int]] = []
        for top, bottom, x_at_top, slope, direction in edges:
            # `top <= y < bottom` counts each crossing once, so a vertex shared by
            # two edges belongs to exactly one of them.
            if top <= y < bottom:
                crossings.append((x_at_top + (y - top) * slope, direction))
        if len(crossings) < 2:
            continue
        crossings.sort()
        base = row * big
        winding = 0
        for i in range(len(crossings) - 1):
            winding += crossings[i][1]
            if winding == 0:
                continue
            left = max(0, int(crossings[i][0] + 0.5))
            right = min(big, int(crossings[i + 1][0] + 0.5))
            if right > left:
                buffer[base + left : base + right] = span_bytes[: right - left]

    mask = Image.frombytes("L", (big, big), bytes(buffer))

    if supersample == 1:
        return mask
    return mask.resize((size, size), Image.BOX)


def has_geometry(commands: list[tuple[str, list[float]]]) -> bool:
    """Whether the path contains a subpath that could actually be filled."""
    moves = sum(1 for cmd, _ in commands if cmd == "M")
    return moves > 0
