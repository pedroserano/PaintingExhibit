# Painting Exhibit

Phase 1 prototype: reads one Photos album, crops each painting, corrects its lighting
using the wall around it, and shows the results as a gallery and full-screen exhibit.
Runs on iPhone, iPad and the Mac, from the same source files.

## Mac

```bash
scripts/make-mac-app.sh
```

This builds `build/Painting Exhibit.app` (macOS 14 or later, Xcode installed). Open it, allow Photos access
and choose your paintings album; copy it to Applications if you like. Unlike the iPhone and iPad app, the
Mac app doesn't expire. It is signed with your free Apple Development certificate when the Mac has one
(set up by signing in to Xcode with your Apple account); otherwise it is signed ad-hoc and the Mac may ask
for Photos access again after each rebuild.

On the Mac: arrow keys or the side buttons move through a gallery, Space shows or hides the label,
Esc closes the exhibit, pinch or double-click zooms, and ⌘, opens Settings.

## iPhone and iPad: first run (free Apple account)

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

- Finds the painting's edges and straightens it, restoring its true proportions when it was photographed
  from one side, above or below (from the corners and the lens's focal length). Looks for the canvas inside
  the frame and drops the frame, including in close-ups where the frame runs off the photo's edges.
  Lens distortion (fish-eye) isn't corrected; iPhone photos have it removed by the camera.
  **Show frames** in Settings sets the default; **Show frame / Remove frame** on a painting overrides it.
- Samples the wall on all four sides of the frame:
  - its colour sets the white balance (skipped when the wall itself is clearly coloured, e.g. a red gallery);
  - the difference between sides evens out spotlight falloff across the canvas.
- Gently sets exposure from the painting's own brightness range.
- Each caption shows what was done (for tuning). Identification comes in phase 2.
- Picks up photos added to (or edited in) the album on its own, while open or on returning to the app.
- Pinch or double-tap to zoom; swipe to the next painting when not zoomed or at the edge.
- Settings: ⋯ menu › Settings on iPhone and iPad, ⌘, on the Mac.

## Non-destructive editing

Photos keeps the only copy of every picture. For each painting the app saves just an edit recipe: the painting and canvas corners, the frame choice,
the wall readings, and the colour, spotlight and exposure values. The exhibit image is drawn from the
original in Photos with that recipe.

Drawn images are kept in the app's cache so swiping is quick. The system may clear the cache when space is
short; they are then redrawn from Photos as you view them. If a photo's original is only in iCloud
(Optimize Storage), redrawing it needs a connection.

### Save edits to Photos (optional, off by default)

With **Save edits to Photos** on, the app also adds each painting's crop and corrections to the photo in
Photos, as a standard photo edit carrying the recipe. Photos keeps the original: **Revert to Original** in
Photos undoes one, and **Remove Edits from Photos** in Settings undoes them all. You're asked to allow each
batch of changes. Revert to Original also removes any edits made in Photos before this app's edit.

The app always works from the image underneath its own edit, so its edits never pile up. If a photo is
edited again elsewhere after the app saved its edit, the app leaves that photo alone from then on.

## Icon

Drawn in code by `scripts/make-icon.swift`; run `swift scripts/make-icon.swift` to redraw it for both apps.

## Licence

MIT. See [LICENSE](LICENSE).
