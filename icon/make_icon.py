# Draws DeskBar's 32x32 pixel-art icon and scales it to 1024 px with nearest-neighbour (crisp pixels).
# Run: uv run --with pillow python icon/make_icon.py
from pathlib import Path
from PIL import Image

N, SCALE = 32, 32
BG, BG2 = (27, 36, 64), (36, 48, 84)          # navy, with a lighter floor band
WOOD, WOOD_HI, WOOD_LO = (201, 139, 75), (232, 172, 108), (138, 90, 43)
STEEL, STEEL_LO = (154, 163, 181), (92, 100, 120)
SCREEN, SCREEN_HI, BEZEL = (72, 196, 220), (160, 232, 244), (40, 44, 58)
ARROW, ARROW_LO = (91, 209, 110), (52, 150, 72)

img = Image.new("RGB", (N, N), BG)
px = img.load()

def rect(x0, y0, x1, y1, c):  # inclusive
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px[x, y] = c

rect(0, 27, 31, 31, BG2)                       # floor
# monitor
rect(10, 3, 21, 10, BEZEL)
rect(11, 4, 20, 9, SCREEN)
rect(11, 4, 14, 4, SCREEN_HI); rect(11, 5, 11, 6, SCREEN_HI)
rect(15, 11, 16, 11, BEZEL)                    # stand
# tabletop
rect(4, 12, 27, 14, WOOD)
rect(4, 12, 27, 12, WOOD_HI)
rect(4, 14, 27, 14, WOOD_LO)
# legs and feet
for x in (7, 23):
    rect(x, 15, x + 1, 26, STEEL)
    rect(x + 1, 15, x + 1, 26, STEEL_LO)
    rect(x - 2, 27, x + 3, 27, STEEL_LO)
# up/down arrow between the legs
rect(15, 17, 16, 24, ARROW)
for i, y in enumerate((16, 17, 18)):           # up head
    rect(15 - i, y, 16 + i, y, ARROW)
for i, y in enumerate((25, 24, 23)):           # down head
    rect(15 - i, y, 16 + i, y, ARROW)
rect(16, 18, 16, 23, ARROW_LO)                 # shading

out = Path(__file__).parent
img.save(out / "icon-32.png")
img.resize((N * SCALE, N * SCALE), Image.NEAREST).save(out / "icon-1024.png")
print("wrote", out / "icon-1024.png")
