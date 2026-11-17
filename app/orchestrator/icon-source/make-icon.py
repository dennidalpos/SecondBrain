"""Draws the original SecondBrain orchestrator icon (1024x1024 PNG, transparent corners).

Usage: python -I make-icon.py icon-source.png
Then: npx tauri icon icon-source/icon-source.png -o <temp dir>, and copy the sizes listed in tauri.conf.json.
"""
import sys
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((64, 64, S - 64, S - 64), radius=200, fill=(18, 36, 66, 255))
# Three queue bars of decreasing length with a leading node: a task queue.
bars = [(560, (255, 255, 255, 255)), (440, (120, 190, 255, 255)), (320, (120, 190, 255, 255))]
for i, (w, color) in enumerate(bars):
    y = 300 + i * 190
    d.ellipse((220, y - 40, 300, y + 40), fill=(255, 196, 61, 255))
    d.rounded_rectangle((340, y - 36, 340 + w, y + 36), radius=36, fill=color)
img.save(sys.argv[1])
