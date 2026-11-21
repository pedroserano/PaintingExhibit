# Painting Exhibit

Phase 1 prototype: reads one Photos album, crops each painting, corrects its lighting
using the wall around it, and shows the results as a gallery and full-screen exhibit.

## First run (free Apple account)

1. Double-click `PaintingExhibit.swiftpm` to open it in Xcode.
2. In Xcode, select the project at the top of the sidebar, open **Signing & Capabilities**,
   and set **Team** to your name (Personal Team).
   If Xcode says the bundle identifier is taken, change it to something unique.
3. Connect your iPhone or iPad with a cable and choose it at the top of the Xcode window.
4. On the device, turn on **Settings > Privacy & Security > Developer Mode** (it restarts).
5. Press **Run** (⌘R).
6. The first time, the device blocks the app: go to
   **Settings > General > VPN & Device Management**, tap your Apple account, and choose **Trust**.
7. Open the app, allow Photos access, and choose your paintings album.

Every 7 days the app stops opening: connect the device and press Run again.
Your paintings and frame choices are kept.

## What phase 1 does

- Finds the painting's edges and straightens it; looks for the canvas inside the frame and drops the frame.
  **Show frames** in the ⋯ menu sets the default; **Show frame / Remove frame** on a painting overrides it.
- Samples the wall on all four sides of the frame:
  - its colour sets the white balance (skipped when the wall itself is clearly coloured, e.g. a red gallery);
  - the difference between sides evens out spotlight falloff across the canvas.
- Gently sets exposure from the painting's own brightness range.
- Each caption shows what was done (for tuning). Identification comes in phase 2.
- Picks up photos added to (or edited in) the album on its own, while open or on returning to the app.
- Pinch or double-tap to zoom; swipe to the next painting when not zoomed or at the edge.

## Non-destructive editing

Photos keeps the only copy of every picture, and nothing in Photos is ever changed.
For each painting the app saves just an edit recipe: the painting and canvas corners, the frame choice,
the wall readings, and the colour, spotlight and exposure values. The exhibit image is drawn from the
original in Photos with that recipe.

Drawn images are kept in the app's cache so swiping is quick. iOS may clear the cache when space is short;
they are then redrawn from Photos as you view them. If a photo's original is only in iCloud
(Optimize iPhone Storage), redrawing it needs a connection.
