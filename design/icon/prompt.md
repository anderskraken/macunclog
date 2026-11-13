# MacUnclog app icon prompts

Generated with Codex CLI 0.159.2 image generation (`codex exec --skip-git-repo-check -s read-only ...`). Codex saves images to `~/.codex/generated_images/<session-id>/exec-*.png` at 1254x1254. Post-processing (crop, 824x824 squircle mask with radius 185 on a 1024 canvas, soft drop shadow) is done by `build_icon.py`.

## Concepts (no reference image)

Only the chosen concept's refinements (`concept-C-R2.png`, `concept-C-R2-small.png`) are kept in the repository; they are the inputs to `build_icon.py`.

Each concept prompt is the shared prefix followed by its subject sentence.

Shared prefix:

```
Use your image generation tool to generate exactly one square 1024x1024 image. Do not write any code, do not draw with code; just call image generation once and then stop. The image is a macOS app icon for "MacUnclog", a utility that finds why a Mac is slow and unclogs it with one click. Style: modern macOS app icon (Big Sur to Tahoe era), chunky glossy softly-lit 3D render, light from the top, soft ambient occlusion, rich but limited palette, one strong central subject with a bold silhouette readable at 16x16 pixels. The artwork fills a rounded-square (squircle) icon body centered on a plain flat white canvas with generous margins, as in Apple macOS icon template. Absolutely no text, no letters, no logos, no Apple logo. No cream or beige background, no pill shapes, no thick accent stroke along one edge.
```

### concept-A.png

```
Subject: a cheerful round blob mascot (bright teal-mint, big friendly eyes, small smile) gripping a red rubber plunger and yanking a cork out of the end of a chunky chrome pipe; the cork is flying off with a burst of white sparkles and little bubbles. Icon body background: deep indigo-to-violet gradient.
```

### concept-B.png

```
Subject: a thick glossy curved chrome pipe elbow seen at three-quarter view, with a wooden cork stopper shooting out of its mouth toward the upper right, followed by a bright cyan-blue whoosh of rushing water and sparkles, speed lines. Icon body background: warm saturated orange-to-coral gradient.
```

### concept-C.png

```
Subject: a big glossy red rubber plunger head (cup facing down) with a short wooden handle, front and center, with a tiny cute face on the red cup (eyes and grin), and a starburst of yellow sparkles and pop lines around it as if it just made a satisfying pop. Icon body background: vivid electric blue gradient with a subtle radial glow behind the plunger.
```

## Refinements of concept C (`-i concept-C.png`, prompt on stdin)

### concept-C-R1.png

```
Use your image generation tool to generate exactly one square 1024x1024 image, using the attached image as the style and subject reference. Do not write any code; just call image generation once and then stop. Recreate this macOS app icon artwork as FULL-BLEED square art: the vivid electric-blue gradient background (lighter radial glow behind the subject, deeper blue toward the corners) must fill the entire square canvas edge to edge, with no rounded-rectangle frame, no white margin, no border, no drop shadow. Keep the same subject: a big glossy red rubber plunger cup with a cute happy face (closed smiling eyes, open grin) and a short warm wooden handle, chunky glossy 3D render, soft light from the top. Make the subject slightly larger and keep it fully inside the central 75 percent of the canvas so it survives a rounded-corner mask. Simplify the surrounding effects for small-size legibility: just four or five bold chunky yellow sparkle stars and pop lines, evenly balanced. No text, no letters, no logos.
```

### concept-C-R2.png

```
Use your image generation tool to generate exactly one square 1024x1024 image, using the attached image as the style and subject reference. Do not write any code; just call image generation once and then stop. Recreate this macOS app icon artwork as FULL-BLEED square art: the vivid electric-blue gradient background (lighter radial glow behind the subject, deeper blue toward the corners) fills the entire square canvas edge to edge, with no rounded-rectangle frame, no white margin, no border, no drop shadow. Subject: the same glossy red rubber plunger with a cute happy face and a short wooden handle, chunky glossy 3D, soft top light, slightly tilted as if mid-pump, and a small chunky tan cork stopper popping up and away to the upper right with a short white whoosh trail and two or three bold yellow sparkles. Keep everything inside the central 75 percent of the canvas so it survives a rounded-corner mask, with a bold simple silhouette readable at 16x16 pixels. No text, no letters, no logos.
```

## Small-size variant (`-i concept-C-R2.png`, prompt on stdin)

### concept-C-R2-small.png

```
Use your image generation tool to generate exactly one square 1024x1024 image, using the attached image as the style and subject reference. Do not write any code; just call image generation once and then stop. Make a simplified small-size version of this macOS app icon art, meant to be shown at 16x16 and 32x32 pixels. FULL-BLEED: the same vivid electric-blue background fills the entire square canvas edge to edge, with a soft lighter glow behind the subject, no rounded-rectangle frame, no white margin, no border. Keep exactly the same red glossy plunger character with the happy face and wooden handle, same tilt, but make it noticeably bigger so it fills about 70 percent of the canvas height, centered. Remove all the small sparkles and pop lines. Keep the tan cork, but make it larger and bolder, popping out to the upper right with just one simple thick white curved motion arc. Strong contrast, simple bold shapes, crisp edges. Everything stays inside the central 80 percent of the canvas. No text, no letters, no logos.
```

## What ships

- `icon-1024.png`: concept-C-R2, masked. Used for the 64 px slots and up (32@2x, 128, 256, 512 at 1x and 2x).
- `icon-small-1024.png`: concept-C-R2-small, masked. Used for 16, 16@2x and 32 (16 and 32 px files), where the sparkles of the master turn to noise.
