"""Draws the six MicFlow logo concepts as 1024x1024 SVG app icons, in color and monochrome.

Every icon sits on the macOS icon grid: an 824x824 rounded tile, corner radius 186, centered on a
1024 canvas. Colors come from the app's palette: charcoal, black, soft white, lime, deep green.
Run: python3 make_icons.py  (writes svg/*.svg next to this file)
"""
import os

CHARCOAL = "#18181B"
BLACK = "#0C0C0E"
SOFT_WHITE = "#F4F1EA"
LIME = "#C6F432"
DEEP_GREEN = "#12301F"
CORAL = "#FF7A59"
INK = "#141414"

TILE = '<rect x="100" y="100" width="824" height="824" rx="186" fill="{fill}"{stroke}/>'
CLIP = '<clipPath id="tile-{id}"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath>'


def svg(id, body, tile, mono):
    stroke = ' stroke="#141414" stroke-width="10"' if mono else ""
    edge = "" if mono else (
        '<rect x="103" y="103" width="818" height="818" rx="183" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="6"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{CLIP.format(id=id)}</defs>'
            f'{TILE.format(fill=tile, stroke=stroke)}'
            f'<g clip-path="url(#tile-{id})">{body}</g>{edge}</svg>')


def palette(mono, **colors):
    """In monochrome, the character is ink, its features cut out in white, on a white tile."""
    if not mono:
        return colors
    return {name: ("#FFFFFF" if name in ("tile", "feature", "gap") else INK) for name in colors}


# 1. Echo, the listening companion: a soft pebble tilted toward the sound it hears; the ripples
#    curve in toward it, arriving rather than leaving.
def echo(mono=False):
    c = palette(mono, tile=CHARCOAL, body=SOFT_WHITE, accent=LIME, feature=BLACK)
    if mono:
        c["feature"] = "#FFFFFF"
    body = f'''
<g transform="rotate(-10 450 540)">
  <ellipse cx="440" cy="545" rx="225" ry="248" fill="{c['body']}"/>
  <ellipse cx="395" cy="505" rx="24" ry="40" fill="{c['feature']}"/>
  <ellipse cx="490" cy="497" rx="24" ry="40" fill="{c['feature']}"/>
</g>
<g fill="none" stroke="{c['accent']}" stroke-linecap="round">
  <path d="M 752 468 A 95 95 0 0 0 752 612" stroke-width="40"/>
  <path d="M 838 410 A 190 190 0 0 0 838 670" stroke-width="36"/>
</g>'''
    return svg("echo", body, c["tile"], mono)


# 2. Moss, the intelligent digital creature: a dark being rising from the bottom edge, leaf sprouts up,
#    one bright eye open and one winking, as if it already knows what you're about to do.
def moss(mono=False):
    c = palette(mono, tile=LIME, body=INK, feature=SOFT_WHITE, pupil=INK)
    if mono:
        c.update(body=INK, feature="#FFFFFF", pupil=INK)
    body = f'''
<g fill="{c['body']}">
  <path d="M 390 470 C 300 430 270 330 300 238 C 380 280 430 370 420 470 Z"/>
  <path d="M 634 470 C 724 430 754 330 724 238 C 644 280 594 370 604 470 Z"/>
  <rect x="268" y="400" width="488" height="700" rx="244"/>
</g>
<circle cx="430" cy="585" r="56" fill="{c['feature']}"/>
<circle cx="446" cy="572" r="26" fill="{c['pupil']}"/>
<path d="M 556 594 Q 606 546 656 594" fill="none" stroke="{c['feature']}" stroke-width="30" stroke-linecap="round"/>'''
    return svg("moss", body, c["tile"], mono)


# 3. Iris, the focused observer: one large, curious lens-eye in a soft tilted face, a single blush
#    to keep it warm rather than watchful.
def iris(mono=False):
    c = palette(mono, tile=BLACK, body=SOFT_WHITE, accent=LIME, pupil=INK, feature="#FFFFFF", blush=CORAL)
    if mono:
        c.update(tile="#FFFFFF", body=INK, accent="#FFFFFF", pupil=INK, feature="#FFFFFF", blush="#FFFFFF")
    body = f'''
<g transform="rotate(7 512 520)">
  <rect x="236" y="244" width="552" height="552" rx="196" fill="{c['body']}"/>
  <circle cx="512" cy="500" r="168" fill="{c['accent']}"/>
  <circle cx="512" cy="500" r="92" fill="{c['pupil']}"/>
  <circle cx="548" cy="462" r="26" fill="{c['feature']}"/>
  <ellipse cx="672" cy="690" rx="44" ry="26" fill="{c['blush']}"/>
</g>'''
    return svg("iris", body, c["tile"], mono)


