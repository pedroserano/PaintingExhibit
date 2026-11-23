# Painting Exhibit

Reads one Photos album of paintings you photographed in museums, crops each painting, corrects its
lighting, works out which painting it is, and shows them as a gallery and full-screen exhibit.
Runs on iPhone, iPad and the Mac, from the same source files. Free, with no account; Photos keeps your originals.

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

## What it does

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
- **Adjust Crop** in the exhibit shows the photo with the crop's four corners in place of the painting; drag them
  onto the painting's corners (a magnifier shows the spot under your finger). It stays on as you move from
  painting to painting, so you can check every crop in turn, and saves as you go. Your corners are kept when
  paintings are processed again; **Use Automatic Crop** goes back. Each fix is recorded next to what the app had chosen
  (`crop-fixes.jsonl` in the app's Application Support folder), as the answer key for measuring and improving
  the automatic cropping.
- **White Balance** works the same way: warmth and tint sliders, an eyedropper to click something that should
  be white or grey, and **Auto**, which balances the painting from its own near-neutral colours.
- **Details** (⌘I) opens a side panel beside the painting: which painting it is, Apple's Look Up, the other
  photos of the same painting, and fields to type the details. Right-click (or long-press) a painting for
  **Show in Photos**.
- **Photos of the same painting:** when you took several photos of one painting, the gallery and exhibit show
  the best one (the closest, or one you edited or chose), with a badge saying how many there are. The others are
  in its details panel: tap one to show it instead, or choose **Not the Same Painting**. Identifying one photo
  identifies them all. **Show each painting once** in Settings turns this off.
- **Galleries:** the gallery button in the toolbar splits the paintings into a gallery for each visit (photos
  taken the same day without a long gap), museum or artist; **View Gallery** walks through just that one.
- Pinch or double-tap to zoom; swipe to the next painting when not zoomed or at the edge.
- Settings: ⋯ menu › Settings on iPhone and iPad, ⌘, on the Mac.

## Identifying paintings

Each painting is looked up once, free and with no account, in this order until one is certain:

1. **The caption label**: text in the photo, or in a photo of the label taken within two minutes of it, read on
   the device and looked up in Wikidata.
2. **The museum's collection**: the museums within 1.5 km of where the photo was taken are found in Wikidata,
   their paintings' images are fetched once from Wikimedia Commons, and your photo is compared with them on the
   device by Apple's MobileCLIP model.
3. **Famous paintings worldwide**: about 5,000 paintings (those with articles in at least five Wikipedias),
   compared the same way, so a well-known painting is recognised even without a location or away from its
   own museum. Their images are fetched once (about 130 MB; Settings › Identify paintings turns this off).
4. **Google** (optional): a reverse image search with your own Google Cloud Vision key, for what's left.

Museum data is kept in the shared folder when you choose one, so each museum is fetched once for all your devices.

- **Identified:** the work's image matches your photo.
- **Possible match:** worth a look; **To Review** in the gallery shows only these. Open one and show **Details**
  to confirm it, choose another candidate, or type the details yourself.
- **Unidentified:** nothing fits. In **Details**, Apple's **Look Up** often names it: type or paste that name
  into **Find by name**, and the app finds the work and checks its image against your photo.

**Write details to Photos** (Mac only, in Settings, off by default) gives each identified painting's photos a
title, caption (artist, year, museum) and keywords (artist, museum) in Photos, and iCloud Photos carries them to
your other devices. Only paintings you confirmed are written (an automatic match can be wrong); a title or caption
you wrote yourself is never replaced, and your own keywords are kept. (iPhone and iPad apps can't change these.)

Details you confirm or type are kept: a later search never replaces them. Your photos stay on the device for the
free search; Wikidata and Wikimedia Commons receive only the names and IDs being looked up. With Google, only the
cropped painting goes to Google, without its location or other photo details.

### Google (optional): getting a free API key

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
Painting Exhibit) on the Mac, iPhone and iPad. Your hand crops, white balance, frame choices, which photo
of a painting is shown, and identifications are kept there (`edits.json`, keyed by each photo's iCloud Photos ID, which is the same on every
device), along with the record of crop fixes and the museum data fetched for identifying, so each museum is
fetched once for all your devices. When two devices changed the same painting, the newer change wins, and an
identification confirmed by hand beats an automatic one. A free Apple account can't use an app's own iCloud
storage, so the app uses a folder you choose instead. A new device asks for the folder before preparing any
paintings, so it uses what your other devices already did instead of redoing it.

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

## Data and licences

- `scripts/fetch-model.sh` fetches Apple's MobileCLIP model at build time (Apple's research licence, so it
  isn't in this repository).
- `PaintingExhibit.swiftpm/App/Models/famous-paintings.json` is the list of famous paintings, from Wikidata
  (CC0); `python3 scripts/make-famous-list.py` makes it again.

## Icon

Drawn in code by `scripts/make-icon.swift`; run `swift scripts/make-icon.swift` to redraw it for both apps.

## Licence

MIT. See [LICENSE](LICENSE).
