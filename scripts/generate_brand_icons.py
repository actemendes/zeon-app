#!/usr/bin/env python3
"""
Generate app icons from assets/images/SVG/logo-icon.svg with a safe container.

Usage:
  python scripts/generate_brand_icons.py
"""

from __future__ import annotations

import re
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw

try:
    from svgpathtools import parse_path
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Missing dependency 'svgpathtools'. Install with: python -m pip install --user svgpathtools"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]

# =============================================================================
# TUNABLE PARAMETERS (можно безопасно менять)
# =============================================================================
# 1) Источник логотипа (SVG)
LOGO_SVG = ROOT / "assets/images/SVG/logo-icon.svg"

# 2) Качество растеризации SVG -> PNG (влияет на сглаживание/скорость)
SVG_RENDER_BASE_WIDTH = 1400
SVG_OVERSAMPLE = 4
SVG_PATH_SAMPLES = 960

# 3) Базовая мастер-иконка приложения (квадрат)
MASTER_ICON_SIZE = 1024

# 4) Контейнер мастер-иконки: поля/радиус/цвета градиента
#    CONTAINER_PAD_RATIO: внутренние поля контейнера от края иконки
#    CONTAINER_RADIUS_RATIO: скругление контейнера
CONTAINER_PAD_RATIO = 0.15
CONTAINER_RADIUS_RATIO = 0.2
CONTAINER_GRADIENT_TOP = (246, 251, 255, 255)
CONTAINER_GRADIENT_BOTTOM = (223, 237, 255, 255)

# 5) Размер логотипа внутри контейнера (safe area)
MASTER_LOGO_WIDTH_RATIO = 0.35

# 6) Android notification / quick tile (монохром)
STAT_ICON_LOGO_WIDTH_RATIO = 0.50
STAT_ICON_MONO_COLOR = (255, 255, 255, 255)
ANDROID_STAT_SIZES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}

# 7) Android launcher sizes
ANDROID_LAUNCHER_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
ANDROID_PLAYSTORE_SIZE = 512

# 8) Android TV/banner
ANDROID_BANNER_SIZE = (320, 180)
ANDROID_BANNER_TILE_SIZE = 154
ANDROID_BANNER_BG_COLOR = (240, 243, 250, 255)

# 9) Web outputs
WEB_ICON_SIZE = 1024
WEB_PWA_SIZES = [192, 512]
WEB_FAVICON_SIZES = [16, 24, 32, 48, 64]

# 10) Desktop/source outputs
SNAP_ICON_SIZE = 256
SOURCE_NOTIFY_ICON_SIZE = 2048
SOURCE_FOREGROUND_LOGO_RATIO = 0.56
WINDOWS_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

# 11) Tray icons
TRAY_SOURCE_SIZE = 2048
TRAY_OUTPUT_SIZE = 128
TRAY_LOGO_WIDTH_RATIO = 0.76
TRAY_LIGHT_COLOR = (242, 242, 242, 255)
TRAY_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _save_png(path: Path, image: Image.Image) -> None:
    _ensure_parent(path)
    image.save(path, format="PNG", optimize=True)
    print(f"wrote {path.relative_to(ROOT)}")


def _save_webp(path: Path, image: Image.Image) -> None:
    _ensure_parent(path)
    image.save(path, format="WEBP", method=6, quality=100, lossless=True)
    print(f"wrote {path.relative_to(ROOT)}")


def _save_ico(path: Path, image: Image.Image, sizes: list[int]) -> None:
    _ensure_parent(path)
    ico_sizes = [(s, s) for s in sizes]
    image.save(path, format="ICO", sizes=ico_sizes)
    print(f"wrote {path.relative_to(ROOT)}")


def _vertical_gradient(size: int, top: tuple[int, int, int, int], bottom: tuple[int, int, int, int]) -> Image.Image:
    line = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / (size - 1) if size > 1 else 0.0
        rgba = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4))
        line.putpixel((0, y), rgba)
    return line.resize((size, size), Image.Resampling.BICUBIC)


