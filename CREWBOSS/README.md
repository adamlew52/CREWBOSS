# Sensaro iOS App — Setup Guide

## What you received
Four Swift files + this guide. They wrap your existing web pages in a native
iOS shell (WKWebView). Your HTML, CSS, JavaScript, and AWS API calls work
exactly as they do today — nothing in your web project needs to change.

---

## Prerequisites
| Requirement | Where to get it |
|---|---|
| Mac running macOS 13+ | Required — Xcode only runs on Mac |
| Xcode 15+ | Mac App Store (free) |
| Apple Developer account | developer.apple.com (free for testing on your own phone, $99/yr for App Store) |
| Your site hosted on HTTPS | Camera and geolocation **require** HTTPS |

---

## Step 1 — Create the Xcode project

1. Open Xcode → **File → New → Project**
2. Choose **iOS → App** → Next
3. Fill in:
   - **Product Name:** `Sensaro`
   - **Team:** your Apple ID
   - **Organization Identifier:** something like `com.yourname` (doesn't matter for testing)
   - **Interface:** SwiftUI
   - **Language:** Swift
4. Uncheck "Include Tests" (not needed)
5. Save it somewhere on your Mac

---

## Step 2 — Add the Swift files

1. In the Xcode sidebar, right-click the **Sensaro** folder (yellow icon) → **Add Files to "Sensaro"**
2. Add all four `.swift` files:
   - `SensaroApp.swift`  ← replaces the one Xcode auto-created
   - `ContentView.swift` ← replaces the one Xcode auto-created
   - `ForestryWebView.swift`
   - `AppCoordinator.swift`
3. When prompted, make sure **"Add to target: Sensaro"** is checked

> **Note:** Xcode already created `SensaroApp.swift` and `ContentView.swift` for you.
> Either delete those and add mine, or open each and replace the contents by copy-pasting.

---

## Step 3 — Set BASE_URL

Open **ContentView.swift** and change line 8:

```swift
// Before
private let BASE_URL = "https://your-domain.com"

// After (example)
private let BASE_URL = "https://sensaro.yourdomain.com"
```

This is the only code change you need to make.

---

## Step 4 — Add permission strings to Info.plist

iOS will crash without these. Here's how to add them:

1. In Xcode's sidebar, click **Info.plist**
2. Right-click it → **Open As → Source Code**
3. Inside the `<dict>` element (before the closing `</dict>`), paste:

```xml
<key>NSCameraUsageDescription</key>
<string>Sensaro needs camera access to photograph forestry concerns like pine beetle damage or wildfire risk areas.</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>Sensaro needs photo library access to upload existing photos of forestry concerns.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Sensaro uses your location to accurately pin forestry concern reports on the map.</string>
```

The full text of these keys is also in `InfoPlist.additions.xml` for reference.

---

## Step 5 — Run on your iPhone

1. Plug your iPhone into your Mac with a USB cable
2. In the Xcode toolbar (top), click the device selector and choose your phone
3. Press **⌘R** (or the ▶ play button)
4. The first time, your iPhone will show "Untrusted Developer" — go to:
   **Settings → General → VPN & Device Management → [your Apple ID] → Trust**
5. Press ▶ again — the app will launch

---

## What each file does

| File | Purpose |
|---|---|
| `SensaroApp.swift` | The `@main` entry point — required by SwiftUI |
| `ContentView.swift` | Three-tab layout. **Only line you edit is `BASE_URL`.** |
| `ForestryWebView.swift` | Wraps WKWebView; injects the geolocation JS bridge |
| `AppCoordinator.swift` | Handles all native iOS plumbing: camera, photo library, GPS, JS alerts |

---

## How the tricky parts work

### Camera & photo upload
iOS requires native code to handle `<input type="file">` inside a WebView.
`AppCoordinator` intercepts the file-picker request and shows a native
iOS action sheet ("Take Photo" / "Choose from Library"). The selected image
is written to a temp file and handed back to your existing `mpb_script.js`
upload flow, which sends it to your S3 pre-signed URL exactly as before.

### Geolocation
`navigator.geolocation` doesn't automatically work inside WKWebView the same
way it does in Safari. `ForestryWebView` injects a thin JS shim that
intercepts `.getCurrentPosition()` calls and forwards them to Swift via a
message handler. Swift uses `CLLocationManager` to get the real GPS
coordinates, then calls `window.__geo_respond(lat, lng, accuracy)` back into
the page — which your existing "Get Location" button handler receives normally.

### JavaScript alerts
Your `mpb_script.js` debug panel uses `alert()` extensively. `AppCoordinator`
catches all `alert()` and `confirm()` calls and presents them as native iOS
`UIAlertController` dialogs, so they look and behave correctly on iPhone.

---

## Submitting to the App Store (when you're ready)

1. Get a paid Apple Developer account ($99/yr) at developer.apple.com
2. In Xcode: **Product → Archive**
3. In the Organizer window that appears: **Distribute App → App Store Connect**
4. Follow the prompts — Xcode handles signing automatically if you have
   "Automatically manage signing" checked in the project settings

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Blank white screen | Check that `BASE_URL` is correct and the site is live over HTTPS |
| "Camera not available" | Must test on a real device, not the Simulator |
| Location never responds | Make sure you granted permission when prompted; check Settings → Privacy → Location |
| `site-header` component missing | Your `/components/header-component.js` path is absolute — it must be served from your domain, not local files |
| Page looks zoomed in | Already handled — the WebView respects your existing `<meta name="viewport">` tag |
