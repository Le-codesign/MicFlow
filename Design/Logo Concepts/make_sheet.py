"""Builds "Logo Concepts.html": the comparison sheet, each concept large with its write-up,
monochrome version, size test and evaluation. Run after make_icons.py."""
import os

HERE = os.path.dirname(os.path.abspath(__file__))

CONCEPTS = [
    dict(id="echo", n=1, name="Echo", direction="The Listening Companion",
         one="A soft white pebble that tilts its head toward the sound arriving at it.",
         metaphor="The ripples curve in toward the face rather than out of it, so the character is hearing, not broadcasting. That's the moment voice typing begins, and it extends to the screen and mouse tools as an app that pays attention to what you do.",
         personality="Attentive, gentle, patient: the friend who lets you finish your sentence.",
         palette=[("Charcoal", "#18181B"), ("Soft white", "#F4F1EA"), ("Lime", "#C6F432"), ("Black", "#0C0C0E")],
         longterm="The tilt and the incoming ripples are a gesture rather than a picture, so they animate naturally (the ripples can pulse while you dictate) and they still read in a monochrome stamp.",
         scores=[4, 3, 5, 3, 4, 4, 3]),
    dict(id="moss", n=2, name="Moss", direction="The Intelligent Digital Creature",
         one="A dark creature with two leaf sprouts, rising from the bottom of the tile with one eye open and one winking.",
         metaphor="The wink says it already knows the shortcut you want. The creature isn't tied to any one feature, so it can stand for the whole toolkit, and the sprouts link it to the green of the app.",
         personality="Clever, a little mischievous, quietly confident.",
         palette=[("Lime", "#C6F432"), ("Ink", "#141414"), ("Soft white", "#F4F1EA")],
         longterm="A full mascot with expressions to spare (open eyes, closed eyes, a wink), easy to use in onboarding, empty states and stickers. The sprout silhouette is the most ownable shape of the six.",
         scores=[5, 4, 4, 3, 5, 4, 5]),
    dict(id="iris", n=3, name="Iris", direction="The Focused Observer",
         one="A tilted soft-square face with one large lime lens for an eye and a single coral blush.",
         metaphor="The lens is a camera aperture and an eye at once: screenshots, recordings and text capture are the app seeing your screen. The blush and the tilt keep it curious and friendly rather than watchful.",
         personality="Curious, observant, warm.",
         palette=[("Black", "#0C0C0E"), ("Soft white", "#F4F1EA"), ("Lime", "#C6F432"), ("Coral (support)", "#FF7A59")],
         longterm="The concentric lens is instantly recognizable at 16 px and doubles as a record indicator. The risk: it leans toward the capture features more than voice.",
         scores=[4, 3, 5, 4, 4, 5, 3]),
    dict(id="trio", n=4, name="Trio", direction="The Adaptive Shape-Shifter",
         one="One figure made of three product shapes: a round listening head, a screen body showing a waveform, and a cursor for a hand.",
         metaphor="Each shape is a capability: the head is voice, the screen is capture, the hand is the mouse tools. Together they read as one helpful character, which is exactly the promise of several utilities in one app.",
         personality="Versatile, eager, a capable all-rounder.",
         palette=[("Charcoal", "#18181B"), ("Lime", "#C6F432"), ("Soft white", "#F4F1EA"), ("Black", "#0C0C0E")],
         longterm="The clearest story of the six and modular for the future: a new feature can become a new shape or a new prop. At 16 px the waveform blurs, so the small icon would drop it.",
         scores=[3, 5, 3, 4, 4, 4, 5]),
    dict(id="pill", n=5, name="Pill", direction="The Minimalist Mac Companion",
         one="The app's own dictation pill, come alive: a black capsule with two lime eyes glancing to the side.",
         metaphor="The capsule is what you already see on screen while dictating, so the logo and the product are the same object. The sideways glance gives it life with nothing more than two dots.",
         personality="Calm, discreet, always ready.",
         palette=[("Soft white", "#F4F1EA"), ("Ink", "#141414"), ("Lime", "#C6F432")],
         longterm="The purest silhouette here; it survives at 16 px and in any single color. It also connects branding to interface: the glowing pill during dictation becomes the mascot at work. One caution: it can be read as a toggle switch with eyes, so the eyes must stay round.",
         scores=[4, 4, 5, 4, 4, 5, 4]),
    dict(id="pointy", n=6, name="Pointy", direction="The Unexpected Original",
         one="The Mac's mouse cursor itself as a lively lime character, with one eye and a grin, leaning forward.",
         metaphor="The cursor is the one thing everyone uses on a Mac; turning it into a character says this app makes everything you point at easier: dictate, capture, scroll, switch Spaces.",
         personality="Energetic, witty, ready to act.",
         palette=[("Deep green", "#12301F"), ("Lime", "#C6F432"), ("Soft white", "#F4F1EA"), ("Ink", "#141414")],
         longterm="The cursor shape is universally understood and unusual as a mascot, so it's memorable. It can point, nudge and react in animations, and it works as a monochrome glyph.",
         scores=[5, 4, 5, 4, 5, 4, 4]),
]

