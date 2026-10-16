r"""Render icon candidates for review, without touching the repo's icons.

    python scripts/icon-sample.py

Writes PNGs to `%TEMP%/icon-sample/`. This exists so a design change can be
looked at before it is applied: `make-icon.py` regenerates the master PNG and
`cargo tauri icon` regenerates every size from it, and neither is pleasant to
undo. It imports `build()` from `make-icon`, so there is one copy of the geometry
and this file only varies the knobs.

Each candidate is also rendered at 64px, because the only size that actually
matters is the taskbar's, and it is the size at which a mark that is too small
looks smallest.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

# `make-icon.py` is not an importable module name — the hyphen is deliberate,
# since it is a script — so it is loaded by path rather than by name.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "make_icon", Path(__file__).resolve().parent / "make-icon.py"
)
make_icon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(make_icon)

WHALE = make_icon.WHALE
build = make_icon.build

OUT_DIR = Path(tempfile.gettempdir()) / "icon-sample"

# Sizes to compare, as a fraction of the plate's width. The shipped default is
# 0.72; the others bracket it.
VARIANTS = {
    "a-064": {"whale_fraction": 0.64},
    "b-072": {"whale_fraction": 0.72},
    "c-080": {"whale_fraction": 0.80},
}


def main() -> int:
    if not WHALE.exists():
        print(f"missing {WHALE}", file=sys.stderr)
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for stale in OUT_DIR.glob("*.png"):
        stale.unlink()

    made = []
    for name, kwargs in VARIANTS.items():
        image = build(**kwargs)
        image.save(OUT_DIR / f"{name}.png")
        image.resize((64, 64), Image.LANCZOS).save(OUT_DIR / f"{name}-64.png")
        made.append(OUT_DIR / f"{name}.png")

    # Side by side at full size, and again at taskbar size, because the two do not
    # pick the same winner.
    for label, images, size in (
        ("sheet", made, None),
        ("taskbar", [OUT_DIR / f"{n}-64.png" for n in VARIANTS], 4),
    ):
        if size is None:
            width, height = Image.open(images[0]).size
            sheet = Image.new("RGBA", (len(images) * width, height), (24, 24, 28, 255))
            for index, path in enumerate(images):
                sheet.alpha_composite(Image.open(path).convert("RGBA"), (index * width, 0))
            sheet.resize((sheet.width // 3, sheet.height // 3), Image.LANCZOS).save(
                OUT_DIR / f"{label}.png"
            )
        else:
            unit = 64 * size
            sheet = Image.new(
                "RGBA", (len(images) * (unit + 10) + 10, unit + 20), (32, 32, 36, 255)
            )
            for index, path in enumerate(images):
                thumb = Image.open(path).resize((unit, unit), Image.NEAREST)
                sheet.alpha_composite(thumb, (10 + index * (unit + 10), 10))
            sheet.save(OUT_DIR / f"{label}.png")

    for path in sorted(OUT_DIR.glob("*.png")):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
