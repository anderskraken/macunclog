# MacUnclog menu bar icon prompts

The renders from each round are not kept; the final glyphs are in the asset catalog, with previews in `MenuBarPlunger-288.png`, `MenuBarPlungerFilled-288.png`, `sizes.png` and `menubar.png`. `render.swift` redraws them.

Generated with Codex CLI 0.159.2. Round 1 used image generation (`codex exec --skip-git-repo-check -s read-only -`, prompt on stdin) to explore shapes; later rounds had Codex write the SVGs by hand (`codex exec --skip-git-repo-check -s workspace-write -C <round dir> -i <images> -`). `render.swift` draws each SVG through AppKit (`NSImage`, the same CoreSVG path the asset catalog uses) as a tinted template image: black on a light bar, white on a dark bar, next to SF Symbols.

## Round 1: shape exploration (image generation) → `explore/r1-concepts.png`

```
Use your image generation tool to generate exactly one square 1024x1024 image. Do not write any code, do not draw with code; just call image generation once and then stop.

The image is a design exploration sheet for a macOS menu bar icon: a 3x2 grid of six different pictogram glyphs of a toilet plunger (a rubber suction cup with a straight stick handle), drawn in the exact style of Apple SF Symbols at Regular weight: pure flat black on a plain white background, uniform medium stroke weight with rounded caps and joins, simple geometric construction, no shading, no gradients, no colour, no text, no labels, no numbers, no grid lines. Each glyph sits centered in its own cell with generous white space and is drawn as if it must stay readable at 16 pixels next to the Wi-Fi and battery icons.

The six variants:
1. Upright plunger, front view: a wide dome-shaped cup outline sitting on a short flat rim, a straight vertical handle rising from the cup top, small round knob at the top of the handle.
2. Same as 1 but the cup is a solid black filled dome (the ".fill" variant).
3. Upright plunger with a bell-shaped cup that flares out at the bottom like a bell, outline only, handle without a knob, rounded handle end.
4. Plunger tilted about 20 degrees to the right, cup outline, as if mid-pump, with two tiny short motion ticks beside the cup.
5. Compact plunger: short handle, the cup is a half-circle with a slightly wider flat lip line below it, outline only, very bold simple silhouette.
6. Plunger seen in three-quarter view, the cup showing an elliptical opening at the bottom, outline only.
```

## Round 2: first SVGs, upright (A) and tilted (B) → `r2/`

Attached: `explore/r1-concepts.png`.

```
You are designing the macOS menu bar status item icon for MacUnclog, a utility that unclogs a slow Mac. Its app icon is a red rubber plunger. The attached image is an exploration sheet of plunger pictograms (row 1: upright with knob, upright filled, bell-shaped; row 2: tilted mid-pump, compact half-dome, three-quarter view).

Write SVG files by hand into the current directory (design/menubar/r2). Do not generate raster images and do not edit anything outside this directory.

Hard requirements for every SVG:
- Root element exactly: <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
- Black (#000) shapes only: fill="#000" and/or stroke="#000". No other colours, no opacity, no gradients, no filters, no masks, no clipPath, no <image>, no text, no transforms that are not needed.
- Nothing may extend outside the 0..18 viewBox, including stroke width and round caps. Keep at least 1 unit of margin on every side.
- Style: Apple SF Symbols at Regular weight, as used in the macOS menu bar next to Wi-Fi, battery and Control Centre. Uniform stroke weight of 1.5 units (handle may be a 1.75-unit stroke so it does not look thinner than the cup outline at small sizes), round line caps and round joins, simple geometric curves, smooth symmetric Bezier arcs. Prefer stroke-based outlines (SF Symbols outline style) with stroke-linecap="round" stroke-linejoin="round".
- It must read as a plunger at 16x16 pixels: the rubber cup must be big (roughly 11 to 13 units wide, 5 to 6.5 units tall including rim), the handle must be clearly a straight stick rising from the top centre of the cup with a short collar/neck where it enters the cup, and there must be a flat rim/lip line along the bottom of the cup that is slightly wider than the dome. No knob ball on the handle (it reads as a pin); end the handle with a round cap. No motion lines.
- Optical centring: the overall glyph's visual mass centred in the 18x18 box; it is fine for the glyph to use the full height from y=1 to y=17.
- Coordinates on a 0.25 grid where possible, so horizontal and vertical edges land on pixel boundaries at 1x and 2x.

Make two design directions, each in two variants with identical silhouettes:
Direction A (upright, based on concept 1 without the knob, cup closer to concept 5's proportions):
  A-outline.svg: cup as an outline (stroke only), rim as a rounded bar or thick line, handle a stroke.
  A-filled.svg: identical silhouette, but the cup dome is solid black (like an SF Symbols .fill variant). Keep the rim readable as a separate lip by leaving a thin transparent gap (about 0.75 units) between the filled dome and the rim, as SF Symbols do to separate parts in .fill glyphs.
Direction B (tilted about 15 degrees clockwise, as if mid-pump, matching the tilted plunger in the app icon; based on concept 4 without the motion ticks): B-outline.svg and B-filled.svg with the same rules. Apply the tilt by computing the rotated coordinates yourself, or with a single transform="rotate(15 9 9)" on a group if you keep everything inside the viewBox after rotation; verify the rotated bounding box stays inside 1..17.

After writing the files, verify each file: check that it is valid XML, that the root element is exactly as specified, and compute the bounding box of all shapes including half the stroke width to confirm it stays within 0.75..17.25. If you can, render them to check by eye: `qlmanage -t -s 288 -o /tmp/<dir> file.svg` or `swift ../render.swift <outdir> name=file.svg` (the second renders the way AppKit draws a template image; it may fail in a sandbox, that is fine). Fix anything that is off. Finish by printing the contents of the four SVG files.
```

