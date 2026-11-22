# Génère le glyphe Oort NX en SVG : trame (grandes tailles) et plein (≤ 32 px).
# Unité : rayon 1, centre (0,0), y vers le bas.
import argparse
import json
import math
import re
from pathlib import Path

RIM, EX, GAP, SUN = 0.86, 0.55, 0.13, 0.075  # bord intérieur de la coquille, demi-axe de la coupe, vide autour du Soleil, Soleil


def cut_x(y):  # x de l'arc de coupe (ellipse EX×1) à la hauteur y
    return EX * math.sqrt(max(0.0, 1 - y * y))


def trumpet(x):  # demi-épaisseur du disque intérieur : fin au centre, évasé aux deux bouts
    end = RIM if x < 0 else cut_x(0)
    t = min(1.0, abs(x) / end)
    return 0.012 + 0.2 * t ** 2.4


def density(x, y):
    r = math.hypot(x, y)
    if r > 1 or r < GAP:
        return 0.0
    if x > 0 and x > cut_x(y):  # croissant de droite, plus dense au milieu
        return 0.2 + 0.75 * (1 - y * y) ** 1.5
    if r >= RIM:  # liseré de gauche, plus marqué au milieu gauche
        return 0.22 + 0.5 * max(0.0, -x) * (1 - y * y) ** 0.5
    w = trumpet(x)
    if abs(y) < w:  # disque : points plus gros vers les bords
        end = RIM if x < 0 else cut_x(y)
        return 0.18 + 0.7 * min(1.0, abs(x) / end) * (1 - abs(y) / w) ** 0.6
    return 0.0


def svg(body, pad=1.08):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-pad} {-pad} {2*pad} {2*pad}" '
            f'fill="currentColor">{body}</svg>\n')


def trame(step=0.056):
    # Anneaux concentriques plutôt qu'une grille carrée : la silhouette reste un cercle parfait.
    dots = []
    for k in range(1, int(1 / step) + 1):
        rad = 1 - (k - 0.5) * step
        m = round(2 * math.pi * rad / step)
        for a in range(m):
            th = 2 * math.pi * a / m
            x, y = rad * math.cos(th), rad * math.sin(th)
            d = density(x, y)
            if d >= 0.12:
                dots.append(f'<circle cx="{x:.3f}" cy="{y:.3f}" r="{0.5 * step * 0.95 * math.sqrt(d):.4f}"/>')
    dots.append(f'<circle r="{SUN}"/>')
    return svg(''.join(dots))


def plein():
    def side(sign):
        end = (1 + RIM) / 2 if sign < 0 else cut_x(0) + 0.02
        xs = [sign * (GAP + (end - GAP) * k / 24) for k in range(25)]
        top = [f'{x:.3f},{-trumpet(x):.3f}' for x in xs]
        bot = [f'{x:.3f},{trumpet(x):.3f}' for x in reversed(xs)]
        return f'<polygon points="{" ".join(top + bot)}"/>'
    ring = f'<circle r="{(1 + RIM) / 2:.3f}" fill="none" stroke="currentColor" stroke-width="{1 - RIM:.3f}"/>'
    crescent = f'<path d="M0,-1 A1,1 0 0 1 0,1 A{EX},1 0 0 0 0,-1 Z"/>'
    return svg(ring + crescent + side(-1) + side(1) + f'<circle r="{SUN * 1.3:.3f}"/>')


THEMES = {  # fond haut, fond bas, encre, givre, liseré du verre
    'sombre': ('#1A1F29', '#05070B', '#D6DEEA', '#AFC3E6', 'rgba(255,255,255,.14)'),
    'clair': ('#F7F9FC', '#DCE3EE', '#1B2230', '#4A5D7E', 'rgba(255,255,255,.9)'),
}
GOLD = '#F4CE8E'


def icon(theme, body, scale=340):
    top, bot, *_, rim = THEMES[theme]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bot}"/></linearGradient>'
            f'<radialGradient id="sun"><stop offset="0" stop-color="#FFF8EA"/><stop offset=".35" stop-color="{GOLD}"/>'
            f'<stop offset="1" stop-color="{GOLD}" stop-opacity="0"/></radialGradient></defs>'
            f'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>'
            f'<g transform="translate(512 512) scale({scale})">{body}</g>'
            f'<rect x="101" y="101" width="822" height="822" rx="184" fill="none" stroke="{rim}" stroke-width="2"/></svg>\n')


def sun(scale=1.0):  # Soleil doré : cœur, halo et fine étoile
    s = scale
    return (f'<circle r="{0.16 * s}" fill="url(#sun)"/><circle r="{0.035 * s}" fill="#FFF8EA"/>'
            f'<path d="M{-0.2 * s},0 L0,-0.006 L{0.2 * s},0 L0,0.006Z M0,{-0.2 * s} L-0.006,0 L0,{0.2 * s} L0.006,0Z" '
            f'fill="#FFF3DC" opacity=".85"/>')


def icon_trame(theme):
    ink = THEMES[theme][2]
    dots = trame().split('>', 1)[1].rsplit('</svg>', 1)[0]
    dots = dots.rsplit(f'<circle r="{SUN}"/>', 1)[0]  # le Soleil devient doré
    return icon(theme, f'<g fill="{ink}">{dots}</g>' + sun(0.55))


