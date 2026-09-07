#!/usr/bin/env python3
"""Derive every branded raster in overlay/ from the brand master logo.svg.

Called by scripts/gen-icons.sh. Generates, per Environment:
  mipmap-<dpi>/icon.png             legacy launcher icon (white tile, mark)
  mipmap-<dpi>/icon_background.png  adaptive background layer (white)
  mipmap-<dpi>/icon_foreground.png  adaptive foreground layer (mark)
and, shared in overlay/common:
  drawable-hdpi/logo.png            login screen mark (full colour)
  drawable-hdpi/splash_image.png    splash mark (full colour)
  drawable-hdpi/drawer_logo.png     drawer header mark (white, on red header)

The staging icon carries a generated STG badge (spec: a visible badge tells
the two Environment builds apart on one device).

The current brand master is an SVG that only wraps raster <image> layers, so
this compositor resamples those rasters directly (LANCZOS) - higher fidelity
than rendering the SVG through a generic renderer. If the master gains real
vector content, this script refuses and asks for rsvg-convert.
"""
import base64
import io
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BRAND_RED = (0xB8, 0x08, 0x18, 255)        # red-600, brand primary
BADGE_BG = (0x0F, 0x17, 0x2A, 255)         # slate-900
TILE_RING = (0xE2, 0xE8, 0xF0, 255)        # slate-200
WHITE = (255, 255, 255, 255)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# density -> (legacy launcher px, adaptive layer px), upstream's exact sizes
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}
SS = 4  # supersampling factor for drawn geometry (tiles, badges)


def parse_master(path: Path):
    svg = path.read_text()
    view = re.search(r'viewBox="([\d. ]+)"', svg)
    if not view:
        sys.exit("gen-icons: master SVG has no viewBox")
    _, _, vw, vh = (float(v) for v in view.group(1).split())
    if re.search(r"<(path|rect|circle|polygon|polyline|ellipse|text)\b", svg):
        if shutil.which("rsvg-convert"):
            return ("rsvg", path, vw, vh)
        sys.exit(
            "gen-icons: the brand master now contains vector shapes; "
            "install rsvg-convert to rasterize it"
        )
    layers = []
    for x, y, w, h, data in re.findall(
        r'<image x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"'
        r' xlink:href="data:img/png;base64,([^"]+)"',
        svg,
    ):
        img = Image.open(io.BytesIO(base64.b64decode(data))).convert("RGBA")
        layers.append((float(x), float(y), float(w), float(h), img))
    if not layers:
        sys.exit("gen-icons: no raster layers found in the master SVG")
    return ("layers", layers, vw, vh)


