"""Repack Unity's CC0 Houdini flipbooks with isolated, padded cells.

Usage: python prepare_flipbooks.py <directory containing the source .tga files>
Only a build-time conversion; Pillow and the source archives are not app dependencies.
"""
from pathlib import Path
import sys
from PIL import Image

source = Path(sys.argv[1])
destination = Path(__file__).resolve().parents[2] / "DroneUAVDemo/Resources/VFX"
destination.mkdir(parents=True, exist_ok=True)
for filename, name, columns, rows, tile_size in [
    ("Flame02_16x4.tga", "HoudiniFlame", 16, 4, (128, 256)),
    ("Explosion02HD_5x5.tga", "HoudiniBurst", 5, 5, (256, 256)),
    ("WispySmoke01_8x8.tga", "HoudiniSmoke", 8, 8, (128, 128)),
]:
    image = Image.open(source / filename).convert("RGBA")
    w, h = tile_size
    atlas = Image.new("RGBA", ((w + 4) * columns, (h + 4) * rows))
    for row in range(rows):
        for column in range(columns):
            rect = (round(column * image.width / columns), round(row * image.height / rows),
                    round((column + 1) * image.width / columns), round((row + 1) * image.height / rows))
            tile = image.crop(rect).resize(tile_size, Image.Resampling.LANCZOS)
            x, y = column * (w + 4) + 2, row * (h + 4) + 2
            atlas.paste(tile, (x, y))
            # Transparent gutters prevent even bilinear taps from seeing an adjacent frame.
    atlas.save(destination / (name + ".png"), optimize=True)
    print(name, atlas.size, (destination / (name + ".png")).stat().st_size)
