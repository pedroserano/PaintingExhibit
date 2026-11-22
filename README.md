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

On the Mac (and iPad with a keyboard): in the gallery, arrow keys pick a painting and Return or Space opens it;
in the exhibit, arrow keys or the side buttons move between paintings, Space shows or hides the label,
Esc closes the exhibit and returns to that painting in the gallery, pinch or double-click zooms, and ⌘, opens Settings.

## iPhone and iPad: first run (free Apple account)

1. Once, fetch Apple's MobileCLIP model, which the app uses to recognise paintings (it isn't kept in this
   repository, as Apple's licence doesn't allow redistributing it): run `scripts/fetch-model.sh`.
   The Mac build script does this for you.
2. Double-click `PaintingExhibit.swiftpm` to open it in Xcode.
3. In Xcode, select the project at the top of the sidebar, open **Signing & Capabilities**,
   and set **Team** to your name (Personal Team).
   If Xcode says the bundle identifier is taken, change it to something unique.
4. Connect your iPhone or iPad with a cable and choose it at the top of the Xcode window.
5. On the device, turn on **Settings > Privacy & Security > Developer Mode** (it restarts).
6. Press **Run** (⌘R).
7. The first time, the device blocks the app: go to
   **Settings > General > VPN & Device Management**, tap your Apple account, and choose **Trust**.
8. Open the app, allow Photos access, and choose your paintings album.

Every 7 days the app stops opening: connect the device and press Run again.
Your paintings and frame choices are kept.

## What phase 1 does

- Finds the painting's edges and straightens it, restoring its true proportions when it was photographed
  from one side, above or below (from the corners and the lens's focal length). Looks for the canvas inside
  the frame and drops the frame, including in close-ups where the frame runs off the photo's edges.
  First, though, it undoes barrel (fish-eye, wide-angle) lens distortion, found from edges that should be
  straight; iPhone photos usually need none, as the camera removes it.
  **Show frames** in Settings sets the default; **Show frame / Remove frame** on a painting overrides it.
- Samples the wall on all four sides of the frame:
  - its colour isn't used for white balance: the patch of wall beside the crop varies from photo to photo,
    and it made photos of the same painting differ more than the cameras did;
  - the difference between sides evens out spotlight falloff across the canvas.
- Gently sets exposure from the painting's own brightness range.
- Each caption shows the painting's title, artist, date and museum once identified (see below), and what was done.
- Picks up photos added to (or edited in) the album on its own, while open or on returning to the app.
- **Adjust Crop** on any painting shows the photo with the crop's four corners; drag them onto the painting's
  corners (a magnifier shows the spot under your finger) and Save. Your corners are kept when paintings are
  processed again; **Use Automatic Crop** goes back. Each fix is recorded next to what the app had chosen
  (`crop-fixes.jsonl` in the app's Application Support folder), as the answer key for measuring and improving
  the automatic cropping.
- Pinch or double-tap to zoom; swipe to the next painting when not zoomed or at the edge.
- Settings: ⋯ menu › Settings on iPhone and iPad, ⌘, on the Mac.

## Identifying paintings (reverse image search)

Each painting is looked up once with Google Cloud Vision's web detection (a reverse image search), using your
own API key. What Google finds is matched to the work in Wikidata, for its title, artist, date and museum, and
Apple's Vision compares the photo with the work's image on the device to confirm it:

- **Identified:** the work's image matches your photo.
- **Possible match:** worth a look; **To Review** in the gallery shows only these. Open one and press **Details**
  to confirm it, choose another candidate, or type the details yourself.
- **Unidentified:** nothing fits; you can still type the details.

Details you confirm or type are kept: a later search never replaces them. Only the cropped painting goes to
Google, without its location or other photo details; Wikidata and Wikimedia Commons receive only the names and IDs
being looked up.

### Getting a free API key

Google's first 1,000 lookups a month are free, and the app stops at 900. Google still asks for a card to turn
the service on.

1. Sign in at [console.cloud.google.com](https://console.cloud.google.com) and create a project.
2. Turn on billing for the project (Billing), then enable the **Cloud Vision API** (APIs & Services › Library).
3. Create an API key (APIs & Services › Credentials › Create credentials › API key). Restrict it to the Cloud
   Vision API.
4. In the app: Settings › Identify paintings, paste the key and press **Save Key**. It is kept in the Keychain.

To be safe from charges, you can also set a budget alert in Billing, or a daily quota on the Cloud Vision API
(APIs & Services › Cloud Vision API › Quotas).

## Sharing between your devices

In Settings › Share between devices, choose the same folder in iCloud Drive (for example iCloud Drive ›
Painting Exhibit) on the Mac, iPhone and iPad. Your hand crops, white balance, frame choices and
identifications are kept there (`edits.json`, keyed by each photo's iCloud Photos ID, which is the same on every
device), along with the record of crop fixes and the museum data fetched for identifying, so each museum is
fetched once for all your devices. When two devices changed the same painting, the newer change wins, and an
identification confirmed by hand beats an automatic one. A free Apple account can't use an app's own iCloud
storage, so the app uses a folder you choose instead.

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