def _parse_hex_color(value: str | None, default: tuple[int, int, int, int] = (0, 0, 0, 255)) -> tuple[int, int, int, int]:
    if not value:
        return default
    raw = value.strip()
    if raw.lower() == "none":
        return (0, 0, 0, 0)
    if raw.startswith("#"):
        code = raw[1:]
        if len(code) == 3:
            r = int(code[0] * 2, 16)
            g = int(code[1] * 2, 16)
            b = int(code[2] * 2, 16)
            return (r, g, b, 255)
        if len(code) == 6:
            r = int(code[0:2], 16)
            g = int(code[2:4], 16)
            b = int(code[4:6], 16)
            return (r, g, b, 255)
        if len(code) == 8:
            r = int(code[0:2], 16)
            g = int(code[2:4], 16)
            b = int(code[4:6], 16)
            a = int(code[6:8], 16)
            return (r, g, b, a)
    return default


def _parse_offset(value: str | None) -> float:
    if value is None:
        return 0.0
    raw = value.strip()
    if raw.endswith("%"):
        try:
            return max(0.0, min(1.0, float(raw[:-1]) / 100.0))
        except ValueError:
            return 0.0
    try:
        return max(0.0, min(1.0, float(raw)))
    except ValueError:
        return 0.0


def _parse_class_fills(root: ET.Element) -> dict[str, str]:
    class_fills: dict[str, str] = {}
    pattern = re.compile(r"\.([a-zA-Z0-9_-]+)\s*\{[^}]*fill\s*:\s*([^;]+);", re.IGNORECASE)
    for element in root.iter():
        if not element.tag.lower().endswith("style"):
            continue
        css = element.text or ""
        for class_name, fill_value in pattern.findall(css):
            class_fills[class_name.strip()] = fill_value.strip()
    return class_fills


def _parse_gradients(root: ET.Element) -> dict[str, dict[str, object]]:
    gradients: dict[str, dict[str, object]] = {}
    for element in root.iter():
        if not element.tag.lower().endswith("lineargradient"):
            continue
        grad_id = element.attrib.get("id")
        if not grad_id:
            continue
        x1 = float(element.attrib.get("x1", "0"))
        y1 = float(element.attrib.get("y1", "0"))
        x2 = float(element.attrib.get("x2", "1"))
        y2 = float(element.attrib.get("y2", "0"))
        stops: list[tuple[float, tuple[int, int, int, int]]] = []
        for stop in element:
            if not stop.tag.lower().endswith("stop"):
                continue
            color = _parse_hex_color(stop.attrib.get("stop-color"), default=(0, 0, 0, 255))
            offset = _parse_offset(stop.attrib.get("offset"))
            stops.append((offset, color))
        if not stops:
            continue
        stops.sort(key=lambda s: s[0])
        gradients[grad_id] = {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "stops": stops}
    return gradients


def _pick_fill_value(path_element: ET.Element, class_fills: dict[str, str]) -> str | None:
    fill = path_element.attrib.get("fill")
    if fill:
        return fill.strip()
    classes = (path_element.attrib.get("class") or "").split()
    for class_name in classes:
        if class_name in class_fills:
            return class_fills[class_name]
    return None


def _resolve_gradient_id(fill_value: str | None) -> str | None:
    if not fill_value:
        return None
    m = re.match(r"url\(#([^)]+)\)", fill_value.strip())
    if not m:
        return None
    return m.group(1)


def _build_linear_gradient_image(
    width: int,
    height: int,
    grad: dict[str, object],
    min_x: float,
    min_y: float,
    scale_x: float,
    scale_y: float,
) -> Image.Image:
    x1 = (float(grad["x1"]) - min_x) * scale_x
    y1 = (float(grad["y1"]) - min_y) * scale_y
    x2 = (float(grad["x2"]) - min_x) * scale_x
    y2 = (float(grad["y2"]) - min_y) * scale_y
    stops = grad["stops"]  # type: ignore[assignment]

    dx = x2 - x1
    dy = y2 - y1
    denom = dx * dx + dy * dy
    if denom <= 1e-6:
        color = stops[-1][1]
        return Image.new("RGBA", (width, height), color)

    xs = np.arange(width, dtype=np.float32)
    ys = np.arange(height, dtype=np.float32)
    grid_x, grid_y = np.meshgrid(xs, ys)
    t = ((grid_x - x1) * dx + (grid_y - y1) * dy) / denom
    t = np.clip(t, 0.0, 1.0)

    stops_pos = np.array([s[0] for s in stops], dtype=np.float32)
    stop_colors = np.array([s[1] for s in stops], dtype=np.float32)
    rgba = np.empty((height, width, 4), dtype=np.uint8)
    flat_t = t.reshape(-1)
    for channel in range(4):
        vals = np.interp(flat_t, stops_pos, stop_colors[:, channel])
        rgba[..., channel] = vals.reshape(height, width).astype(np.uint8)

    return Image.fromarray(rgba, mode="RGBA")


