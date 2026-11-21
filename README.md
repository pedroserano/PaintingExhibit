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
Your processed paintings are kept.

## What phase 1 does

- Finds the painting's edges and straightens it; looks for the canvas inside the frame and drops the frame.
- Samples the wall on all four sides of the frame:
  - its colour sets the white balance (skipped when the wall itself is clearly coloured, e.g. a red gallery);
  - the difference between sides evens out spotlight falloff across the canvas.
- Gently sets exposure from the painting's own brightness range.
- Each caption shows what was done (for tuning). Identification comes in phase 2.

Processed images live in the app's own storage; nothing in Photos is changed.
