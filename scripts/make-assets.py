"""Builds VibeMeeting's asset catalog from the logo: macOS app icon, menu bar
template icons, and the accent color. Needs Pillow (pip3 install pillow).
Usage, from the repo root:
    python3 scripts/make-assets.py Design/logo.webp VibeMeeting/Assets.xcassets
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

logo_path, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

write_json(os.path.join(out, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

# ---------- App icon (macOS template: 824 px body on a 1024 canvas) ----------
SS = 4  # supersampling for smooth edges
canvas, body, radius = 1024, 824, 185
logo = Image.open(logo_path).convert("RGBA")
side = min(logo.size)
logo = logo.crop(((logo.width - side) // 2, (logo.height - side) // 2,
                  (logo.width + side) // 2, (logo.height + side) // 2))
art = logo.resize((body, body), Image.LANCZOS)

mask_big = Image.new("L", (body * SS, body * SS), 0)
ImageDraw.Draw(mask_big).rounded_rectangle((0, 0, body * SS - 1, body * SS - 1), radius=radius * SS, fill=255)
mask = mask_big.resize((body, body), Image.LANCZOS)

offset = (canvas - body) // 2
# Soft drop shadow, as in Apple's macOS icon template.
shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
shadow_mask = Image.new("L", (canvas, canvas), 0)
shadow_mask.paste(mask, (offset, offset + 10))
shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(14)).point(lambda a: int(a * 0.32))
shadow.putalpha(shadow_mask)

master = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
master.alpha_composite(shadow)
body_layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
body_layer.paste(art, (offset, offset), mask)
master.alpha_composite(body_layer)

icon_dir = os.path.join(out, "AppIcon.appiconset")
os.makedirs(icon_dir, exist_ok=True)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(icon_dir, name), optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
write_json(os.path.join(icon_dir, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})

# ---------- Menu bar template icons (18 pt) ----------
# Five rounded bars in the logo's proportions, spaced for legibility at 18 pt.
WIDTHS = [2.15, 2.35, 2.6, 2.4, 2.2]
HEIGHTS = [0.225, 0.56, 1.0, 0.56, 0.225]
GAP = 1.35

def bars(draw, scale, box_w, box_h, cx, cy, fill):
    total = sum(WIDTHS) + GAP * (len(WIDTHS) - 1)
    k = min(box_w / total, box_h / 1.0)
    x = cx - total * k / 2
    for w, h in zip(WIDTHS, HEIGHTS):
        bw, bh = w * k, max(h * box_h, w * k)
        draw.rounded_rectangle(
            ((x) * scale, (cy - bh / 2) * scale, (x + bw) * scale, (cy + bh / 2) * scale),
            radius=bw / 2 * scale, fill=fill)
        x += (w + GAP) * k

def menubar(name, live):
    d = os.path.join(out, f"{name}.imageset")
    os.makedirs(d, exist_ok=True)
    entries = []
    for scale in (1, 2):
        px = 18 * scale
        big = SS * 4
        img = Image.new("L", (px * big, px * big), 0)
        draw = ImageDraw.Draw(img)
        s = scale * big
        if live:
            # Filled circle with the bars knocked out, like an SF ".circle.fill" symbol.
            draw.ellipse((0.5 * s, 0.5 * s, 17.5 * s, 17.5 * s), fill=255)
            bars(draw, s, 11.0, 9.5, 9.0, 9.0, 0)
        else:
            bars(draw, s, 16.8, 15.0, 9.0, 9.0, 255)
        alpha = img.resize((px, px), Image.LANCZOS)
        rgba = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        rgba.putalpha(alpha)
        file = f"{name}{'@2x' if scale == 2 else ''}.png"
        rgba.save(os.path.join(d, file), optimize=True)
        entries.append({"filename": file, "idiom": "universal", "scale": f"{scale}x"})
    write_json(os.path.join(d, "Contents.json"), {
        "images": entries,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    })

menubar("MenuBarIdle", live=False)
menubar("MenuBarLive", live=True)

# ---------- Colors (from the logo's gradient) ----------
def colorset(name, light, dark=None):
    def comp(rgb):
        return {"color": {"color-space": "srgb", "components": {
            "red": f"{rgb[0] / 255:.3f}", "green": f"{rgb[1] / 255:.3f}", "blue": f"{rgb[2] / 255:.3f}", "alpha": "1.000"}},
            "idiom": "universal"}
    colors = [comp(light)]
    if dark:
        entry = comp(dark)
        entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        colors.append(entry)
    d = os.path.join(out, f"{name}.colorset")
    os.makedirs(d, exist_ok=True)
    write_json(os.path.join(d, "Contents.json"), {"colors": colors, "info": {"author": "xcode", "version": 1}})

# The system uses AccentColor only when the user's accent is "Multicolor"; the
# app also tints its windows with Brand.accent (same blue) so it always applies.
colorset("AccentColor", (10, 92, 255), (77, 141, 255))