def _sample_svg_path_points(d: str, samples: int) -> list[tuple[float, float]]:
    path = parse_path(d)
    points: list[tuple[float, float]] = []
    for i in range(samples):
        t = i / (samples - 1)
        p = path.point(t)
        points.append((float(p.real), float(p.imag)))
    return points


def _render_logo() -> Image.Image:
    tree = ET.parse(LOGO_SVG)
    root = tree.getroot()
    view_box = root.attrib.get("viewBox")
    if not view_box:
        raise RuntimeError(f"Missing viewBox in {LOGO_SVG}")

    min_x, min_y, vb_w, vb_h = [float(v) for v in view_box.strip().split()]
    target_w = SVG_RENDER_BASE_WIDTH
    target_h = max(1, int(round(target_w * (vb_h / vb_w))))
    oversample = SVG_OVERSAMPLE
    canvas_w = target_w * oversample
    canvas_h = target_h * oversample

    scale_x = canvas_w / vb_w
    scale_y = canvas_h / vb_h

    logo = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(logo)
    class_fills = _parse_class_fills(root)
    gradients = _parse_gradients(root)
    gradient_cache: dict[str, Image.Image] = {}

    for element in root.iter():
        tag = element.tag.lower()
        if not tag.endswith("path"):
            continue
        d = element.attrib.get("d")
        if not d:
            continue

        # Number of interpolation points for bezier path rasterization.
        points = _sample_svg_path_points(d, samples=SVG_PATH_SAMPLES)
        mapped = [((x - min_x) * scale_x, (y - min_y) * scale_y) for x, y in points]
        fill_value = _pick_fill_value(element, class_fills)
        gradient_id = _resolve_gradient_id(fill_value)
        if gradient_id and gradient_id in gradients:
            mask = Image.new("L", (canvas_w, canvas_h), 0)
            mask_draw = ImageDraw.Draw(mask)
            mask_draw.polygon(mapped, fill=255)
            if gradient_id not in gradient_cache:
                gradient_cache[gradient_id] = _build_linear_gradient_image(
                    canvas_w,
                    canvas_h,
                    gradients[gradient_id],
                    min_x,
                    min_y,
                    scale_x,
                    scale_y,
                )
            logo.paste(gradient_cache[gradient_id], (0, 0), mask)
            continue

        fill = _parse_hex_color(fill_value, default=(69, 77, 88, 255))
        if fill[3] == 0:
            continue
        draw.polygon(mapped, fill=fill)

    logo = logo.resize((target_w, target_h), Image.Resampling.LANCZOS)
    bbox = logo.getbbox()
    if not bbox:
        raise RuntimeError(f"Logo has no visible pixels after rasterization: {LOGO_SVG}")
    return logo.crop(bbox)


def _recolor_logo(logo: Image.Image, color: tuple[int, int, int, int]) -> Image.Image:
    alpha = logo.split()[-1]
    solid = Image.new("RGBA", logo.size, color)
    solid.putalpha(alpha)
    return solid


