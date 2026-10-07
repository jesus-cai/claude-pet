#!/usr/bin/env python3
"""Comprueba que una carpeta de mascota cumple el formato Codex (v1 8x9 o v2 8x11).

    python3 tools/validate_pet.py ~/.compa/pets/mochi [--sheet hoja.png]

Revisa: pet.json, tamaño del atlas, celdas usadas no vacías, celdas sobrantes
transparentes, y avisa de lo que la app tolera pero conviene arreglar. Con --sheet
guarda una hoja de contacto sobre fondo gris para mirarla de un vistazo.
"""
import json
import sys
from pathlib import Path

from PIL import Image

ROWS = [("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4),
        ("jumping", 5), ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6)]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    d = Path(args[0]).expanduser()
    errors, warns = [], []
    man = d / "pet.json"
    meta = {}
    if not man.exists():
        errors.append("falta pet.json")
    else:
        try:
            meta = json.loads(man.read_text())
        except Exception as e:  # noqa: BLE001
            errors.append(f"pet.json no es JSON válido: {e}")
    if meta.get("kind") == "rig":
        print("mascota de tipo rig (capas): este validador es para atlas")
        return
    sheet_name = meta.get("spritesheetPath") or next(
        (n for n in ("spritesheet.webp", "spritesheet.png") if (d / n).exists()), "spritesheet.webp")
    sp = d / sheet_name
    if not sp.exists():
        errors.append(f"no existe la hoja {sheet_name}")
        report(errors, warns)
        return
    img = Image.open(sp).convert("RGBA")
    W, H = img.size
    version = int(meta.get("spriteVersionNumber", 1) or 1)
    if W % 8:
        errors.append(f"ancho {W} no es múltiplo de 8 columnas")
    cw = W // 8
    ch_v1, ch_v2 = H / 9, H / 11
    expected_ch = cw * 208 / 192
    nrows = 11 if (version >= 2 or abs(ch_v2 - expected_ch) < abs(ch_v1 - expected_ch)) else 9
    ch = H // nrows
    if (W, H) not in ((1536, 1872), (1536, 2288)):
        warns.append(f"tamaño {W}x{H}: el estándar es 1536x1872 (v1) o 1536x2288 (v2). "
                     "La app lo acepta si la proporción de celda es 192:208, Codex no.")
    if nrows == 11 and version < 2:
        warns.append("la hoja tiene 11 filas pero pet.json no dice \"spriteVersionNumber\": 2 "
                     "(Codex la rechazaría; esta app la detecta igual)")
    if nrows == 9 and version >= 2:
        errors.append("pet.json dice versión 2 pero la hoja tiene 9 filas")

    def cell(r, c):
        return img.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))

    def opaque(c):
        return c.getchannel("A").getbbox() is not None

    for r, (name, used) in enumerate(ROWS):
        for c in range(8):
            o = opaque(cell(r, c))
            if c < used and not o:
                (warns if c > 0 else errors).append(f"fila {r} ({name}): cuadro {c} vacío")
            if c >= used and o:
                warns.append(f"fila {r} ({name}): la columna {c} debería estar vacía y no lo está")
    if nrows == 11:
        for r in (9, 10):
            for c in range(8):
                if not opaque(cell(r, c)):
                    errors.append(f"fila {r} (mirada {(r - 9) * 8 + c}): vacía")
    # bordes: un sprite que toca el borde de la celda se corta al animarse
    for r in range(nrows):
        for c in range(8):
            bb = cell(r, c).getchannel("A").getbbox()
            if bb and (bb[0] == 0 or bb[1] == 0 or bb[2] == cw or bb[3] == ch):
                warns.append(f"fila {r} col {c}: toca el borde de la celda")
                break

    talk = meta.get("talkSheet")
    if talk:
        tp = d / talk
        if not tp.exists():
            errors.append(f"talkSheet apunta a {talk}, que no existe")
        else:
            t = Image.open(tp)
            if t.height != ch or t.width % cw:
                errors.append(f"{talk}: debe ser una fila de celdas de {cw}x{ch} (es {t.width}x{t.height})")
            else:
                print(f"tira de hablar: {t.width // cw} cuadros")

    if "--sheet" in sys.argv:
        out = sys.argv[sys.argv.index("--sheet") + 1] if sys.argv.index("--sheet") + 1 < len(sys.argv) else "hoja.png"
        bg = Image.new("RGBA", img.size, (200, 205, 215, 255))
        bg.alpha_composite(img)
        bg.save(out)
        print("hoja de contacto:", out)
    print(f"{d.name}: {W}x{H}, {nrows} filas, celda {cw}x{ch}, versión {version}")
    report(errors, warns)


def report(errors, warns):
    for w in warns:
        print("  aviso:", w)
    for e in errors:
        print("  ERROR:", e)
    print("OK" if not errors else "NO VÁLIDA")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
