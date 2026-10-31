# /// script
# dependencies = ["pillow"]
# ///
"""Draws every on-screen controller layout from tools/test_pad_layout.sh --json as PNGs (game picture, HUD zones,
iPhone Duo status pill, home bar, controls), for eyeballing a layout change before it goes on a phone.
    tools/test_pad_layout.sh --json > /tmp/pads.json && uv run tools/pad_preview.py /tmp/pads.json OUTDIR"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

HUD = [("minimap", .84, 0, 1, .23), ("quest", .79, .24, 1, .31), ("health", 0, 0, .30, .10), ("call", 0, .11, .155, .31),
       ("quick items", 0, .79, .165, 1), ("prompts", .875, .70, 1, .89), ("weapon / ammo", .86, .90, 1, 1), ("stance", .94, .92, 1, 1)]
LABEL = {"up": "▲", "down": "▼", "left": "◀", "right": "▶", "view": "⧉", "menu": "≡", "toggle": "pad", "stick": ""}

def main(src, out):
    os.makedirs(out, exist_ok=True)
    try: font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
    except OSError: font = ImageFont.load_default()
    for c in json.load(open(src)):
        k = 2; W, H = int(c["w"] * k), int(c["h"] * k)
        im = Image.new("RGB", (W, H), (0, 0, 0)); d = ImageDraw.Draw(im, "RGBA")
        px, py, pw, ph = (v * k for v in c["pic"])
        d.rectangle([px, py, px + pw, py + ph], fill=(38, 52, 70))
        for name, x0, y0, x1, y1 in HUD:
            d.rectangle([px + x0 * pw, py + y0 * ph, px + x1 * pw, py + y1 * ph], fill=(230, 160, 40, 90), outline=(230, 160, 40))
            d.text((px + x0 * pw + 4, py + y0 * ph + 2), name, fill=(255, 200, 90), font=font)
        t, l, b, r = (v * k for v in c["inset"])
        for box in ([0, 0, W, t], [0, 0, l, H], [0, H - b, W, H], [W - r, 0, W, H]):
            if box[2] > box[0] and box[3] > box[1]: d.rectangle(box, fill=(200, 40, 40, 70))
        cx0, cy0, cx1, cy1 = (v * k for v in c.get("cut", [0, 0, 0, 0]))
        if cx1 > cx0: d.rounded_rectangle([cx0, cy0, cx1, cy1], 16, fill=(200, 40, 40, 140), outline=(255, 80, 80))
        if c["duoInner"]: d.rounded_rectangle([W - 95 * k, 0, W, 108 * k], 20, fill=(220, 40, 220, 110), outline=(255, 90, 255))
        if b: d.rounded_rectangle([W / 2 - 75 * k, H - 14 * k, W / 2 + 75 * k, H], 8, fill=(255, 255, 255, 80))
        for name, (x, y, rr) in c["pads"].items():
            if x < -999: continue
            x, y, rr = x * k, y * k, rr * k
            d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(255, 255, 255, 40), outline=(255, 255, 255), width=3)
            s = LABEL.get(name, name); bb = d.textbbox((0, 0), s, font=font)
            d.text((x - (bb[2] - bb[0]) / 2, y - (bb[3] - bb[1]) / 2 - 4), s, fill=(255, 255, 255), font=font)
        d.text((10, H - 34), c["name"], fill=(140, 220, 255), font=font)
        im.save(os.path.join(out, c["name"] + ".png"))
        print(os.path.join(out, c["name"] + ".png"))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