# 4. Trio, the adaptive shape-shifter: three of the product's shapes made into one figure: a round
#    head that listens, a screen for a body that captures, and a cursor for a hand that acts.
def trio(mono=False):
    c = palette(mono, tile=CHARCOAL, head=LIME, body=SOFT_WHITE, hand=LIME, feature=BLACK, gap=CHARCOAL)
    if mono:
        c.update(head=INK, body=INK, hand=INK, feature="#FFFFFF", gap="#FFFFFF")
    cursor = "610,540 610,812 672,752 716,852 768,830 724,732 810,732"
    body = f'''
<rect x="282" y="470" width="372" height="356" rx="96" fill="{c['body']}"/>
<g stroke="{c['feature']}" stroke-width="26" stroke-linecap="round">
  <line x1="384" y1="660" x2="384" y2="720"/><line x1="436" y1="630" x2="436" y2="750"/>
  <line x1="488" y1="600" x2="488" y2="780"/><line x1="540" y1="645" x2="540" y2="735"/>
</g>
<circle cx="468" cy="390" r="150" fill="{c['head']}" stroke="{c['gap']}" stroke-width="22"/>
<circle cx="422" cy="386" r="27" fill="{c['feature']}"/>
<circle cx="516" cy="386" r="27" fill="{c['feature']}"/>
<polygon points="{cursor}" fill="{c['hand']}" stroke="{c['gap']}" stroke-width="30" stroke-linejoin="round"/>
<polygon points="{cursor}" fill="{c['hand']}" stroke="{c['hand']}" stroke-width="10" stroke-linejoin="round"/>'''
    return svg("trio", body, c["tile"], mono)


# 5. Pill, the minimalist Mac companion: the app's own dictation pill, come alive: a black capsule
#    with two lime eyes, nothing else.
def pill(mono=False):
    c = palette(mono, tile=SOFT_WHITE, body=INK, feature=LIME)
    if mono:
        c.update(tile="#FFFFFF", body=INK, feature="#FFFFFF")
    shadow = "" if mono else '<ellipse cx="512" cy="690" rx="250" ry="34" fill="#000000" fill-opacity="0.10"/>'
    body = f'''
{shadow}
<rect x="196" y="392" width="632" height="250" rx="125" fill="{c['body']}"/>
<circle cx="560" cy="500" r="44" fill="{c['feature']}"/>
<circle cx="680" cy="500" r="44" fill="{c['feature']}"/>'''
    return svg("pill", body, c["tile"], mono)


# 6. Pointy, the unexpected original: the Mac's cursor itself as a lively little character, one eye
#    and a grin, leaning forward, ready to go.
def pointy(mono=False):
    c = palette(mono, tile=DEEP_GREEN, body=LIME, feature=SOFT_WHITE, pupil=INK, mouth=INK)
    if mono:
        c.update(body=INK, feature="#FFFFFF", pupil=INK, mouth="#FFFFFF")
    arrow = "322,206 322,780 462,648 562,872 650,834 552,612 742,612"
    body = f'''
<polygon points="{arrow}" fill="{c['body']}" stroke="{c['body']}" stroke-width="56" stroke-linejoin="round"/>
<circle cx="428" cy="468" r="62" fill="{c['feature']}"/>
<circle cx="446" cy="460" r="30" fill="{c['pupil']}"/>
<path d="M 392 600 Q 440 640 488 596" fill="none" stroke="{c['mouth']}" stroke-width="22" stroke-linecap="round"/>'''
    return svg("pointy", body, c["tile"], mono)


CONCEPTS = [("echo", echo), ("moss", moss), ("iris", iris), ("trio", trio), ("pill", pill), ("pointy", pointy)]

if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
    os.makedirs(out, exist_ok=True)
    for name, draw in CONCEPTS:
        for mono in (False, True):
            path = os.path.join(out, f"{name}{'-mono' if mono else ''}.svg")
            with open(path, "w") as f:
                f.write(draw(mono))
    print("wrote", len(CONCEPTS) * 2, "icons to", out)
