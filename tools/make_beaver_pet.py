#!/usr/bin/env python3
"""Genera "Bober", un castor en pixel art monocromo, como atlas Codex v2 (8x11) más una
tira de "hablar" (talk.webp, 4 cuadros) que Compa reproduce cada vez que sale un globito.

    python3 tools/make_beaver_pet.py pets/bober
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image

GW, GH, K = 48, 52, 4
COLS, ROWS = 8, 11

INK = (18, 18, 22, 255)
DARK = (72, 72, 78, 255)
MID = (128, 128, 134, 255)
LIGHT = (196, 196, 198, 255)
WHITE = (240, 238, 232, 255)
TAIL = (52, 52, 58, 255)


def floor(v):
    return math.floor(v + 0.5)


class Canvas:
    def __init__(self):
        self.g = [[None] * GW for _ in range(GH)]
        self.part = [[None] * GW for _ in range(GH)]   # qué pieza ocupa cada píxel

    def put(self, x, y, c, part=None):
        x, y = floor(x), floor(y)
        if 0 <= x < GW and 0 <= y < GH:
            self.g[y][x] = c
            if part:
                self.part[y][x] = part

    def get(self, x, y):
        x, y = floor(x), floor(y)
        return self.g[y][x] if 0 <= x < GW and 0 <= y < GH else None

    def ellipse(self, cx, cy, rx, ry, shade, part):
        """Relleno con piel: gris medio, tramado oscuro hacia el borde."""
        for y in range(GH):
            for x in range(GW):
                nx, ny = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                d = nx * nx + ny * ny
                if d <= 1:
                    self.put(x, y, shade(x, y, nx, ny, d), part)


def fur(x, y, nx, ny, d):
    if d > 0.72 and (x + y) % 2 == 0:
        return DARK
    if nx * 0.5 + ny * 0.8 > 0.55 and (x + y) % 2 == 0:
        return DARK
    if (nx + 0.45) ** 2 + (ny + 0.55) ** 2 < 0.05:
        return LIGHT
    return MID


def scales(x, y, nx, ny, d):
    # la cola de castor: plana y con escamas en rombos
    return DARK if (x + y) % 3 == 0 or (x - y) % 3 == 0 else TAIL


def draw(*, dx=0, dy=0, sy=1.0, eyes="open", look=(0, 0), mouth="closed", facing=0,
         paws=(0, 0), feet=(0, 0), tail=0, ears=0, flail=None, laptop=None, typing=0):
    c = Canvas()
    cx, base = 24 + dx, 47 + dy
    bry = 10 * sy
    bcy = base - 1 - bry
    hcy = bcy - bry - 1
    side = -1 if facing > 0 else 1                 # la cola va detrás, del lado contrario

    # cola (detrás de todo)
    # pala plana apoyada en el suelo, asomando por detrás
    c.ellipse(cx + side * 13 + tail, base - 2.5, 6.5, 3.2, scales, "tail")
    # pies
    for i, fx in enumerate((-5, 5)):
        c.ellipse(cx + fx + facing, base - 0.5 + feet[i], 3, 1.6, lambda *a: DARK, "feet")
    # cuerpo y barriga
    c.ellipse(cx, bcy, 12, bry, fur, "body")
    c.ellipse(cx + facing, bcy + 2, 7, bry * 0.7, lambda x, y, nx, ny, d: WHITE if d < 0.75 else LIGHT, "body")
    # orejas
    for s in (-1, 1):
        c.ellipse(cx + s * 7 + facing, hcy - 5.5 - ears, 2.2, 2.2, lambda *a: DARK, "ear")
        c.put(cx + s * 7 + facing, hcy - 5.5 - ears, INK, "ear")
    # cabeza
    c.ellipse(cx + facing, hcy, 10, 7.5, fur, "head")
    # barbilla: línea entre cabeza y cuerpo
    for y in range(GH):
        for x in range(GW):
            if c.part[y][x] == "head" and y + 1 < GH and c.part[y + 1][x] == "body":
                c.put(x, y, INK)
    # patitas delante de la barriga
    for i, s in enumerate((-1, 1)):
        px, py = cx + s * 4 + facing, bcy - 2 - paws[i] * 3
        if flail:                                # patas fuera del cuerpo, aleteando
            px, py = cx + s * 13, bcy - 2 - flail[i] * 3
        if laptop == "side" and s > 0:           # va a buscarlo a un lado
            px, py = cx + 12, bcy
        c.ellipse(px, py, 2.2, 1.6, lambda *a: MID, "paw")
        c.put(px, py + 1, DARK)

    # hocico
    fx, fy = cx + facing * 2 + look[0], hcy + 1 + look[1]
    # el hocico crece hacia abajo al abrir la boca: los dientes nunca se despegan de él
    jaw = {"half": 1, "open": 2, "o": 2}.get(mouth, 0)
    c.ellipse(fx - 0.5, fy + 1.5 + jaw * 0.9, 4.5, 3.2 + jaw * 0.9, lambda *a: LIGHT, "muzzle")
    # nariz
    for x in (-1, 0, 1):
        c.put(fx + x, fy - 0.5, INK)
    c.put(fx - 1, fy + 0.5, INK); c.put(fx, fy + 0.5, INK)
    c.put(fx - 1, fy - 0.5, DARK)
    # boca y dientes: los dientes bajan cuando abre la boca
    gap = {"closed": 0, "half": 1, "open": 2, "smile": 0, "frown": 0, "o": 2, "smirk": 0}[mouth]
    ty = fy + 2
    if gap:
        for g in range(gap):
            for x in (-1, 0):
                c.put(fx + x, ty + g, INK)
    else:
        c.put(fx - 1, ty, INK); c.put(fx, ty, INK)
    if mouth == "smile":
        c.put(fx - 2, ty - 1, INK); c.put(fx + 1, ty - 1, INK)
    if mouth == "frown":
        c.put(fx - 2, ty + 1, INK); c.put(fx + 1, ty + 1, INK)
    if mouth == "smirk":                         # boca torcida hacia un lado
        c.put(fx + 1, ty - 1, INK); c.put(fx - 2, ty + 1, INK)
    # dos paletas grandes, el rasgo de castor por excelencia
    for t in range(4):
        for x in (-2, -1, 0, 1):
            edge = t == 3 or x in (-2, 1) and t < 3
            c.put(fx + x - 0.5 + 0.5, ty + gap + 1 + t, INK if edge else WHITE)
    for t in range(3):
        c.put(fx - 3, ty + gap + 1 + t, INK); c.put(fx + 2, ty + gap + 1 + t, INK)
    for x in (-2, -1, 0, 1):
        c.put(fx + x, ty + gap + 1 + 0, WHITE)
        c.put(fx + x, ty + gap + 2, WHITE)
        c.put(fx + x, ty + gap + 3, WHITE)
        c.put(fx + x, ty + gap + 4, INK)
    for t in range(3):
        c.put(fx - 0.5 + 0.5 - 0, ty + gap + 1 + t, WHITE)
    c.put(fx - 1 + 0.5 - 0.5, ty + gap + 2, LIGHT)
    c.put(fx, ty + gap + 2, LIGHT)
    # bigotes
    for s in (-1, 1):
        c.put(fx + s * 6, fy + 1, DARK); c.put(fx + s * 7, fy + 0, DARK); c.put(fx + s * 7, fy + 2, DARK)

    # ojos: negros, con un punto de luz; de párpado caído por defecto, que es lo que
    # le da el aire misterioso
    ex, ey = fx, hcy - 2 + look[1]
    for s in (-1, 1):
        x0 = ex + s * 5 + (1 if s > 0 else 0)
        e = eyes
        if eyes == "skeptic":
            # una ceja levantada: el ojo es exactamente el mismo, solo sube la ceja
            e = "half"
            if s > 0:
                for x in range(-2, 2):
                    c.put(x0 + x, ey - 3 - (1 if x >= 0 else 0), INK)
        if eyes == "side":
            e = "half"
        if e == "shut":
            # apretados en pico (> <), bajo el párpado caído: no quiere mirar
            for x in range(-2, 2):
                c.put(x0 + x, ey - 1, INK)
            tip = 1 if s < 0 else -2
            back = -2 if s < 0 else 1
            c.put(x0 + back, ey, INK); c.put(x0 + back + (1 if s < 0 else -1), ey, INK)
            c.put(x0 + tip, ey + 1, INK)
            c.put(x0 + back, ey + 2, INK); c.put(x0 + back + (1 if s < 0 else -1), ey + 2, INK)
            continue
        if e == "squint":
            for x in range(-2, 2):
                c.put(x0 + x, ey, INK)
            c.put(x0 - 1, ey + 1, INK)
            continue
        if e in ("open", "half", "big"):
            eyes_ = e
            h = {"open": 2, "half": 2, "big": 3}[eyes_]
            for x in range(-1, 1 + (eyes_ == "big")):
                for y in range(h):
                    c.put(x0 + x, ey + y, INK)
            c.put(x0 - 1, ey, WHITE)
            if eyes_ == "half":
                for x in range(-2, 2):
                    c.put(x0 + x, ey - 1, INK)
                c.put(x0 - 1, ey, INK); c.put(x0, ey, INK)
                # la pupila se va al lado al que mira de reojo
                c.put(x0 - 1 + (1 if eyes == "side" else 0), ey + 1, WHITE)
        elif e == "blink":
            for x in range(-2, 2):
                c.put(x0 + x, ey + 1, INK)
        elif e == "happy":
            c.put(x0 - 2, ey + 1, INK); c.put(x0 - 1, ey, INK); c.put(x0, ey, INK); c.put(x0 + 1, ey + 1, INK)
        elif e == "sad":
            c.put(x0 - 1, ey, INK); c.put(x0, ey, INK)
            c.put(x0 - 1, ey + 1, INK); c.put(x0, ey + 1, INK)
            c.put(x0 + (1 if s < 0 else -2), ey - 1, INK); c.put(x0 + (0 if s < 0 else -1), ey - 2, INK)
        elif e == "focus":
            for x in range(-2, 2):
                c.put(x0 + x, ey, INK)
            c.put(x0 - 1, ey + 1, INK); c.put(x0, ey + 1, INK)
    if laptop:
        draw_laptop(c, cx, bcy, laptop)
        if laptop != "side":
            # las patas sujetan la base y teclean, una arriba y otra abajo
            for i, s in enumerate((-1, 1)):
                px = cx + s * 6
                py = bcy - 1 - (1 if (typing > 0) == (i == 0) and typing else 0)
                c.ellipse(px, py, 2.2, 1.6, lambda *a: MID, "paw")
                c.put(px, py + 1, DARK)
    return outline(c.g)


def draw_laptop(c, cx, bcy, state):
    """Un portátil diminuto visto por la tapa, en alto, con la pantalla
    iluminándole la cara desde abajo."""
    if state == "side":                          # cerrado, sacándolo de un lado
        for x in range(-4, 5):
            for y in range(2):
                c.put(cx + 15 + x, bcy - 1 + y, LIGHT if y == 0 else DARK)
        return
    base_y = bcy - 1
    for x in range(-7, 7):                       # la base, de canto
        c.put(cx + x, base_y, MID)
        c.put(cx + x, base_y + 1, DARK)
    lid_h = {"closed": 1, "half": 4, "open": 8}[state]
    for y in range(lid_h):
        for x in range(-6, 6):
            edge = y == lid_h - 1 or x in (-6, 5)
            c.put(cx + x, base_y - 1 - y, LIGHT if edge else DARK)
    if state == "open":
        c.put(cx - 1, base_y - 5, MID); c.put(cx, base_y - 5, MID)   # una pegatina en la tapa
        # resplandor de pantalla sobre la cara, justo encima de la tapa
        top = base_y - lid_h - 1
        for y in (top, top - 1):
            for x in range(-6, 6):
                if c.get(cx + x, y) in (MID, DARK) and (x + y) % 2 == 0:
                    c.put(cx + x, y, LIGHT)


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
    return img.resize((GW * K, GH * K), Image.NEAREST)


def rows():
    """Un castor que te juzga. Nunca está contento; como mucho, conforme."""
    R = {}
    # reposo: mirada de juicio, boca torcida, un vistazo de reojo y un parpadeo lento
    R[0] = [draw(eyes=e, mouth=m, look=lk, sy=sy) for e, m, lk, sy in [
        ("half", "frown", (0, 0), 1.0), ("half", "frown", (0, 0), 0.98), ("side", "smirk", (1, 0), 0.98),
        ("side", "smirk", (1, 0), 0.98), ("blink", "frown", (0, 0), 0.99), ("half", "frown", (0, 0), 1.0)]]

    def walk(f):
        # arrastra los pies: poco rebote y cara de que no le apetece
        out = []
        for i in range(8):
            ph = i / 8 * 2 * math.pi
            out.append(draw(dx=f * (1 if i % 4 in (1, 2) else 0), dy=-(1 if abs(math.sin(ph)) > 0.7 else 0),
                            facing=f, look=(f, 0), eyes="half", mouth="frown",
                            feet=(-1 if math.sin(ph) > 0.3 else 0, -1 if math.sin(ph) < -0.3 else 0),
                            tail=round(math.sin(ph))))
        return out
    R[1], R[2] = walk(1), walk(-1)
    # "¿qué?": levanta una ceja y una pata con desgana; sirve para el clic, para
    # cuando Claude termina (asiente: "hmph, ya está") y para llamarte la atención
    R[3] = [draw(eyes=e, paws=p, mouth=m, sy=sy) for e, p, m, sy in [
        ("half", (0, 0), "frown", 1.0), ("skeptic", (0, 1), "smirk", 1.0),
        ("skeptic", (0, 1), "smirk", 0.96), ("half", (0, 0), "frown", 0.98)]]
    # arrastrado: se sobresalta, patas al aire, pies colgando: "¡suéltame!"
    # (ojos apretados, boca cerrada, brazos arriba y abajo para que lo sueltes)
    R[4] = [draw(sy=1.04, dy=d, eyes="shut", flail=p, mouth="frown", feet=ft, ears=-1, tail=t)
            for d, p, ft, t in [            # los dos brazos a la vez: arriba, medio, abajo
                (-2, (2, 2), (1, 0), 1),
                (-3, (1, 1), (0, 1), 2),
                (-2, (0, 0), (0, 1), 1),
                (-3, (1, 1), (1, 0), 2),
                (-2, (2, 2), (1, 0), 1)]]
    # error: ni se inmuta. Cierra los ojos despacio, "lo sabía", y vuelve a mirarte
    R[5] = [draw(eyes=e, mouth=m, sy=sy, ears=ea) for e, m, sy, ea in [
        ("half", "frown", 1.0, 0), ("squint", "frown", 0.99, 0), ("blink", "frown", 0.98, -1),
        ("blink", "frown", 0.97, -1), ("blink", "smirk", 0.97, -1), ("blink", "smirk", 0.98, -1),
        ("squint", "frown", 0.99, 0), ("half", "smirk", 1.0, 0)]]
    # esperándote: golpea el suelo con el pie, mirándote fijo
    R[6] = [draw(eyes="half", mouth="frown", feet=ft, paws=(1, 1), look=(0, 0)) for ft in
            [(0, 0), (0, -2), (0, 0), (0, -2), (0, 0), (0, 0)]]
    # trabajando: portátil en alto, tecleando a regañadientes; la pantalla le ilumina
    R[7] = [draw(eyes=e, laptop="open", typing=ty, mouth="frown", look=(0, 1)) for e, ty in
            [("squint", 1), ("squint", -1), ("half", 1), ("squint", -1), ("squint", 1), ("half", -1)]]
    # leyendo: el mismo portátil, repasando la pantalla de un lado a otro con sospecha
    R[8] = [draw(eyes=e, laptop="open", look=lk, mouth="frown") for e, lk in
            [("squint", (-1, 1)), ("side", (-1, 1)), ("squint", (0, 1)),
             ("side", (1, 1)), ("squint", (1, 1)), ("half", (0, 1))]]
    # mirada: siempre con los párpados caídos, te sigue sin entusiasmo
    looks = []
    for i in range(16):
        th = math.radians(i * 22.5)
        lx, ly = round(math.sin(th) * 1.6), round(-math.cos(th) * 1.6)
        looks.append(draw(look=(lx, ly), dx=round(math.sin(th)), eyes="half", mouth="frown",
                          tail=-round(math.sin(th))))
    R[9], R[10] = looks[:8], looks[8:]
    return R


def laptop_out():
    """Una sola vez al empezar a trabajar: lo saca de un lado y lo abre."""
    return [draw(eyes="half", mouth="frown", laptop=l) for l in ("side", "closed", "half")]


def talk():
    # habla sin abrir los ojos del todo, como quien hace un favor
    return [draw(eyes="half", mouth=m) for m in ("half", "open", "half", "frown")]


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "pets/bober")
    out.mkdir(parents=True, exist_ok=True)
    W, H = GW * K, GH * K
    atlas = Image.new("RGBA", (COLS * W, ROWS * H), (0, 0, 0, 0))
    for r, frames in rows().items():
        for c, g in enumerate(frames):
            atlas.paste(to_image(g), (c * W, r * H))
    atlas.save(out / "spritesheet.webp", lossless=True)
    strip = talk()
    t = Image.new("RGBA", (len(strip) * W, H), (0, 0, 0, 0))
    for c, g in enumerate(strip):
        t.paste(to_image(g), (c * W, 0))
    t.save(out / "talk.webp", lossless=True)
    strip = laptop_out()
    t = Image.new("RGBA", (len(strip) * W, H), (0, 0, 0, 0))
    for c, g in enumerate(strip):
        t.paste(to_image(g), (c * W, 0))
    t.save(out / "laptop-out.webp", lossless=True)
    (out / "pet.json").write_text(json.dumps({
        "id": "bober",
        "displayName": "Bober",
        "description": "Un castor que juzga en silencio todo lo que haces.",
        "spriteVersionNumber": 2,
        "spritesheetPath": "spritesheet.webp",
        "pixelated": True,
        "talkSheet": "talk.webp",
        "talkFrameMs": 120,
        # personalidad: qué fila usa en cada reacción, y qué dice
        "reactions": {"done": "waving", "drag": "jumping", "wave": "waving", "error": "failed",
                      "work": "running"},
        # se reproduce una vez al entrar en esa fila, antes del bucle
        "introSheets": {"running": "laptop-out.webp"},
        "introFrameMs": 160,
        "lines": {
            "start": ["fine…", "if I must…", "sigh…", "ugh. ok…"],
            "done": ["finally.", "there. happy?", "done. you're welcome.", "hmph. it's done.",
                     "took long enough."],
            "error": ["of course it broke.", "called it.", "unsurprising."]
        }
    }, indent=2, ensure_ascii=False) + "\n")
    print("ok", out)


if __name__ == "__main__":
    main()
