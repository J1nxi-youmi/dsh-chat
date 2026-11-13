"""Generate the rounded transparent Windows icon from assets/app_icon.png.

Usage: python tool/make_windows_icon.py
Requires Pillow (already available in the DSH Python environment).
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "app_icon.png"
PNG_OUT = ROOT / "tool" / "app_icon_rounded.png"
ICO_OUT = ROOT / "tool" / "app_icon.ico"

SIZE = 1024
RADIUS = 208
SCALE = 4


def main() -> None:
    image = Image.open(SOURCE).convert("RGBA").resize(
        (SIZE, SIZE), Image.Resampling.LANCZOS
    )

    mask = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, SIZE * SCALE - 1, SIZE * SCALE - 1),
        radius=RADIUS * SCALE,
        fill=255,
    )
    mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    image.putalpha(mask)

    image.save(PNG_OUT, optimize=True)
    image.save(
        ICO_OUT,
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"wrote {PNG_OUT}")
    print(f"wrote {ICO_OUT}")


if __name__ == "__main__":
    main()
