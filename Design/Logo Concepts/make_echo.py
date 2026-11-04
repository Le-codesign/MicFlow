"""Echo, refined: the listening pebble as a big character that fills the tile and runs off its
bottom edge, in one color family that fades from a light top to a deep bottom, with tall white
eyes set low, and the incoming ripples in the same family. Writes svg/echo-v2-*.svg.
Run: python3 make_echo.py
"""
import os

VARIANTS = {
    # Pale mint tile, lime-to-forest body: the main brand version.
    "mint": dict(tile_top="#F1FBE6", tile_bottom="#DDF3CF", body_top="#C9F56A", body_bottom="#1F7A45",
                 wave_top="#9BE05A", wave_bottom="#2E8B4F", eye="#FFFFFF"),
    # Charcoal tile, the same body: for dark Docks and the app's dark theme.
    "night": dict(tile_top="#24262A", tile_bottom="#141517", body_top="#D2F86F", body_bottom="#2B8F4E",
                  wave_top="#C6F432", wave_bottom="#6CC24A", eye="#FFFFFF"),
    # Forest tile, cream body fading to sage: the calmest version, closest to the app's green frame.
    "forest": dict(tile_top="#2F6B44", tile_bottom="#173B26", body_top="#FBF6E8", body_bottom="#BFE3B4",
                   wave_top="#F4F1EA", wave_bottom="#BFE3B4", eye="#173B26"),
}


def echo(v, mono=False):
    if mono:
        v = dict(tile_top="#FFFFFF", tile_bottom="#FFFFFF", body_top="#141414", body_bottom="#141414",
                 wave_top="#141414", wave_bottom="#141414", eye="#FFFFFF")
    outline = ' stroke="#141414" stroke-width="10"' if mono else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath>
  <linearGradient id="tileFill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{v['tile_top']}"/><stop offset="1" stop-color="{v['tile_bottom']}"/>
  </linearGradient>
  <linearGradient id="bodyFill" gradientUnits="userSpaceOnUse" x1="0" y1="300" x2="0" y2="980">
    <stop offset="0" stop-color="{v['body_top']}"/><stop offset="1" stop-color="{v['body_bottom']}"/>
  </linearGradient>
  <linearGradient id="waveFill" gradientUnits="userSpaceOnUse" x1="0" y1="360" x2="0" y2="760">
    <stop offset="0" stop-color="{v['wave_top']}"/><stop offset="1" stop-color="{v['wave_bottom']}"/>
  </linearGradient>
</defs>
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#tileFill)"{outline}/>
<g clip-path="url(#tile)">
  <!-- The pebble leans toward the sound on its right, and runs off the bottom of the tile. -->
  <g transform="rotate(6 420 700)">
    <path d="M 420 328 C 600 328 694 478 694 690 C 694 862 634 1000 420 1000 C 206 1000 146 862 146 690 C 146 478 240 328 420 328 Z"
          fill="url(#bodyFill)"/>
    <ellipse cx="362" cy="650" rx="40" ry="70" fill="{v['eye']}"/>
    <ellipse cx="496" cy="650" rx="40" ry="70" fill="{v['eye']}"/>
  </g>
  <!-- Two ripples spreading from a sound off to the right, toward the face: concentric arcs
       around (980, 575), the nearer one wider. -->
  <g fill="none" stroke="url(#waveFill)" stroke-linecap="round">
    <path d="M 816 460 A 200 200 0 0 0 816 690" stroke-width="40"/>
    <path d="M 882 506 A 120 120 0 0 0 882 644" stroke-width="38"/>
  </g>
</g>
</svg>'''


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
    os.makedirs(out, exist_ok=True)
    for name, v in VARIANTS.items():
        with open(os.path.join(out, f"echo-v2-{name}.svg"), "w") as f:
            f.write(echo(v))
    with open(os.path.join(out, "echo-v2-mono.svg"), "w") as f:
        f.write(echo(VARIANTS["mint"], mono=True))
    print("wrote", len(VARIANTS) + 1, "Echo icons")
