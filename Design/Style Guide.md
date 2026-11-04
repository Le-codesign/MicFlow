# MicFlow style guide

Based on the "Calendar / Weekly Productivity / Archive Project" dashboard references. The look
is a **dark (or forest green) app frame holding a mix of dark and light cards**, with a few loud,
flat, friendly colors (pink, yellow, orange, lavender, cream) used only where something matters.
It feels like a well-made physical planner: chunky type, round chips, dashed placeholders,
playful stickers. No glows, no neon, no gradient haze.

## 1. Color

### Surfaces
| Token | Hex | Use |
|---|---|---|
| `canvas` | `#E4E9E4` | Outside the app frame (pale grey-green paper) |
| `frame.dark` | `#141414` | App frame and sidebar, dark theme |
| `frame.green` | `#2B5036` | App frame and sidebar, green theme (the reference's toggle) |
| `card.dark` | `#232323` | Dark cards on the dark frame |
| `card.green` | `#335E41` | Cards on the green frame (a step lighter than the frame) |
| `card.light` | `#FFFFFF` | The one big light panel (schedule) and light cards |
| `row.selected` | `#2E2E2E` dark / `#F2F2F0` light | Hovered or selected list row |
| `hairline` | white 8% on dark, black 7% on light | Card borders, dashed grid lines |

### Accents (flat, saturated, used sparingly)
| Token | Hex | Meaning in the references |
|---|---|---|
| `pink` | `#F66399` | Special or selected days, badges, the "+" button |
| `yellow` | `#FFB413` | The one urgent card, the primary button, today's bar |
| `orange` | `#F2621F` → `#FF8A3D` | Image card (wavy texture), "Details" button |
| `lavender` | `#B99AF6` | A task card |
| `cream` | `#FBEBC9` | Day circles, selected pill on dark |
| `mint` | `#DDF3E2` with `#2E9E57` text | "Add new task" dashed slot |

Rule of thumb: about **80% neutral surfaces, 15% cream/white, 5% loud accents**. A screen has
one yellow thing. Pink marks what's special. Accents never touch each other without a neutral gap.

### Text
| Token | On dark | On light |
|---|---|---|
| primary | `#FFFFFF` | `#141414` |
| secondary | `#9A9A9A` | `#8A8A8A` |
| on accent | `#141414` (on yellow, cream, mint) / `#FFFFFF` (on pink, orange, lavender) | |

## 2. Type

- **Display:** a chunky, slightly condensed grotesk, bold to heavy (the reference's "Meet Nadhim
  at Gramedia today", "June, 2025", "14/Mon"). In SwiftUI: system font, `.bold`/`.heavy`, width
  `.condensed`, tight tracking.
- **Body and labels:** the system sans at regular/medium, small (11–13 pt).
- **Number + unit pairs:** the number heavy and big, the unit light and grey right after it
  (`14` **/Mon**, `20` hr).

| Role | Size / weight |
|---|---|
| Page title ("June, 2025") | 30 pt heavy condensed, with a ⌄ after it |
| Hero card title | 24 pt heavy condensed, 2 lines max |
| Card title ("Calendar") | 14 pt semibold, with an 11 pt grey subtitle under it |
| Column header (`14/Mon`) | 22 pt heavy + 12 pt regular grey |
| Body / list rows | 13 pt regular |
| Small labels, axis | 10–11 pt medium, grey |
| Badges | 10 pt bold in a pink circle |

## 3. Shape and spacing

- **Radii:** app frame 32, cards 22–24, inner tiles 14–16, buttons and pills fully round.
- **Day chips:** perfect circles about 32 pt, 4 pt gap; days outside the month are dashed circles.
- **Spacing:** 8 pt grid. Gap between cards 10–12 (cards nearly touch, like tiles in a box).
  Card padding 16–18.
- **Dashed lines:** 1 pt, dash 4/4, for the time grid and empty "add" slots (dashed border with
  a tinted fill).
- **No shadows** on dark; a very soft one (black 6%, y 8, blur 24) only under light cards
  floating on the canvas.

## 4. Components

- **Sidebar:** a narrow column (72 pt) of outline icons, 20 pt, grey; the active one white. The
  logo mark at the top; avatars and a pink "+" circle lower; a sun/moon switch at the bottom
  that swaps the dark and green frames.
- **Card header:** an icon in a cream circle + title + grey subtitle on the left, a ↗ / ⋯ / ⌄
  icon on the right.
- **Pill group:** a cream (on dark) or black (on light) filled pill for the selected option; the
  others outlined (on dark) or plain text (on light), all fully round.
- **Hero event card:** yellow, black text, a small time label top-left, a white "48 min" chip
  top-right, a big 2-line title, an orange filled button + a plain text button, and a sticker
  illustration breaking out of the bottom-right corner.
- **Schedule card:** white, a column header per day, an hour column on the left, dashed grid,
  colored cards placed in the grid (orange image card, lavender checklist card, pink image card,
  yellow image card, a mint dashed "add" slot).
- **Bar chart:** dark grey rounded bars (two stacked tones), one highlighted bar in yellow over
  orange diagonal stripes, a dark tooltip with colored-square legend.
- **List card (Archive Project):** rows of icon + name + grey suffix, one row with a lighter
  background and a trailing action icon.
- **Checklist card (Categories):** square checkboxes, labels, pink count badges.

## 5. Hierarchy

1. Color decides importance: the yellow card is read first, then the pink days, then the white panel.
2. A big light panel inside the dark frame holds the main content; dark cards hold the supporting
   facts.
3. Each card answers one question, with its title at the top left and its action at the top right.
4. Numbers are the heroes inside cards; labels stay small and grey.

## 6. Applied to MicFlow Home

| Reference piece | MicFlow Home |
|---|---|
| Calendar card | **Activity:** this month as day circles; days you dictated in pink, today ringed |
| Yellow event card | **Today:** "1,240 words today" with a WPM chip, Copy last and History buttons, a mic sticker |
| Categories card | **Languages:** English and Bengali with pink word-share badges |
| White schedule panel | **Today's dictations** on an hour grid, each a colored card |
| Weekly Productivity | **Weekly words** bars, today in yellow stripes, with a tooltip |
| Archive Project list | **Your numbers:** average speed, total words, streak, time saved |
| Sun/moon switch | Dark and green themes |