def _compose_container(size: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Safe margins and corner rounding for the app icon container.
    pad = int(round(size * CONTAINER_PAD_RATIO))
    radius = int(round(size * CONTAINER_RADIUS_RATIO))
    rect = (pad, pad, size - pad, size - pad)

    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(rect, radius=radius, fill=255)

    gradient = _vertical_gradient(size, CONTAINER_GRADIENT_TOP, CONTAINER_GRADIENT_BOTTOM)
    layer.paste(gradient, (0, 0), mask)
    return layer


def _fit_logo(logo: Image.Image, target_width: int) -> Image.Image:
    h = max(1, int(round(target_width * logo.height / logo.width)))
    return logo.resize((target_width, h), Image.Resampling.LANCZOS)


def _compose_master_icon(size: int, logo: Image.Image) -> Image.Image:
    icon = _compose_container(size)
    logo_w = int(round(size * MASTER_LOGO_WIDTH_RATIO))
    logo_img = _fit_logo(logo, logo_w)

    x = (size - logo_img.width) // 2
    y = (size - logo_img.height) // 2

    icon.alpha_composite(logo_img, (x, y))
    return icon


def _compose_monochrome_stat(size: int, logo_mask: Image.Image) -> Image.Image:
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    logo_w = int(round(size * STAT_ICON_LOGO_WIDTH_RATIO))
    logo_img = _fit_logo(logo_mask, logo_w)
    x = (size - logo_img.width) // 2
    y = (size - logo_img.height) // 2
    icon.alpha_composite(logo_img, (x, y))
    return icon


def _compose_banner(master_icon: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", ANDROID_BANNER_SIZE, ANDROID_BANNER_BG_COLOR)

    tile = master_icon.resize((ANDROID_BANNER_TILE_SIZE, ANDROID_BANNER_TILE_SIZE), Image.Resampling.LANCZOS)
    x = (ANDROID_BANNER_SIZE[0] - tile.width) // 2
    y = (ANDROID_BANNER_SIZE[1] - tile.height) // 2
    canvas.alpha_composite(tile, (x, y))
    return canvas


def _compose_tray_icon(size: int, logo: Image.Image) -> Image.Image:
    tray = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    logo_w = int(round(size * TRAY_LOGO_WIDTH_RATIO))
    logo_img = _fit_logo(logo, logo_w)
    x = (size - logo_img.width) // 2
    y = (size - logo_img.height) // 2
    tray.alpha_composite(logo_img, (x, y))
    return tray


def _write_android_launcher(master: Image.Image) -> None:
    for bucket, px in ANDROID_LAUNCHER_SIZES.items():
        icon = master.resize((px, px), Image.Resampling.LANCZOS)
        _save_webp(ROOT / f"android/app/src/main/res/{bucket}/ic_launcher.webp", icon)
        _save_webp(ROOT / f"android/app/src/main/res/{bucket}/ic_launcher_round.webp", icon)

    playstore = master.resize((ANDROID_PLAYSTORE_SIZE, ANDROID_PLAYSTORE_SIZE), Image.Resampling.LANCZOS)
    _save_png(ROOT / "android/app/src/main/ic_launcher-playstore.png", playstore)


def _write_android_stat_icons(logo_mono: Image.Image) -> None:
    for bucket, px in ANDROID_STAT_SIZES.items():
        icon = _compose_monochrome_stat(px, logo_mono)
        _save_png(ROOT / f"android/app/src/main/res/{bucket}/ic_stat_logo.png", icon)


def _write_ios_and_macos(master: Image.Image) -> None:
    ios_root = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for path in sorted(ios_root.rglob("*.png")):
        with Image.open(path) as current:
            size = current.size
        icon = master.resize(size, Image.Resampling.LANCZOS)
        _save_png(path, icon)

    mac_root = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for path in sorted(mac_root.glob("*.png")):
        with Image.open(path) as current:
            size = current.size
        icon = master.resize(size, Image.Resampling.LANCZOS)
        _save_png(path, icon)


def _write_web(master: Image.Image) -> None:
    web_icon = master.resize((WEB_ICON_SIZE, WEB_ICON_SIZE), Image.Resampling.LANCZOS)
    _save_png(ROOT / "web/icon.png", web_icon)
    _save_ico(ROOT / "web/favicon.ico", web_icon, WEB_FAVICON_SIZES)

    icon_192 = master.resize((WEB_PWA_SIZES[0], WEB_PWA_SIZES[0]), Image.Resampling.LANCZOS)
    icon_512 = master.resize((WEB_PWA_SIZES[1], WEB_PWA_SIZES[1]), Image.Resampling.LANCZOS)
    _save_png(ROOT / "web/icons/Icon-192.png", icon_192)
    _save_png(ROOT / "web/icons/Icon-512.png", icon_512)


def _write_windows_linux_sources(master: Image.Image) -> None:
    master_1024 = master.resize((MASTER_ICON_SIZE, MASTER_ICON_SIZE), Image.Resampling.LANCZOS)
    _save_png(ROOT / "assets/images/source/ic_launcher_border.png", master_1024)
    _save_png(ROOT / "assets/images/source/ic_launcher_splash.png", master_1024)

    foreground = Image.new("RGBA", (MASTER_ICON_SIZE, MASTER_ICON_SIZE), (0, 0, 0, 0))
    logo = _render_logo()
    logo_mark = _fit_logo(logo, int(round(MASTER_ICON_SIZE * SOURCE_FOREGROUND_LOGO_RATIO)))
    x = (MASTER_ICON_SIZE - logo_mark.width) // 2
    y = (MASTER_ICON_SIZE - logo_mark.height) // 2
    foreground.alpha_composite(logo_mark, (x, y))
    _save_png(ROOT / "assets/images/source/ic_launcher_foreground.png", foreground)

    _save_png(
        ROOT / "snap/gui/app_icon.png",
        master.resize((SNAP_ICON_SIZE, SNAP_ICON_SIZE), Image.Resampling.LANCZOS),
    )

    _save_png(
        ROOT / "assets/images/source/ic_notify.png",
        master.resize((SOURCE_NOTIFY_ICON_SIZE, SOURCE_NOTIFY_ICON_SIZE), Image.Resampling.LANCZOS),
    )

    _save_ico(
        ROOT / "windows/runner/resources/app_icon.ico",
        master_1024,
        WINDOWS_ICO_SIZES,
    )
    _save_ico(
        ROOT / "assets/images/source/hiddify.ico",
        master_1024,
        WINDOWS_ICO_SIZES,
    )


def _write_android_banner(master: Image.Image) -> None:
    banner = _compose_banner(master)
    _save_png(ROOT / "android/app/src/main/res/mipmap-xhdpi/ic_banner.png", banner)


def _write_tray_icons(logo: Image.Image) -> None:
    colored_2048 = _compose_tray_icon(TRAY_SOURCE_SIZE, logo)
    white_logo = _recolor_logo(logo, TRAY_LIGHT_COLOR)
    white_2048 = _compose_tray_icon(TRAY_SOURCE_SIZE, white_logo)

    _save_png(ROOT / "assets/images/source/tray_icon.png", colored_2048)
    _save_png(ROOT / "assets/images/source/tray_icon_connected.png", colored_2048)
    _save_png(ROOT / "assets/images/source/tray_icon_disconnected.png", white_2048)

    colored_128 = colored_2048.resize((TRAY_OUTPUT_SIZE, TRAY_OUTPUT_SIZE), Image.Resampling.LANCZOS)
    white_128 = white_2048.resize((TRAY_OUTPUT_SIZE, TRAY_OUTPUT_SIZE), Image.Resampling.LANCZOS)
    _save_png(ROOT / "assets/images/tray_icon.png", colored_128)
    _save_png(ROOT / "assets/images/tray_icon_connected.png", colored_128)
    _save_png(ROOT / "assets/images/tray_icon_dark.png", white_128)
    _save_png(ROOT / "assets/images/tray_icon_disconnected.png", white_128)

    _save_ico(ROOT / "assets/images/tray_icon.ico", colored_2048, TRAY_ICO_SIZES)
    _save_ico(ROOT / "assets/images/tray_icon_connected.ico", colored_2048, TRAY_ICO_SIZES)
    _save_ico(ROOT / "assets/images/tray_icon_dark.ico", white_2048, TRAY_ICO_SIZES)
    _save_ico(ROOT / "assets/images/tray_icon_disconnected.ico", white_2048, TRAY_ICO_SIZES)


def main() -> None:
    logo = _render_logo()
    logo_mono_white = _recolor_logo(logo, STAT_ICON_MONO_COLOR)
    master = _compose_master_icon(MASTER_ICON_SIZE, logo)

    _write_android_launcher(master)
    _write_android_stat_icons(logo_mono_white)
    _write_android_banner(master)
    _write_ios_and_macos(master)
    _write_web(master)
    _write_windows_linux_sources(master)
    _write_tray_icons(logo)


if __name__ == "__main__":
    main()
