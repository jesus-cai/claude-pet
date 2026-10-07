#!/usr/bin/env python3
"""Convierte cualquier imagen (una foto, un dibujo, un fondo de pantalla) en un
escenario para la oficina de mascotas.

    python3 tools/scene_from_image.py foto.jpg --id playa --name "Playa"
    python3 tools/scene_from_image.py foto.jpg --id playa --pixel 3 --desks cabana
    python3 tools/scene_from_image.py foto.jpg --id mi-sitio --desks ninguna --no-floor

Qué hace:
  - recorta la imagen al formato del escenario (360x150, por el centro) y la escala;
  - con --pixel N la convierte en pixel art: la reduce N veces, la vuelve a ampliar
    sin suavizar y limita la paleta, para que pegue con las mascotas;
  - añade una franja de suelo bajo los pies (--no-floor para no ponerla), porque una
    foto rara vez tiene el suelo justo donde apoyan;
  - reutiliza las mesas (front.png) y los puestos de un escenario incluido
    (--desks oficina|cabana|ninguna);
  - lo guarda en ~/.compa/scenes/<id>/ (o en --out), listo para elegirlo en el menú
    Varias mascotas > Escenario.

Usa solo imágenes que puedas usar: tus fotos, dibujos tuyos o con licencia libre.
"""
import argparse
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance

W, H = 360, 150
FLOOR = 138
ROOT = Path(__file__).resolve().parent.parent


def fit(img, w, h):
    """Recorta por el centro a la proporción pedida y escala."""
    img = img.convert("RGB")
    r = w / h
    iw, ih = img.size
    if iw / ih > r:
        nw = int(ih * r)
        img = img.crop(((iw - nw) // 2, 0, (iw - nw) // 2 + nw, ih))
    else:
        nh = int(iw / r)
        img = img.crop((0, (ih - nh) // 2, iw, (ih - nh) // 2 + nh))
    return img.resize((w, h), Image.LANCZOS)


def pixelate(img, n, colors=40):
    small = img.resize((max(1, W // n), max(1, H // n)), Image.BOX)
    small = small.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).convert("RGB")
    return small.resize((W, H), Image.NEAREST)


def add_floor(img, pixel):
    """Una franja de suelo oscura y algo transparente: da dónde apoyar sin tapar el fondo."""
    img = img.convert("RGBA")
    band = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(band)
    top = 112
    for y in range(top, H):
        a = int(70 + 110 * (y - top) / (H - top))
        d.line([(0, y), (W, y)], fill=(30, 24, 22, a))
    step = max(2, pixel or 2)
    for y in range(top, H, step * 3):                      # líneas de tablón
        d.line([(0, y), (W, y)], fill=(0, 0, 0, 60))
    img.alpha_composite(band)
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--id", required=True)
    ap.add_argument("--name")
    ap.add_argument("--pixel", type=int, default=0, help="tamaño del píxel (0 = sin pixelar)")
    ap.add_argument("--desks", default="oficina", help="oficina | cabana | ninguna")
    ap.add_argument("--no-floor", action="store_true")
    ap.add_argument("--brightness", type=float, default=1.0, help="<1 oscurece el fondo para que destaquen")
    ap.add_argument("--out", default=str(Path.home() / ".compa" / "scenes"))
    a = ap.parse_args()

    img = fit(Image.open(a.image), W, H)
    if a.brightness != 1:
        img = ImageEnhance.Brightness(img).enhance(a.brightness)
    if a.pixel > 1:
        img = pixelate(img, a.pixel)
    img = img.convert("RGBA") if a.no_floor else add_floor(img, a.pixel)

    out = Path(a.out).expanduser() / a.id
    out.mkdir(parents=True, exist_ok=True)
    img.save(out / "back.png")

    template = ROOT / "scenes" / ("oficina" if a.desks == "ninguna" else a.desks)
    meta = json.loads((template / "scene.json").read_text())
    meta.update({"id": a.id, "name": a.name or a.id, "pixelated": a.pixel > 1})
    if a.desks == "ninguna":
        meta["desks"] = []
        (out / "front.png").unlink(missing_ok=True)
    else:
        shutil.copy(template / "front.png", out / "front.png")
    (out / "scene.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    print(f"escenario listo: {out}  (menú → Varias mascotas → Escenario → {meta['name']})")


if __name__ == "__main__":
    main()