CRITERIA = ["Memorability", "Brand fit", "Simplicity", "Originality", "Personality", "macOS fit", "Scalability"]


def icon(name, mono=False):
    with open(os.path.join(HERE, "svg", f"{name}{'-mono' if mono else ''}.svg")) as f:
        return f.read().replace('width="1024" height="1024"', 'width="100%" height="100%"')


def concept_section(c):
    swatches = "".join(f'<div class="sw"><span style="background:{hex}"></span>{label}<code>{hex}</code></div>'
                       for label, hex in c["palette"])
    sizes = "".join(f'<div class="sz"><div style="width:{px}px;height:{px}px">{icon(c["id"])}</div><small>{px}</small></div>'
                    for px in (16, 32, 64, 128))
    scores = "".join(f'<tr><td>{name}</td><td>{"●" * s}<span class="off">{"●" * (5 - s)}</span></td></tr>'
                     for name, s in zip(CRITERIA, c["scores"]))
    return f'''
<section class="concept">
  <div class="art">
    <div class="big">{icon(c["id"])}</div>
    <div class="row">
      <figure><div class="mid">{icon(c["id"], mono=True)}</div><figcaption>Monochrome</figcaption></figure>
      <figure><div class="bgs"><div class="light">{icon(c["id"])}</div><div class="dark">{icon(c["id"])}</div></div>
        <figcaption>On light and dark</figcaption></figure>
    </div>
    <div class="sizes">{sizes}</div>
  </div>
  <div class="text">
    <p class="kicker">Concept {c["n"]} · {c["direction"]}</p>
    <h2>{c["name"]}</h2>
    <p class="one">{c["one"]}</p>
    <h3>Visual metaphor</h3><p>{c["metaphor"]}</p>
    <h3>Personality</h3><p>{c["personality"]}</p>
    <h3>Palette</h3><div class="swatches">{swatches}</div>
    <h3>Why it can last</h3><p>{c["longterm"]}</p>
    <h3>Evaluation</h3><table class="scores">{scores}</table>
  </div>
</section>'''


def main():
    grid = "".join(f'<figure><div class="tile">{icon(c["id"])}</div><figcaption><b>{c["n"]}. {c["name"]}</b>'
                   f'<span>{c["direction"]}</span></figcaption></figure>' for c in CONCEPTS)
    head = "".join(f"<th>{c['name']}</th>" for c in CONCEPTS)
    rows = "".join("<tr><td>" + name + "</td>" + "".join(f"<td>{c['scores'][i]}</td>" for c in CONCEPTS) + "</tr>"
                   for i, name in enumerate(CRITERIA))
    totals = "<tr class='total'><td>Total (of 35)</td>" + "".join(f"<td>{sum(c['scores'])}</td>" for c in CONCEPTS) + "</tr>"
    html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>MicFlow Logo Concepts</title>
