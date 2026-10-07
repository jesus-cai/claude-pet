#!/usr/bin/env python3
"""Genera "Mochi", la mascota de ejemplo, como atlas Codex v2 (8x11, celdas 192x208).

Es pixel art procedural: se dibuja en una grilla de 48x52 y se agranda x4 con vecino
más cercano. Sirve de mascota por defecto y de plantilla para ver qué espera cada
fila del atlas. Uso:

    python3 tools/make_demo_pet.py pets/mochi
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image

GW, GH, K = 48, 52, 4                     # grilla base y factor de escala
COLS, ROWS = 8, 11
OUT_W, OUT_H = GW * K, GH * K             # 192 x 208

INK = (74, 40, 56, 255)
BODY = (247, 190, 170, 255)
SHADE = (232, 154, 140, 255)
LIGHT = (255, 232, 220, 255)
FEET = (214, 124, 116, 255)
BLUSH = (240, 120, 130, 255)
WHITE = (255, 255, 255, 255)
LEAF = (110, 186, 104, 255)
LEAF_D = (64, 128, 70, 255)
DROP = (120, 190, 240, 255)


def blank():
    return [[None] * GW for _ in range(GH)]


def put(g, x, y, c):
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)   # round() de Python redondea al par
    if 0 <= x < GW and 0 <= y < GH:
        g[y][x] = c


def draw_pet(*, dx=0, dy=0, sx=1.0, sy=1.0, eyes="open", look=(0, 0), arms=(0, 0),
             feet=(0, 0), leaf=0, drop=False, mouth="smile", facing=0):
    """Dibuja un cuadro. arms: altura de cada bracito (0 abajo, 1 medio, 2 arriba,
    -1 al frente). feet: desplazamiento vertical de cada pie. facing: -1/0/1."""
    g = blank()
    cx, base = 24 + dx, 47 + dy               # base = línea de las suelas
    rx, ry = 13.5 * sx, 12.5 * sy
    cy = base - 3 - ry

    # pies (detrás del cuerpo)
    for i, fx in enumerate((-6, 6)):
        fy = base - 1 + feet[i] - (0 if i == 0 else 0)
        for x in range(-3, 3):
            for y in range(-2, 1):
                if (x + 0.5) ** 2 / 9 + (y + 0.5) ** 2 / 4 <= 1:
                    put(g, cx + fx + x + facing, fy + y, FEET)

    # cuerpo
    inside = set()
    for y in range(GH):
        for x in range(GW):
            if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1:
                inside.add((x, y))
    for (x, y) in inside:
        nx, ny = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
        c = BODY
        if nx * 0.6 + ny * 0.8 > 0.55:
            c = SHADE
        if (nx + 0.45) ** 2 + (ny + 0.5) ** 2 < 0.06:
            c = LIGHT
        put(g, x, y, c)

    # bracitos
    for side, h in ((-1, arms[0]), (1, arms[1])):
        ax = cx + side * (rx + 0.5)
        ay = cy + 3 - h * 4
        if h == -1:                          # al frente, "tecleando"
            ax, ay = cx + side * 5, cy + ry - 3
        for x in range(-2, 2):
            for y in range(-1, 2):
                if (x + 0.5) ** 2 / 4 + y ** 2 / 2.2 <= 1:
                    put(g, ax + x, ay + y, BODY)

    # hojita
    top = cy - ry
    sway = leaf
    put(g, cx + sway * 0.5, top - 1, LEAF_D)
    put(g, cx + sway, top - 2, LEAF_D)
    for x in range(0, 5):
        for y in range(-2, 1):
            if (x - 2) ** 2 / 5 + (y + 0.5) ** 2 / 1.6 <= 1:
                put(g, cx + sway + x, top - 3 + y, LEAF)
    put(g, cx + sway + 1, top - 3, LEAF_D)

    # cara
    ex, ey = cx + facing * 2 + look[0], cy - 1 + look[1]
    for side in (-1, 1):
        x0 = ex + side * 5
        if eyes == "open" or eyes == "big":
            wid, hgt = (3, 4) if eyes == "big" else (2, 3)
            for x in range(wid):
                for y in range(hgt):
                    put(g, x0 - 1 + x, ey - 1 + y, INK)
            if eyes == "big":
                put(g, x0 - 1, ey - 1, WHITE)
        elif eyes == "blink":
            for x in range(-1, 2):
                put(g, x0 + x, ey + 1, INK)
        elif eyes == "happy":                # ^ ^
            put(g, x0 - 1, ey + 1, INK); put(g, x0, ey, INK); put(g, x0 + 1, ey + 1, INK)
        elif eyes == "focus":                # – –, un poco más bajos
            for x in range(-1, 2):
                put(g, x0 + x, ey + 1, INK)
            put(g, x0 - side, ey, INK)
        elif eyes == "sad":                  # > <
            put(g, x0 - side, ey - 1, INK); put(g, x0, ey, INK); put(g, x0 - side, ey + 1, INK)
    # mejillas
    for side in (-1, 1):
        put(g, ex + side * 8, ey + 3, BLUSH)
        put(g, ex + side * 8 + side, ey + 3, BLUSH)
    # boca
    mx, my = ex, ey + 4
    if mouth == "smile":
        put(g, mx - 1, my, INK); put(g, mx, my + 1, INK); put(g, mx + 1, my, INK)
    elif mouth == "open":
        put(g, mx, my, INK); put(g, mx - 1, my + 1, INK); put(g, mx, my + 1, BLUSH); put(g, mx + 1, my + 1, INK)
    elif mouth == "flat":
        put(g, mx - 1, my, INK); put(g, mx, my, INK)
    elif mouth == "o":
        put(g, mx, my, INK); put(g, mx, my + 1, INK)
    elif mouth == "wobbly":
        put(g, mx - 1, my + 1, INK); put(g, mx, my, INK); put(g, mx + 1, my + 1, INK)

    # gota de sudor pegada a la cabeza (efecto "adherido", como pide el contrato)
    if drop:
        bx, by = cx + rx - 3, cy - ry + 5
        for p in ((0, 0), (0, 1), (-1, 1), (1, 1), (0, 2), (-1, 2), (1, 2), (0, 3)):
            put(g, bx + p[0], by + p[1], DROP)

    return outline(g)


def outline(g):
    out = [row[:] for row in g]
    for y in range(GH):
        for x in range(GW):
            if g[y][x] is None:
                for ox, oy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + ox, y + oy
                    if 0 <= nx < GW and 0 <= ny < GH and g[ny][nx] not in (None, INK):
                        out[y][x] = INK
                        break
    return out


def to_image(g):
    img = Image.new("RGBA", (GW, GH), (0, 0, 0, 0))
    for y in range(GH):
        for x in range(GW):
            if g[y][x] is not None:
                img.putpixel((x, y), g[y][x])
    return img.resize((OUT_W, OUT_H), Image.NEAREST)


def rows():
    R = {}
    R[0] = [draw_pet(sy=s, dy=d, eyes=e, leaf=l, arms=(0, 0)) for s, d, e, l in [
        (1.0, 0, "open", 0), (0.97, 0, "open", 1), (0.95, 0, "open", 1),
        (0.95, 0, "blink", 0), (0.97, 0, "open", -1), (1.0, 0, "open", 0)]]
    def run(f):
        out = []
        for i in range(8):
            ph = i / 8 * 2 * math.pi
            out.append(draw_pet(dx=f * (1 if i % 4 in (1, 2) else 0), dy=-round(abs(math.sin(ph)) * 2),
                                sy=1 - 0.04 * abs(math.cos(ph)), facing=f, look=(f, 0),
                                feet=(-2 if math.sin(ph) > 0.3 else 0, -2 if math.sin(ph) < -0.3 else 0),
                                arms=(1 if math.sin(ph) > 0 else 0, 0 if math.sin(ph) > 0 else 1),
                                leaf=-f, mouth="open"))
        return out
    R[1], R[2] = run(1), run(-1)
    R[3] = [draw_pet(eyes="happy", arms=(0, a), mouth="open", leaf=l) for a, l in
            [(1, 0), (2, 1), (1, -1), (2, 0)]]
    R[4] = [draw_pet(sy=s, dy=d, eyes=e, arms=a, mouth=m, feet=ft) for s, d, e, a, m, ft in [
        (0.88, 1, "happy", (0, 0), "smile", (0, 0)),
        (1.06, -6, "happy", (2, 2), "open", (-1, -1)),
        (1.08, -10, "happy", (2, 2), "open", (-1, -1)),
        (1.03, -5, "open", (1, 1), "open", (0, 0)),
        (0.92, 1, "happy", (0, 0), "smile", (0, 0))]]
    R[5] = [draw_pet(sy=s, dy=0, eyes=e, drop=dr, mouth=m, arms=(0, 0), leaf=l) for s, e, dr, m, l in [
        (1.0, "open", False, "o", 0), (0.97, "sad", False, "wobbly", -1), (0.93, "sad", True, "wobbly", -2),
        (0.9, "sad", True, "wobbly", -2), (0.88, "sad", True, "wobbly", -2), (0.88, "sad", True, "wobbly", -1),
        (0.9, "sad", True, "wobbly", -2), (0.9, "blink", True, "wobbly", -2)]]
    R[6] = [draw_pet(dy=d, eyes="big", look=(0, -1), arms=(1, 1), mouth="o", leaf=l) for d, l in
            [(0, 0), (-1, 1), (-2, 1), (-1, 0), (0, -1), (0, 0)]]
    R[7] = [draw_pet(dy=d, eyes="focus", arms=a, mouth="flat", leaf=0) for d, a in
            [(0, (-1, 0)), (0, (0, -1)), (-1, (-1, 0)), (0, (0, -1)), (0, (-1, 0)), (-1, (0, -1))]]
    R[8] = [draw_pet(eyes=e, look=lk, mouth="flat", dx=t, leaf=t) for e, lk, t in
            [("open", (-1, 0), 0), ("open", (-1, 0), -1), ("open", (0, 0), 0),
             ("open", (1, 0), 1), ("blink", (1, 0), 1), ("open", (0, 0), 0)]]
    looks = []
    for i in range(16):
        th = math.radians(i * 22.5)            # 0 = arriba, sentido horario
        lx, ly = round(math.sin(th) * 1.6), round(-math.cos(th) * 1.6)
        looks.append(draw_pet(look=(lx, ly), dx=round(math.sin(th)), leaf=-round(math.sin(th)),
                              eyes="big" if ly < 0 else "open"))
    R[9], R[10] = looks[:8], looks[8:]
    return R


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "pets/mochi")
    out.mkdir(parents=True, exist_ok=True)
    atlas = Image.new("RGBA", (COLS * OUT_W, ROWS * OUT_H), (0, 0, 0, 0))
    for r, frames in rows().items():
        for c, g in enumerate(frames):
            atlas.paste(to_image(g), (c * OUT_W, r * OUT_H))
    atlas.save(out / "spritesheet.webp", lossless=True)
    (out / "pet.json").write_text(json.dumps({
        "id": "mochi",
        "displayName": "Mochi",
        "description": "Una bolita con hojita que vigila a Claude.",
        "spriteVersionNumber": 2,
        "spritesheetPath": "spritesheet.webp",
        "pixelated": True,
    }, indent=2, ensure_ascii=False) + "\n")
    print("ok", out)


if __name__ == "__main__":
    main()