def render_mark(master, size: int) -> Image.Image:
    """Render the master onto a transparent size x size square."""
    kind, payload, vw, vh = master
    if kind == "rsvg":
        out = subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size),
             "--keep-aspect-ratio", str(payload)],
            check=True, capture_output=True,
        ).stdout
        img = Image.open(io.BytesIO(out)).convert("RGBA")
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.alpha_composite(img, ((size - img.width) // 2, (size - img.height) // 2))
        return canvas
    scale = size / max(vw, vh)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for x, y, w, h, img in payload:
        resized = img.resize(
            (max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS
        )
        canvas.alpha_composite(resized, (round(x * scale), round(y * scale)))
    return canvas


def tint(img: Image.Image, rgba) -> Image.Image:
    """Recolour every pixel, keeping the alpha channel (mark is a red shape
    on transparency, so this yields the white drawer variant)."""
    out = Image.new("RGBA", img.size, rgba)
    out.putalpha(img.getchannel("A"))
    return out


def badge(width: int, height: int) -> Image.Image:
    """A generated STG pill, supersampled for smooth corners and text."""
    w, h = width * SS, height * SS
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=BADGE_BG)
    font = ImageFont.truetype(FONT, int(h * 0.58))
    draw.text((w / 2, h / 2 - h * 0.02), "STG", font=font, fill=WHITE, anchor="mm")
    return img.resize((width, height), Image.LANCZOS)


def rounded_tile(size: int) -> Image.Image:
    """White rounded-rect legacy tile with a subtle ring, supersampled."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    radius = round(s * 10 / 48)
    ring = max(1, round(s * 0.02))
    draw.rounded_rectangle([0, 0, s - 1, s - 1], radius=radius, fill=TILE_RING)
    draw.rounded_rectangle(
        [ring, ring, s - 1 - ring, s - 1 - ring], radius=radius - ring, fill=WHITE
    )
    return img.resize((size, size), Image.LANCZOS)


def paste_center(canvas: Image.Image, img: Image.Image, cx: float, cy: float):
    canvas.alpha_composite(
        img, (round(cx - img.width / 2), round(cy - img.height / 2))
    )


def legacy_icon(master, size: int, staged: bool) -> Image.Image:
    icon = rounded_tile(size)
    mark = render_mark(master, round(size * 0.72))
    paste_center(icon, mark, size / 2, size * (0.47 if staged else 0.5))
    if staged:
        bw, bh = round(size * 0.44), round(size * 0.22)
        b = badge(bw, bh)
        icon.alpha_composite(b, (size - bw - round(size * 0.03),
                                 size - bh - round(size * 0.03)))
    return icon


def adaptive_foreground(master, size: int, staged: bool) -> Image.Image:
    # Safe zone: central 66/108 circle. The mark sits slightly above centre,
    # the staging badge overlaps its lower edge like a sticker.
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if staged:
        mark = render_mark(master, round(size * 0.52))
        paste_center(fg, mark, size / 2, size * 0.45)
        b = badge(round(size * 0.28), round(size * 0.115))
        paste_center(fg, b, size / 2, size * 0.705)
    else:
        mark = render_mark(master, round(size * 0.56))
        paste_center(fg, mark, size / 2, size * 0.485)
    return fg


def folder_icons(upstream: Path, overlay: Path) -> None:
    """Re-tint upstream's baked-blue folder rasters to slate-500.

    ic_menu_archive is ownCloud steel blue (#55739A) baked into PNGs - the
    one blue the color overlays cannot reach. Slate-500 (#64748B) makes
    folders read neutral beside the red chrome. Same contract as every
    raster here: regenerate, never hand-edit.
    """
    target = (100, 116, 139)
    res = overlay / "common" / "owncloudApp/src/original/res"
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi"):
        src = (upstream / "owncloudApp/src/main/res" /
               f"drawable-{density}" / "ic_menu_archive.png")
        im = Image.open(src).convert("RGBA")
        tinted = Image.new("RGBA", im.size, target + (0,))
        tinted.putalpha(im.getchannel("A"))
        out = res / f"drawable-{density}"
        out.mkdir(parents=True, exist_ok=True)
        tinted.save(out / "ic_menu_archive.png", optimize=True)
    print("re-tinted folder icons into overlay/common")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "folder-icons":
        folder_icons(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    if len(sys.argv) != 3:
        sys.exit("usage: gen_icons.py <logo.svg> <overlay-dir>\n"
                 "       gen_icons.py folder-icons <upstream-dir> <overlay-dir>")
    master = parse_master(Path(sys.argv[1]))
    overlay = Path(sys.argv[2])
    res = "owncloudApp/src/original/res"

    for env in ("production", "staging"):
        staged = env == "staging"
        for dpi, (legacy, adaptive) in DENSITIES.items():
            out = overlay / env / res / f"mipmap-{dpi}"
            out.mkdir(parents=True, exist_ok=True)
            legacy_icon(master, legacy, staged).save(out / "icon.png")
            Image.new("RGBA", (adaptive, adaptive), WHITE).save(
                out / "icon_background.png"
            )
            adaptive_foreground(master, adaptive, staged).save(
                out / "icon_foreground.png"
            )
        print(f"generated launcher icons for {env}")

    common = overlay / "common" / res / "drawable-hdpi"
    common.mkdir(parents=True, exist_ok=True)
    for name, tinted in (("logo.png", False), ("splash_image.png", False),
                         ("drawer_logo.png", True)):
        w, h = (400, 218) if name == "drawer_logo.png" else (300, 149)
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        mark = render_mark(master, h)
        if tinted:
            mark = tint(mark, WHITE)
        paste_center(canvas, mark, w / 2, h / 2)
        canvas.save(common / name)
    print("generated login/splash/drawer marks in overlay/common")


if __name__ == "__main__":
    main()

