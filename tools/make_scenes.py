#!/usr/bin/env python3
"""Genera los escenarios incluidos: "oficina" y "cabana". Pixel art de 360x150 en dos
capas (fondo y primer plano) más scene.json con los puestos.

    python3 tools/make_scenes.py scenes

Formato de un escenario (para hacer los tuyos):

    scenes/<id>/scene.json   tamaño, suelo, altura de las mascotas y puestos (x):
                             door (entrada/salida), desks (mesas), rest (descanso),
                             window (asomarse), walk [x0, x1] (por dónde se mueven)
    scenes/<id>/back.png     lo que queda detrás de las mascotas
    scenes/<id>/front.png    lo que queda delante (las mesas), transparente el resto
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 360, 150
FLOOR = 138                 # donde apoyan los pies
DESKS = [82, 128, 174, 220, 266]
DOOR, REST, WINDOW = 26, 322, 174


def rect(d, x0, y0, x1, y1, c):
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=c)


def office():
    back = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(back)
    WALL, WALL2, BASE = (226, 221, 210, 255), (214, 208, 196, 255), (150, 132, 112, 255)
    FL1, FL2, INK = (176, 140, 104, 255), (160, 126, 92, 255), (52, 44, 48, 255)
    rect(d, 0, 0, W, 112, WALL)
    for x in range(0, W, 24):                       # papel pintado a rayas suaves
        rect(d, x, 0, x + 12, 112, WALL2)
    rect(d, 0, 108, W, 114, BASE)
    for y in range(114, H, 6):                      # tarima
        rect(d, 0, y, W, y + 6, FL1 if (y // 6) % 2 else FL2)
        for x in range((y * 7) % 40, W, 40):
            rect(d, x, y, x + 1, y + 6, (140, 108, 80, 255))
    # puerta
    rect(d, DOOR - 16, 52, DOOR + 16, FLOOR, INK)
    rect(d, DOOR - 14, 54, DOOR + 14, FLOOR, (120, 86, 62, 255))
    rect(d, DOOR - 11, 58, DOOR + 11, 92, (138, 100, 72, 255))
    rect(d, DOOR - 11, 96, DOOR + 11, 132, (138, 100, 72, 255))
    rect(d, DOOR + 8, 94, DOOR + 11, 97, (230, 196, 90, 255))
    # ventanal con cielo y ciudad
    rect(d, WINDOW - 70, 14, WINDOW + 70, 72, INK)
    rect(d, WINDOW - 68, 16, WINDOW + 68, 70, (150, 200, 236, 255))
    for i, (bx, bw, bh) in enumerate([(-66, 18, 26), (-46, 14, 36), (-30, 22, 20), (-6, 16, 40),
                                      (12, 20, 28), (34, 14, 44), (50, 18, 24)]):
        rect(d, WINDOW + bx, 70 - bh, WINDOW + bx + bw, 70, (112, 136, 170, 255) if i % 2 else (98, 120, 156, 255))
        for wy in range(70 - bh + 4, 68, 6):
            for wx in range(WINDOW + bx + 3, WINDOW + bx + bw - 3, 5):
                rect(d, wx, wy, wx + 2, wy + 2, (240, 226, 150, 255))
    rect(d, WINDOW - 1, 16, WINDOW + 1, 70, INK)
    rect(d, WINDOW - 68, 42, WINDOW + 68, 44, INK)
    # reloj y cuadro
    d.ellipse([292, 22, 312, 42], fill=INK); d.ellipse([294, 24, 310, 40], fill=(250, 248, 240, 255))
    rect(d, 301, 27, 303, 33, INK); rect(d, 302, 32, 308, 34, INK)
    rect(d, 52, 28, 78, 54, INK); rect(d, 54, 30, 76, 52, (244, 236, 214, 255))
    d.polygon([(56, 50), (64, 36), (70, 44), (74, 50)], fill=(92, 160, 120, 255))
    # rincón de descanso: sofá y planta
    rect(d, REST - 28, 100, REST + 28, 128, INK)
    rect(d, REST - 26, 102, REST + 26, 126, (196, 92, 84, 255))
    rect(d, REST - 26, 112, REST + 26, 126, (214, 108, 98, 255))
    rect(d, REST - 30, 108, REST - 24, 130, (178, 80, 74, 255)); rect(d, REST + 24, 108, REST + 30, 130, (178, 80, 74, 255))
    rect(d, 346, 104, 358, 128, (190, 120, 80, 255))
    for (px, py) in [(348, 90), (352, 84), (356, 92), (350, 96), (354, 98)]:
        d.ellipse([px - 4, py - 6, px + 4, py + 6], fill=(78, 150, 90, 255))

    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    f = ImageDraw.Draw(front)
    for x in DESKS:                                  # mesas: tapan la parte baja de la mascota
        rect(f, x - 19, 121, x + 19, 125, INK)
        rect(f, x - 18, 122, x + 18, 124, (232, 222, 200, 255))
        rect(f, x - 17, 125, x + 17, 140, (196, 180, 152, 255))
        rect(f, x - 17, 125, x + 17, 126, INK)
        rect(f, x - 17, 139, x + 17, 140, INK)
        rect(f, x - 14, 129, x - 2, 136, (178, 162, 134, 255))     # cajón
        rect(f, x - 9, 132, x - 7, 133, INK)
        rect(f, x + 10, 116, x + 15, 122, (250, 250, 250, 255))   # taza
        rect(f, x + 10, 116, x + 15, 117, (120, 80, 60, 255))
    return back, front


def cabin():
    back = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(back)
    LOG1, LOG2, INK = (150, 104, 66, 255), (128, 86, 54, 255), (44, 32, 28, 255)
    for y in range(0, 112, 10):                     # paredes de troncos
        rect(d, 0, y, W, y + 10, LOG1 if (y // 10) % 2 else LOG2)
        rect(d, 0, y + 9, W, y + 10, (100, 66, 42, 255))
        for x in range((y * 13) % 70, W, 70):
            d.ellipse([x, y + 2, x + 6, y + 8], fill=(110, 74, 46, 255))
    for y in range(112, H, 5):                      # suelo de tablones oscuros
        rect(d, 0, y, W, y + 5, (96, 70, 50, 255) if (y // 5) % 2 else (86, 62, 44, 255))
    d.ellipse([110, 120, 250, 146], fill=(150, 58, 52, 255))           # alfombra
    d.ellipse([120, 123, 240, 143], fill=(176, 80, 66, 255))
    # puerta con arco
    d.ellipse([DOOR - 16, 46, DOOR + 16, 78], fill=INK); rect(d, DOOR - 16, 62, DOOR + 16, FLOOR, INK)
    d.ellipse([DOOR - 14, 48, DOOR + 14, 76], fill=(92, 60, 40, 255)); rect(d, DOOR - 14, 62, DOOR + 14, FLOOR, (92, 60, 40, 255))
    for x in range(DOOR - 12, DOOR + 13, 6):
        rect(d, x, 56, x + 1, FLOOR, (70, 46, 30, 255))
    rect(d, DOOR + 8, 98, DOOR + 11, 101, (210, 180, 90, 255))
    # ventana redonda al bosque: el paisaje se pinta aparte y se recorta con la forma
    # del cristal; el marco y los cuarterones van por encima, como en una ventana de verdad
    view = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    v = ImageDraw.Draw(view)
    rect(v, WINDOW - 40, 8, WINDOW + 40, 80, (196, 222, 214, 255))            # cielo
    rect(v, WINDOW - 40, 62, WINDOW + 40, 80, (120, 160, 120, 255))           # prado al fondo
    for (tx, th, c) in [(-26, 30, (64, 112, 80)), (-12, 44, (52, 98, 70)), (4, 36, (70, 122, 86)),
                        (18, 42, (58, 104, 74)), (30, 28, (66, 116, 82))]:
        v.polygon([(WINDOW + tx - 10, 80), (WINDOW + tx, 80 - th), (WINDOW + tx + 10, 80)], fill=c + (255,))
        rect(v, WINDOW + tx - 1, 74, WINDOW + tx + 1, 80, (90, 64, 44, 255))  # tronco
    glass = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glass).ellipse([WINDOW - 31, 13, WINDOW + 31, 75], fill=255)
    back.paste(view, (0, 0), glass)
    d.ellipse([WINDOW - 34, 10, WINDOW + 34, 78], outline=INK, width=4)     # marco encima
    rect(d, WINDOW - 31, 43, WINDOW + 31, 45, INK); rect(d, WINDOW - 1, 13, WINDOW + 1, 75, INK)
    # chimenea encendida con butaca (descanso)
    rect(d, REST - 30, 50, REST + 6, FLOOR, (120, 116, 112, 255))
    for y in range(52, FLOOR, 8):
        for x in range(REST - 30 + (y // 8 % 2) * 6, REST + 6, 12):
            rect(d, x, y, x + 11, y + 7, (138, 134, 128, 255))
    rect(d, REST - 22, 96, REST - 2, FLOOR, INK)
    d.polygon([(REST - 18, FLOOR), (REST - 12, 108), (REST - 6, FLOOR)], fill=(240, 150, 60, 255))
    d.polygon([(REST - 14, FLOOR), (REST - 12, 118), (REST - 9, FLOOR)], fill=(250, 220, 110, 255))
    rect(d, REST + 10, 104, REST + 36, 132, INK); rect(d, REST + 12, 106, REST + 34, 130, (86, 120, 92, 255))
    rect(d, REST + 12, 116, REST + 34, 130, (100, 138, 106, 255))
    # estantería con libros y una seta
    rect(d, 46, 30, 86, 32, INK); rect(d, 46, 56, 86, 58, INK)
    for i, x in enumerate(range(48, 84, 5)):
        rect(d, x, 18 + (i % 3) * 2, x + 4, 30, [(180, 70, 60, 255), (70, 110, 160, 255), (210, 170, 70, 255)][i % 3])
    d.ellipse([60, 44, 72, 52], fill=(200, 60, 50, 255)); rect(d, 64, 50, 68, 56, (240, 230, 210, 255))
    rect(d, 63, 45, 65, 47, (255, 255, 255, 255))

    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    f = ImageDraw.Draw(front)
    for x in DESKS:                                  # mesas de madera maciza
        rect(f, x - 19, 121, x + 19, 126, INK)
        rect(f, x - 18, 122, x + 18, 125, (176, 128, 78, 255))
        rect(f, x - 16, 126, x - 12, 140, INK); rect(f, x + 12, 126, x + 16, 140, INK)
        rect(f, x - 15, 126, x - 13, 140, (150, 104, 62, 255)); rect(f, x + 13, 126, x + 15, 140, (150, 104, 62, 255))
        rect(f, x - 12, 126, x + 12, 128, (150, 104, 62, 255))
        d2 = x + 11                                  # velita
        rect(f, d2, 116, d2 + 3, 122, (240, 232, 210, 255)); rect(f, d2 + 1, 113, d2 + 2, 116, (250, 190, 70, 255))
    return back, front


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "scenes")
    for sid, name, fn in [("oficina", "Oficina", office), ("cabana", "Cabaña del bosque", cabin)]:
        out = root / sid
        out.mkdir(parents=True, exist_ok=True)
        back, front = fn()
        back.save(out / "back.png"); front.save(out / "front.png")
        (out / "scene.json").write_text(json.dumps({
            "id": sid, "name": name, "size": [W, H], "floor": FLOOR, "petHeight": 40, "pixelated": True,
            "walk": [14, 346], "door": DOOR, "desks": DESKS, "rest": 345 if sid == "cabana" else REST, "window": WINDOW,
        }, indent=2, ensure_ascii=False) + "\n")
        print("ok", out)


if __name__ == "__main__":
    main()