## Round 3: refinement from renders → `r3/`

Attached: `r2/menubar.png`, `r2/large-sheet.png`, the app icon at 512 px.

```
Round 3 of the MacUnclog menu bar icon. You wrote ../r2/A-outline.svg, ../r2/A-filled.svg (upright) and ../r2/B-outline.svg, ../r2/B-filled.svg (tilted 15 degrees). Read them first. The attached images are: (1) an AppKit render of those four SVGs as template images in a mock macOS menu bar next to SF Symbols, each bar at 1x and then 2x, light then dark; order of glyphs top to bottom is A-outline, A-filled, B-outline, B-filled; (2) the same four SVGs at 288 px on an 18x18 grid; (3) the app icon whose plunger this glyph should echo.

What is wrong at 16 to 18 px:
- The cup is too small and too flat relative to the 18x18 box and to the Wi-Fi glyph next to it; the upright version reads as a desk lamp or a triangle on a stick, not as a plunger.
- The rim barely overhangs the dome (0.5 unit each side), so the characteristic plunger silhouette, a rounded rubber bell that flares out into a wider lip, is lost. Compare the app icon: a bulbous dome, slightly pinched above a clearly wider flared lip.
- The collar (8.25..9.75 at y 10.25) is invisible; either make it a real neck (a short wider segment where the handle enters the cup, about 3 units wide and 1.25 units tall, rounded) or drop it.
- The glyph uses only about 10.5 to 11.5 units of the width; it looks lighter and smaller than the neighbouring system icons.

Write refined versions into the current directory (design/menubar/r3), same hard rules as before: root element exactly <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">, #000 fill/stroke only, no opacity, gradients, masks, clip paths, images or text, everything (including stroke caps) inside 0.75..17.25, SF Symbols Regular look with 1.5-unit strokes (handle 1.75), round caps and joins, 0.25 grid where possible.

Make:
- A-outline.svg and A-filled.svg: upright. Cup about 13 to 14 units wide at the lip and 7 to 7.5 units tall including the lip; the dome itself about 10.5 to 11 units wide, with sides that curve down and then flare outwards into the lip (a bell/rubber-cup profile, not a semicircle), and the lip a rounded horizontal bar about 1.75 units tall spanning the full width. Handle a straight 1.75 stroke from about y=1.25 down into the neck. Bottom of the lip at about y=16.5; whole glyph optically centred horizontally at x=9.
- A-filled.svg: identical outer silhouette; the dome is solid, separated from the lip by a 0.75-unit transparent gap that runs the full width so the lip still reads as its own part (like SF Symbols .fill variants). Handle and neck unchanged.
- B-outline.svg and B-filled.svg: the same refined shape tilted 12 to 15 degrees clockwise, translated so its bounding box is optically centred in the 18x18 box.

Then check each file: valid XML, exact root element, stroke-inclusive bounding box inside 0.75..17.25. Render them with `swift ../render.swift . A-outline=A-outline.svg A-filled=A-filled.svg B-outline=B-outline.svg B-filled=B-filled.svg` (writes menubar.png, sizes.png and *-288.png into this directory), look at menubar.png and sizes.png yourself, and fix what still does not read as a plunger at 16 px. Iterate up to three times. Finish by printing the final contents of the four SVGs and one sentence per direction on how it reads at 16 px.
```

