#!/usr/bin/env python3
"""Generate the original AIUsage macOS app icon."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "Resources" / "AppIcon.iconset"
ICONSET.mkdir(parents=True, exist_ok=True)
SIZE = 1024
image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
pixels = image.load()
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)
        pixels[x, y] = (int(18 + 28 * t), int(24 + 26 * t), int(48 + 45 * t), 255)

draw = ImageDraw.Draw(image)
draw.rounded_rectangle((45, 45, 979, 979), radius=220, outline=(255, 255, 255, 28), width=8)
colors = [(25, 196, 196), (129, 87, 224), (84, 104, 232)]
for index, color in enumerate(colors):
    radius = 315 - index * 82
    box = (512 - radius, 512 - radius, 512 + radius, 512 + radius)
    draw.arc(box, 205, 505, fill=(*color, 255), width=46)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 230)
except OSError:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 230)
text = "AI"
box = draw.textbbox((0, 0), text, font=font)
draw.text(((SIZE - (box[2] - box[0])) / 2, (SIZE - (box[3] - box[1])) / 2 - 18), text, font=font, fill=(245, 247, 255, 255))

sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
for name, size in sizes.items():
    image.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / name)
print(ICONSET)
