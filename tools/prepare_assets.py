#!/usr/bin/env python3
"""Prepare BnB sprites/audio for Roblox upload.

Reads ../BnB/client/assets by default and writes:
  assets/prepared/manifest.json
  assets/prepared/images/<key>.png
  assets/prepared/audio/<key>.ogg
  tools/studio_asset_ids.json (template; existing IDs are preserved)

Requires ffmpeg on PATH. No Python third-party packages.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT.parent / "BnB" / "client" / "assets"
PREPARED = ROOT / "assets" / "prepared"
IMAGES_DIR = PREPARED / "images"
AUDIO_DIR = PREPARED / "audio"
STUDIO_IDS = ROOT / "tools" / "studio_asset_ids.json"

TEAM_COLORS = ("red", "blue", "green", "yellow", "purple", "orange")


@dataclass
class ImageSpec:
    key: str
    source: str
    width: int
    height: int
    cols: int = 1
    rows: int = 1
    frame_width: int | None = None
    frame_height: int | None = None
    scale: str | None = None
    display_name: str = ""
    generated: str | None = None


def image_specs() -> list[ImageSpec]:
    specs: list[ImageSpec] = [
        ImageSpec("img_floor_checker", "", 320, 320, generated="floor_checker",
                  display_name="BnB floor checker"),
        ImageSpec("img_box", "box.png", 160, 192, display_name="BnB soft box"),
        ImageSpec("img_crate", "crate.png", 160, 192, display_name="BnB crate"),
        ImageSpec("img_cannon", "cannon.png", 160, 320, display_name="BnB cannon"),
        ImageSpec("img_mast", "mast.png", 800, 960, display_name="BnB mast"),
        ImageSpec("img_explosion", "pic/Explosion.png", 980, 350, 14, 5, 70, 70,
                  "iw*7/16:ih*7/16", "BnB explosion"),
        ImageSpec("img_big_popo", "pic/BigPopo.png", 972, 108, 9, 1, 108, 108,
                  "iw*3/8:ih*3/8", "BnB big bubble"),
        ImageSpec("img_role1_die", "pic/Role1Die.png", 792, 150, 11, 1, 72, 150,
                  "iw*3/8:ih*3/8", "BnB baobao death"),
        ImageSpec("img_role2_die", "pic/Role2Die.png", 924, 147, 11, 1, 84, 147,
                  "iw*3/8:ih*3/8", "BnB pirate death"),
    ]

    for char in ("baobao", "haidao"):
        w, h = (96, 128) if char == "baobao" else (112, 134)
        for color in TEAM_COLORS:
            specs.append(ImageSpec(
                f"img_anim_{char}_{color}",
                f"anim/{char}_{color}.png",
                w * 6, h * 4, 6, 4, w, h, "iw/2:ih/2",
                f"BnB {char} walk {color}",
            ))

    for prefix in ("b", "r"):
        for i in range(3):
            specs.append(ImageSpec(
                f"img_popo_{prefix}{i}", f"popo/{prefix}{i}.png", 176, 164,
                display_name=f"BnB bubble {prefix}{i}",
            ))

    for char in ("baobao", "haidao"):
        for color in TEAM_COLORS:
            w = 180 if char == "baobao" else 232
            specs.append(ImageSpec(
                f"img_chars_{char}_{color}", f"chars/{char}_{color}.png",
                w, 224, display_name=f"BnB {char} portrait {color}",
            ))

    gifts = (
        ("1", "Gift1.png", 504, 180),
        ("2", "Gift2.png", 504, 180),
        ("3", "Gift3.png", 504, 180),
        ("6", "Gift6.png", 504, 184),
        ("7", "Gift7.png", 432, 152),
        ("8", "Gift8.png", 432, 164),
        ("9", "Gift9.png", 480, 164),
    )
    for n, src, w, h in gifts:
        specs.append(ImageSpec(
            f"img_gift{n}", f"pic/{src}", w, h, 3, 1, w // 3, h,
            display_name=f"BnB item Gift{n}",
        ))

    specs += [
        ImageSpec("img_item_gremlin", "items2/gremlin.png", 168, 180,
                  display_name="BnB gremlin"),
        ImageSpec("img_item_devil", "items2/devil.png", 168, 180,
                  display_name="BnB devil"),
        ImageSpec("img_item_needle", "items/needle.png", 112, 116,
                  display_name="BnB needle"),
        ImageSpec("img_item_remote", "items/remote.png", 136, 140,
                  display_name="BnB remote"),
        ImageSpec("img_item_pirate_turtle", "items/pirateTurtle.png", 432, 164,
                  3, 1, 144, 164, display_name="BnB pirate turtle icon"),
        ImageSpec("img_mount_turtle", "pic/SlowTurtle.png", 384, 512,
                  2, 4, 192, 128, display_name="BnB slow turtle"),
        ImageSpec("img_mount_owl", "pic/Owl.png", 320, 640,
                  2, 4, 160, 160, display_name="BnB owl"),
        ImageSpec("img_mount_pirate_turtle", "pic/Turtle.png", 384, 512,
                  2, 4, 192, 128, display_name="BnB pirate turtle"),
        ImageSpec("img_mount_ufo", "pic/FastUFO.png", 416, 496,
                  2, 4, 208, 124, display_name="BnB UFO"),
        ImageSpec("img_num_strip", "", 480, 40, 10, 1, 48, 40,
                  generated="num_strip", display_name="BnB numbers"),
        ImageSpec("img_win", "pic/Win.png", 816, 280, display_name="BnB win"),
        ImageSpec("img_draw", "pic/Draw.png", 816, 272, display_name="BnB draw"),
        ImageSpec("img_lose", "pic/lose.png", 816, 280, display_name="BnB lose"),
        ImageSpec("img_shadow_gift", "pic/ShadowGift.png", 36, 9,
                  display_name="BnB item shadow"),
        ImageSpec("img_shadow_role", "pic/ShadowRole.png", 32, 15,
                  display_name="BnB role shadow"),
    ]
    return specs


AUDIO_SPECS = {
    "sfx_bomb_set": ("snd/放置泡泡_bomb_set.mp3", "BnB bomb set"),
    "sfx_explode": ("snd/explode.wav", "BnB explosion"),
    "sfx_get": ("snd/get.wav", "BnB item get"),
    "sfx_save": ("snd/save.wav", "BnB bubble save"),
    "sfx_role_die": ("snd/role_die.mp3", "BnB character death"),
    "sfx_start": ("snd/start.wav", "BnB round start"),
    "sfx_victory": ("snd/victory.wav", "BnB victory"),
    "sfx_lose": ("snd/lose.wav", "BnB defeat"),
    "sfx_draw": ("snd/draw.wav", "BnB draw"),
    "bgm_game": ("snd/海盗船_patrit.mp3", "BnB game music"),
}
OPTIONAL_AUDIO = {
    "bgm_lobby": ("snd/游戏大厅_lobby_scene.mp3", "BnB lobby music"),
    "bgm_login": ("snd/登录_login.mp3", "BnB login music"),
}


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"not a PNG: {path}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def scale_image(src: Path, dst: Path, scale: str) -> None:
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-vf", f"scale={scale}:flags=lanczos",
        "-frames:v", "1", str(dst),
    ])


def make_floor_checker(source: Path, dst: Path) -> None:
    floor = source / "floor.png"
    floor_h = source / "floor_h.png"
    graph = (
        "[0:v]scale=160:160,split=2[a1][a2];"
        "[1:v]scale=160:160,split=2[b1][b2];"
        "[a1][b1]hstack[top];[b2][a2]hstack[bottom];"
        "[top][bottom]vstack[out]"
    )
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(floor), "-i", str(floor_h),
        "-filter_complex", graph, "-map", "[out]", "-frames:v", "1", str(dst),
    ])


def make_num_strip(source: Path, dst: Path) -> None:
    inputs: list[str] = []
    for i in range(10):
        inputs += ["-i", str(source / "num" / f"{i}.png")]
    graph = "".join(f"[{i}:v]" for i in range(10)) + "hstack=inputs=10[out]"
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        *inputs, "-filter_complex", graph, "-map", "[out]",
        "-frames:v", "1", str(dst),
    ])


def convert_audio(src: Path, dst: Path) -> None:
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-vn", "-ac", "2", "-ar", "44100",
        "-c:a", "vorbis", "-strict", "experimental", "-q:a", "6", str(dst),
    ])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--include-optional-audio", action="store_true")
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_dir():
        print(f"source asset directory not found: {source}", file=sys.stderr)
        return 1
    if shutil.which("ffmpeg") is None:
        print("ffmpeg is required", file=sys.stderr)
        return 1

    for directory in (IMAGES_DIR, AUDIO_DIR):
        directory.mkdir(parents=True, exist_ok=True)

    specs = image_specs()
    manifest = {"version": 1, "source": str(source), "images": {}, "audio": {}}

    for spec in specs:
        dst = IMAGES_DIR / f"{spec.key}.png"
        if spec.generated == "floor_checker":
            make_floor_checker(source, dst)
        elif spec.generated == "num_strip":
            make_num_strip(source, dst)
        else:
            src = source / spec.source
            if not src.is_file():
                print(f"missing image: {src}", file=sys.stderr)
                return 1
            if spec.scale:
                scale_image(src, dst, spec.scale)
            else:
                shutil.copy2(src, dst)

        width, height = png_size(dst)
        if (width, height) != (spec.width, spec.height):
            raise RuntimeError(
                f"{spec.key}: expected {spec.width}x{spec.height}, got {width}x{height}"
            )
        if max(width, height) > 1024:
            raise RuntimeError(f"{spec.key}: exceeds Roblox 1024 px limit")
        if spec.cols > 1 and width % spec.cols:
            raise RuntimeError(f"{spec.key}: width {width} not divisible by {spec.cols}")
        if spec.rows > 1 and height % spec.rows:
            raise RuntimeError(f"{spec.key}: height {height} not divisible by {spec.rows}")

        manifest["images"][spec.key] = {
            "file": f"images/{spec.key}.png",
            "assetType": "Image",
            "displayName": spec.display_name,
            "width": width,
            "height": height,
            "cols": spec.cols,
            "rows": spec.rows,
            "frameWidth": spec.frame_width or width // spec.cols,
            "frameHeight": spec.frame_height or height // spec.rows,
        }

    audio = dict(AUDIO_SPECS)
    if args.include_optional_audio:
        audio.update(OPTIONAL_AUDIO)
    for key, (src_rel, display_name) in audio.items():
        src = source / src_rel
        if not src.is_file():
            print(f"missing audio: {src}", file=sys.stderr)
            return 1
        dst = AUDIO_DIR / f"{key}.ogg"
        convert_audio(src, dst)
        manifest["audio"][key] = {
            "file": f"audio/{key}.ogg",
            "assetType": "Audio",
            "displayName": display_name,
        }

    manifest_path = PREPARED / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    # Preserve IDs already entered by hand; add new keys with an empty value.
    existing: dict[str, str] = {}
    if STUDIO_IDS.is_file():
        try:
            raw = json.loads(STUDIO_IDS.read_text())
            existing = {str(k): str(v or "") for k, v in raw.items()}
        except (json.JSONDecodeError, AttributeError):
            existing = {}
    keys = list(manifest["images"].keys()) + list(manifest["audio"].keys())
    template = {key: existing.get(key, "") for key in keys}
    STUDIO_IDS.parent.mkdir(parents=True, exist_ok=True)
    STUDIO_IDS.write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n")

    print(f"prepared {len(manifest['images'])} images and {len(manifest['audio'])} audio files")
    print(f"manifest: {manifest_path}")
    print(f"studio IDs: {STUDIO_IDS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