<style>
:root {{ --bg:#0B0B0C; --card:#141416; --text:#F4F1EA; --muted:#9A9A9A; --lime:#C6F432; --line:rgba(255,255,255,.08); }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.55 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; }}
main {{ max-width:1180px; margin:0 auto; padding:56px 28px 80px; }}
h1 {{ font-size:44px; line-height:1.05; letter-spacing:-.02em; margin:0 0 10px; font-weight:800; }}
.lede {{ color:var(--muted); max-width:720px; margin:0 0 44px; }}
.grid {{ display:grid; grid-template-columns:repeat(3,1fr); gap:26px; background:var(--card); border:1px solid var(--line);
  border-radius:28px; padding:40px; }}
.grid figure {{ margin:0; text-align:center; }}
.grid .tile {{ width:200px; height:200px; margin:0 auto 12px; }}
.grid figcaption b {{ display:block; font-size:16px; }}
.grid figcaption span {{ color:var(--muted); font-size:13px; }}
.concept {{ display:grid; grid-template-columns:420px 1fr; gap:44px; padding:56px 0; border-bottom:1px solid var(--line); }}
.big {{ width:420px; height:420px; }}
.row {{ display:flex; gap:20px; margin-top:18px; }}
.row figure {{ margin:0; }}
.row figcaption {{ color:var(--muted); font-size:12px; margin-top:6px; }}
.mid {{ width:150px; height:150px; background:#fff; border-radius:24px; padding:6px; }}
.bgs {{ display:flex; border-radius:24px; overflow:hidden; }}
.bgs > div {{ width:125px; height:150px; padding:22px 12px; }}
.bgs .light {{ background:#ECECEC; }} .bgs .dark {{ background:#1E1E1E; }}
.sizes {{ display:flex; align-items:flex-end; gap:22px; margin-top:20px; padding:18px; background:#1E1E1E; border-radius:20px; }}
.sz {{ text-align:center; }} .sz small {{ color:var(--muted); font-size:11px; }}
.kicker {{ color:var(--lime); font-size:12px; font-weight:700; letter-spacing:.06em; text-transform:uppercase; margin:6px 0 4px; }}
h2 {{ font-size:40px; margin:0 0 8px; letter-spacing:-.02em; font-weight:800; }}
h3 {{ font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); margin:22px 0 6px; }}
.one {{ font-size:18px; margin:0; }}
.text p {{ margin:0; max-width:620px; }}
.swatches {{ display:flex; flex-wrap:wrap; gap:10px; }}
.sw {{ display:flex; align-items:center; gap:8px; background:var(--card); border:1px solid var(--line); border-radius:99px; padding:5px 12px 5px 5px; font-size:13px; }}
.sw span {{ width:22px; height:22px; border-radius:50%; border:1px solid rgba(255,255,255,.15); }}
.sw code {{ color:var(--muted); font-size:11px; }}
table {{ border-collapse:collapse; }}
.scores td {{ padding:3px 18px 3px 0; font-size:13px; }}
.scores td:last-child {{ color:var(--lime); letter-spacing:2px; }}
.off {{ color:#333; }}
.summary {{ margin-top:56px; }}
.summary table {{ width:100%; background:var(--card); border:1px solid var(--line); border-radius:20px; overflow:hidden; }}
.summary th, .summary td {{ padding:12px 14px; text-align:center; border-bottom:1px solid var(--line); font-size:14px; }}
.summary td:first-child, .summary th:first-child {{ text-align:left; color:var(--muted); }}
.summary .total td {{ font-weight:800; color:var(--lime); border-bottom:0; }}
.reco {{ margin-top:28px; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:24px 28px; }}
.reco h3 {{ margin-top:0; }}
@media (max-width: 900px) {{
  .grid {{ grid-template-columns:repeat(2,1fr); padding:24px; }}
  .grid .tile {{ width:140px; height:140px; }}
  .concept {{ grid-template-columns:1fr; }}
  .big {{ width:100%; height:auto; aspect-ratio:1; }}
}}
</style></head>
<body><main>
<h1>MicFlow logo concepts</h1>
<p class="lede">Six original character directions for a Mac utility that listens, sees and acts: voice typing, screen capture and recording, and mouse tools in one app. Each is a vector macOS icon on the standard 824&#8202;pt tile, in charcoal, black, soft white and lime, with one supporting color where it helps.</p>
<div class="grid">{grid}</div>
{"".join(concept_section(c) for c in CONCEPTS)}
<div class="summary">
  <h2>Side by side</h2>
  <table><tr><th>Criterion (1–5)</th>{head}</tr>{rows}{totals}</table>
  <div class="reco">
    <h3>Recommendation</h3>
    <p><b>Pointy</b> scores highest (31), with <b>Moss</b> and <b>Pill</b> close behind (30 each). Pointy and Moss are ownable silhouettes with real personality, and neither is tied to a single feature. Pill is the safest premium choice and links the brand to the dictation pill you see on screen. A strong next step is to take one of these three into a refinement round: expressions, a Dock-size version, and the menu bar glyph.</p>
  </div>
</div>
</main></body></html>'''
    with open(os.path.join(HERE, "Logo Concepts.html"), "w") as f:
        f.write(html)
    print("wrote Logo Concepts.html")


if __name__ == "__main__":
    main()