def particules(theme, n=32000, seed=7):
    import random
    rnd = random.Random(seed)
    _, _, ink, frost, _ = THEMES[theme]
    out = []
    for _ in range(n):
        r, th = math.sqrt(rnd.random()) * 1.06, rnd.random() * 2 * math.pi
        x, y = r * math.cos(th), r * math.sin(th)
        d = density(x, y) if r <= 1 else 0.05 * (1.06 - r) / 0.06  # quelques comètes égarées
        edge = x > 0 and abs(x - cut_x(y)) < 0.018 and r <= 1  # arête de coupe, nette et lumineuse
        if edge:
            d = 1.0
        if rnd.random() > d ** 1.25 * 0.9:
            continue
        col = ink if edge or rnd.random() < 0.55 else frost
        size = (0.0065 if edge else 0.0045) + rnd.random() * 0.006 * d
        out.append(f'<circle cx="{x:.4f}" cy="{y:.4f}" r="{size:.4f}" fill="{col}" '
                   f'opacity="{0.55 + 0.45 * rnd.random():.2f}"/>')
    arc = (f'<path d="M0,-1 A{EX},1 0 0 1 0,1" fill="none" stroke="{ink}" stroke-width="0.007" '
           f'stroke-linecap="round" opacity=".9"/>')
    return ''.join(out) + arc


def icon_particules(theme):
    return icon(theme, particules(theme) + sun(0.6))


def icon_plein(theme):  # rendu des petites tailles (≤ 128 px) : formes pleines, lisibles au pixel près
    ink = THEMES[theme][2]
    body = plein().split('>', 1)[1].rsplit('</svg>', 1)[0].replace('currentColor', ink)
    body = body.rsplit('<circle r=', 1)[0]  # le Soleil devient doré
    return icon(theme, f'<g fill="{ink}">{body}</g><circle r="{SUN * 1.5:.3f}" fill="{GOLD}"/>', scale=370)


def _color(hexa):
    r, g, b = (int(hexa.lstrip('#')[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f'extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000'


def _solid(light, dark):
    return [{"value": {"solid": _color(light)}}, {"appearance": "dark", "value": {"solid": _color(dark)}}]


def icon_package(root, body, glass):
    """Writes an Icon Composer `.icon`: flat white layers recoloured per appearance by the system."""
    def layer(content):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<g transform="translate(512 512) scale(360)" fill="#FFFFFF">{content}</g></svg>\n')
    (root / 'Assets').mkdir(parents=True, exist_ok=True)
    (root / 'Assets' / 'glyph.svg').write_text(layer(body), encoding='utf-8')
    (root / 'Assets' / 'sun.svg').write_text(layer(f'<circle r="{SUN * 1.1:.3f}"/>'), encoding='utf-8')
    doc = {
        "fill-specializations": [
            {"value": {"linear-gradient": [_color('#F7F9FC'), _color('#DCE3EE')]}},
            {"appearance": "dark", "value": {"linear-gradient": [_color('#1A1F29'), _color('#05070B')]}},
        ],
        "groups": [
            {"name": "Sun", "layers": [{"name": "Sun", "image-name": "sun.svg", "glass": True,
                                        "fill-specializations": _solid('#E0A85A', GOLD)}],
             "shadow": {"kind": "layer-color", "opacity": 0.5}, "specular": True,
             "translucency": {"enabled": False, "value": 0.5}},
            {"name": "Oort", "layers": [{"name": "Glyph", "image-name": "glyph.svg", "glass": glass,
                                         "fill-specializations": _solid('#1B2230', '#D6DEEA')
                                         + [{"appearance": "tinted", "value": {"solid": _color('#FFFFFF')}}]}],
             "shadow": {"kind": "neutral", "opacity": 0.4}, "specular": True,
             "translucency": {"enabled": False, "value": 0.5}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (root / 'icon.json').write_text(json.dumps(doc, indent=2) + '\n', encoding='utf-8')


def halftone_dots():
    return trame().split('>', 1)[1].rsplit('</svg>', 1)[0].rsplit(f'<circle r="{SUN}"/>', 1)[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Generate Oort NX icon and glyph SVGs.")
    parser.add_argument("output", type=Path)
    out = parser.parse_args().output
    out.mkdir(parents=True, exist_ok=True)
    assert density(0.9, 0) > 0.9 and density(-0.93, 0) > 0.6 and density(0, 0.5) == 0 and density(0.05, 0) == 0
    for th in THEMES:
        (out / f'icone-trame-{th}.svg').write_text(icon_trame(th), encoding='utf-8')
        (out / f'icone-particules-{th}.svg').write_text(icon_particules(th), encoding='utf-8')
        (out / f'icone-plein-{th}.svg').write_text(icon_plein(th), encoding='utf-8')
    (out / 'glyphe-trame.svg').write_text(trame(), encoding='utf-8')
    (out / 'glyphe-plein.svg').write_text(plein(), encoding='utf-8')
    icon_package(out / 'AppIcon.icon', halftone_dots(), glass=True)
    flat = re.sub(r' (fill|stroke)="#[0-9A-Fa-f]{6}"', lambda m: f' {m.group(1)}="#FFFFFF"', particules('sombre'))
    icon_package(out / 'AppIconParticles.icon', flat, glass=False)