## Round 4: polish of direction A → `r4/`

Attached: `r3/sizes.png`, `r3/menubar.png`.

```
Round 4, final polish of the MacUnclog menu bar icon. The upright direction A was chosen. Read ../r3/A-outline.svg and ../r3/A-filled.svg. The attached images are ../r3/sizes.png (rows: A-outline light, A-outline dark, A-filled light, A-filled dark, then B rows that you can ignore; columns: 16 px 1x, 16 px 2x, 18 px 1x, 18 px 2x, 22 px 1x, 22 px 2x, magnified 4x nearest-neighbour) and ../r3/menubar.png (the glyph at the far left of a mock macOS menu bar, 1x and 2x, light and dark).

Keep the concept and overall silhouette: straight handle, small rounded neck, bulbous rubber dome that flares into a wider rounded lip bar; the filled variant has a solid dome separated from the lip by a full-width transparent gap. Polish only:
1. Pixel fit. The icon is drawn at 18x18 pt in the menu bar, so 1 unit = 1 px at 1x and 2 px at 2x. Put every horizontal edge (lip top and bottom, dome/lip gap, neck top and bottom, handle cap end) on a 0.5-unit grid, and preferably on whole units for the lip and the gap so they are sharp at 1x. Keep the handle 1.75 wide centred on x=9 unless 2.0 reads clearly better.
2. Outline counter. At 16 px 1x the inside of the outline cup almost closes up; make the hollow inside the dome a little more open (for example a slightly thinner wall of 1.25 to 1.5 units at the sides where the dome meets the flare, or a slightly taller dome) without making the outline look lighter than SF Symbols Regular next to it.
3. Weight match. Next to Wi-Fi and the magnifying glass the outline should look the same weight, and the filled variant should look solid but not blotchy; at 16 px 1x the gap in the filled variant must still be visible as a clean light line.
4. Optical centring: the visual centre of mass of the glyph should sit at about (9, 9.25) to (9, 9.5) because the heavy part is at the bottom; the glyph may use y from 1 to 17.

Same hard rules: root element exactly <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">, #000 fill/stroke only, no opacity, gradients, masks, clip paths, transforms, images or text, everything including stroke caps inside 0.75..17.25. Write A-outline.svg and A-filled.svg into the current directory (design/menubar/r4) and nothing else besides the renders. Check XML validity, the root element and the stroke-inclusive bounding box, then render with `swift ../render.swift . A-outline=A-outline.svg A-filled=A-filled.svg`, look at sizes.png and menubar.png, compare against the round 3 renders, and iterate up to three times. Finish by printing both SVGs and two sentences on how each reads at 16 px 1x.
```

## What ships

`r4/A-outline.svg` is `MenuBarPlunger.svg` and `r4/A-filled.svg` is `MenuBarPlungerFilled.svg`, unchanged. The upright direction won over the tilted one (B, rounds 2 and 3) because its lip and gap land on whole pixels and stay sharp at 1x, while the tilted lip turns jagged and its outline hollow closes up at 16 px.

Previews of the shipped files: `MenuBarPlunger-288.png`, `MenuBarPlungerFilled-288.png`, `sizes.png` (16, 18 and 22 px at 1x and 2x, magnified 4x), `menubar.png` (status bar mock beside SF Symbols `magnifyingglass`, `wifi`, `battery.75percent` and `switch.2`, at 1x and 2x, light and dark). `v0/` holds the same renders of the earlier hand-drawn glyph. Regenerate with:

    swift render.swift . MenuBarPlunger=<path>/MenuBarPlunger.svg MenuBarPlungerFilled=<path>/MenuBarPlungerFilled.svg
