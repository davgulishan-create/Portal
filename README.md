# Portal: iPhone ⇄ Mac edge drop

Free and open source (MIT). Drag a photo off the left edge of your iPhone and it flies into your Mac from the right edge, with a rainbow or portal effect. Drag a file into the right edge of your Mac and it lands on your iPhone. No cloud, no account: everything goes over your local Wi-Fi.

Two SwiftUI apps that talk over the local network using Network.framework and Bonjour (`_portal._tcp`).

| | iOS (`PortalPhone`) | macOS (`PortalMac`) |
|---|---|---|
| Role | Bonjour **browser / client** | Bonjour **listener / server** (menu bar, `LSUIElement`) |
| Send | Long-press a photo, drag it past the left 40 pt, let go | Drag a file into the right-edge send zone (or use menu ▸ Send File…) |
| Receive | Images and videos go to Photos, other files go to Files ▸ On My iPhone ▸ Portal | Edge effect plays, image flies in, file saved to `~/Downloads` |

## Now Playing + Dynamic Island (Mac)

**Dynamic Island.** While music plays, a black pill around the MacBook notch shows the cover on one side and moving bars on the other. Hover over it to see the title, progress and controls, or click the cover to go full screen. It also briefly shows files sent to or received from the iPhone. On Macs without a notch, it sits at the top centre of the screen.

**Screensaver.** If music is playing and the Mac has been idle for a while (2 minutes by default), Now Playing starts as a screensaver. You first see a lock-screen look with your wallpaper, a big clock and a small player widget. Touch the trackpad and it turns into the full player with lyrics. Any other key closes it. It stays out of the way while a video, video call or presentation is keeping the display awake. Settings ▸ Now Playing shows exactly what Portal can see in each player, which helps when nothing shows up.

**Any player.** Portal first reads macOS's own *Now Playing*, the one in Control Center, which every player feeds: the Yandex Music, VK, Telegram and YouTube Music apps, browsers, Music, Spotify… Since macOS 15.4 Apple only answers its own processes here, so Portal asks `/usr/bin/osascript` to read it. That's a workaround: it needs the Mac app to run **without App Sandbox**, and a future macOS may close it. If that happens, Portal falls back to the sources below.

**Sources:** Music, Spotify, and browser tabs in Safari, Chrome, Arc, Brave, Edge and Vivaldi (YouTube, YouTube Music, SoundCloud, Spotify Web, Yandex Music, VK, Deezer…). Browsers need **“Allow JavaScript from Apple Events”** switched on once. In Chrome-based browsers it's under *View ▸ Developer*. In Safari it's under *Develop* (turn on *Settings ▸ Advanced ▸ Show features for web developers* first). Firefox isn't scriptable, so it's not supported.

Touch the **left edge** of the screen and a small white tab slides out. Click it, or choose **Now Playing** in the menu, to open a full-screen player for **Music** or **Spotify**:
- an ambient background made from the album cover, heavily blurred and slowly drifting;
- a big clock;
- the cover, progress bar and controls;
- **time-synced lyrics** from [LRCLIB](https://lrclib.net). The current line is bright and the others are dimmed and blurred. Click a line to jump to it.

Esc closes it, Space plays or pauses, and ← / → skip. The first time you open it, macOS asks to let Portal control Music or Spotify (System Settings ▸ Privacy & Security ▸ Automation). Lyrics lookups send only the song title, artist, album and duration to lrclib.net, and you can turn them off in Settings.

## Layout

```
project.yml                 XcodeGen spec (both targets, Info.plist keys, entitlements)
Shared/
  PortalProtocol.swift      wire format: 16-byte header + name + payload; filename sanitising
  PortalConnection.swift    framed NWConnection (chunked receive, main-queue callbacks)
PortalPhone/
  PortalPhoneApp.swift      app, ContentView, Mac picker, pairing-code alert, toasts
  PortalClient.swift        NWBrowser + connect/hello/auto-reconnect + ack tracking
  PhotoLibrary.swift        PhotoKit auth, fetch, original-bytes export (+ fixes extension)
  PhotoGridView.swift       grid, long-press→drag gesture, left-edge glow, haptics
  IncomingSaver.swift       saves files from the Mac to Photos or Documents
PortalMac/
  PortalMacApp.swift        MenuBarExtra + Settings scene + AppDelegate wiring
  PortalServer.swift        NWListener + Bonjour advertising, pairing code, single peer
  EdgePanel.swift           borderless/transparent NSPanel + DropZoneView drag destination
  EdgeController.swift      owns both panels, layout on the right-most display, send/receive
  DragMonitor.swift         system-wide file-drag detection + accelerating trackpad haptics
  OverlayModel.swift        queued effect/fly-in sequencing
  OverlayView.swift         SwiftUI overlay, curved fly-in modifier, zone indicator
  Effects.swift             Rainbow (blurred gradient band) + Portal (Canvas ring + particles)
  SettingsView.swift        Send Zone slider, effect picker, "Show on This Mac", pairing code
  NowPlaying/               left-edge tab, full-screen player, AppleScript bridge, LRCLIB lyrics
```

## How it works

**Discovery and pairing.** The Mac advertises `_portal._tcp` under its computer name. The iPhone browses, you tap the Mac, and the iPhone asks for the **6-digit pairing code** shown in the Mac's menu-bar menu. The code goes in the first `hello` message. If it's wrong, the Mac replies `reject` and closes the connection. The Mac ignores any file from a connection that hasn't said hello correctly. Both sides keep the pairing, and the iPhone reconnects by itself whenever the app becomes active.

**Wire format.** Each message is `"PRTL" | ver | kind | nameLen:u16 | payloadLen:u64 | name | payload`, big-endian. The receiver reads the payload in 1 MiB chunks, and payloads are capped at 1 GiB. Kinds are `hello`, `reject`, `file` and `ack`. The iPhone fires its success haptic only after the Mac acks, meaning the file is already on disk.

**The Mac edge panels.** There are two `EdgePanel`s, both at `.screenSaver` level, borderless, with a clear background, `ignoresMouseEvents = true`, and `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`:
1. **Overlay** (460 pt wide). It's always click-through and draws the effects and the flying image.
2. **Send zone** (as wide as the slider setting). It's click-through *except during a file drag*. `DragMonitor` uses a global `leftMouseDragged` monitor plus the `NSPasteboard(.drag)` change count to notice that a file drag has started anywhere on the system. This needs no Accessibility permission. When a drag starts, the zone panel starts accepting mouse events so it can act as an `NSDraggingDestination`. When the button goes up, it turns click-through again, so scroll bars and window edges stay usable the rest of the time.

**Haptics on the Mac.** During a drag, the cursor is polled at 60 Hz. Inside 320 pt of the edge, `NSHapticFeedbackManager` sends `.alignment` ticks. The gap between ticks shrinks quadratically from about 330 ms to 40 ms. Entering the zone gives one `.levelChange` bump, and inside the zone it ticks every 30 ms.

**Effects.** *Rainbow* is three hue-cycling `LinearGradient` bands, blurred and blended with `.plusLighter`, that breathe in width. *Portal* is a `TimelineView` + `Canvas` drawing: a blurred radial glow, seven conic-gradient arcs counter-rotating, a dark core with a bright rim, and 140 particles spiralling inward. Each particle's position is a pure function of its index and the time, so there's no particle state to update. Both effects pause their timelines when they're invisible. The fly-in uses an `Animatable` modifier, so the spring follows a curved path with a 3D turn instead of a straight line. The file is written to Downloads **after** the image lands, or right away when "Show on This Mac" is off, and the Dock's Downloads stack bounces.

---

## Building, signing and running on real devices

### Requirements
- A Mac with **Xcode 16 or newer** (macOS 14+ to run the Mac app).
- An iPhone on **iOS 17+**, on the **same Wi-Fi network** as the Mac. Guest and corporate networks often block mDNS (Bonjour). A phone hotspot or home Wi-Fi works.
- An Apple ID. A **free** account works for both apps (limits below). A paid Developer Program account ($99/yr) removes the limits.

### 1. Generate the Xcode project
```bash
brew install xcodegen
```
```bash
cd Portal && xcodegen
```
```bash
open Portal.xcodeproj
```
<details><summary>Without XcodeGen</summary>

Create a new multiplatform or two-target project in Xcode: an iOS App target and a macOS App target, both SwiftUI. Add `Shared/` to **both** targets, and each app's folder to its own target. Then add the Info.plist keys and macOS entitlements listed in `project.yml` under each target's *Info* and *Signing & Capabilities* tabs. Set "Application is agent (UIElement)" = YES on the Mac target.
</details>

### 2. Set up signing (once)
1. **Xcode ▸ Settings ▸ Accounts**: click **+** and sign in with your Apple ID. A "Personal Team" appears.
2. In `project.yml`, change `bundleIdPrefix` and the two `PRODUCT_BUNDLE_IDENTIFIER`s from `com.example.portal…` to something unique, like `com.yourname.portal.phone` and `com.yourname.portal.mac`. Then run `xcodegen` again. Bundle IDs are global, and `com.example` is likely taken.
3. For **each target** (PortalPhone and PortalMac), open **Signing & Capabilities**:
   - Check **Automatically manage signing**.
   - Set **Team** to your Personal Team or paid team. Alternatively, put your Team ID in `DEVELOPMENT_TEAM` in `project.yml` so you don't have to set it again after regenerating.
   - Xcode creates the provisioning profile. On the Mac target you should see **App Sandbox** with *Incoming/Outgoing Connections* and *Downloads Folder: Read/Write*, plus **Hardened Runtime**. Those come from the generated entitlements file.

### 3. Run the iPhone app
1. Connect the iPhone by USB (or pair it once for Wi-Fi debugging) and tap **Trust This Computer**.
2. On the iPhone, open **Settings ▸ Privacy & Security ▸ Developer Mode**, turn it on, and reboot. This option only appears after Xcode has seen the device once.
3. In Xcode, choose the **PortalPhone** scheme and your iPhone as the destination, then press **⌘R**.
4. With a free account, the first launch fails with "Untrusted Developer". On the iPhone, go to **Settings ▸ General ▸ VPN & Device Management**, open your Apple ID, tap **Trust**, then run again.
5. Allow the prompts: **Photos** (Full Access or Limited) and **Local Network**. The Local Network prompt is required for Bonjour. If you denied it, re-enable it under Settings ▸ Privacy & Security ▸ Local Network ▸ Portal.

### 4. Run the Mac app
1. Choose the **PortalMac** scheme with destination **My Mac**, then press **⌘R**.
2. No Dock icon appears (`LSUIElement`). Look for the 🌈 icon in the menu bar.
3. On macOS 15+, allow **Local Network** access when asked. It's also under System Settings ▸ Privacy & Security ▸ Local Network. Also allow incoming connections if the macOS firewall asks.
4. Click the menu-bar icon and note the **pairing code**. Click **Preview Effect** to check the overlay, and open **Settings…** to pick Rainbow or Portal and set the send-zone width.

To keep it running without Xcode: choose **Product ▸ Show Build Folder in Finder**, open **Products ▸ Debug**, copy **Portal.app** into **/Applications**, launch it from there, and add it to **System Settings ▸ General ▸ Login Items**. Stop the Xcode-launched copy first (■) so two copies don't run at once. Builds signed with a free team only run on the Mac that built them. To give the app to other Macs, you need a paid account and **Developer ID** signing + notarization.

### 5. Pair and test
1. On the iPhone, tap **Pair Mac** (top right), pick your Mac, and enter the code. The badge turns green.
2. **iPhone → Mac:** long-press a photo until it lifts, drag it to the left edge (the rainbow glow brightens and you feel a tick), and let go. You get a heavy haptic on send and a success haptic once the Mac has saved it. On the Mac, the effect plays, the image flies in, and the file appears in `~/Downloads`.
3. **Mac → iPhone:** drag any file from Finder toward the right edge of the right-most display. The trackpad ticks faster as you get closer, and the send zone lights up. Drop it there. Images and videos land in Photos, other files in Files ▸ On My iPhone ▸ Portal.

### Free-account limits and gotchas
- Apps signed with a **free** account expire after **7 days** on iPhone. Just run from Xcode again. You're also limited to 3 sideloaded apps per device.
- **Haptics on the Mac** need a Force Touch trackpad, and you only feel them while your finger is on it. A mouse gets nothing.
- The **edge** is the right side of the *right-most* display, where the cursor actually stops. With a display arranged to the right of the laptop, the zone is on that display.
- iOS closes the socket when Portal goes to the background. It reconnects when you return to the app, so receiving from the Mac requires the iPhone app to be open.
- "Waiting for iPhone…" that never changes usually means Local Network access was denied on one side, the devices are on different networks or VLANs, or the network blocks multicast.

### Mac → iPhone drag only works for files in Downloads?
The Mac app ships with the **App Sandbox** on. Sometimes macOS doesn't hand the drop to the edge window. Portal then falls back to reading the dragged file itself, and a sandboxed app is only allowed to do that inside `~/Downloads`. So if you drop a file from the Desktop or Documents and nothing happens, you have two options:
- drag files from **Downloads**, or **Send File to iPhone…** from the menu-bar icon (that works for any file), **or**
- remove **App Sandbox** in *PortalMac ▸ Signing & Capabilities* (trash icon). The app can then read any file you drag to the edge. That's less isolation, so decide for yourself.

### Signing troubleshooting
- **"Signing certificate is invalid" / "Missing Private Key" / "Not in Keychain"**, and **+ ▸ Apple Development** answers "You already have a current Development certificate". This means your Apple ID's development certificate was created on another Mac or its private key was lost. A free account can't revoke it.
  - **Mac target:** set **Team** to *None* and **Signing Certificate** to *Sign to Run Locally*. That's enough to run it on your own Mac.
  - **iPhone target:** export the certificate from the Mac that has the key (Xcode ▸ Settings ▸ Apple Accounts ▸ Manage Certificates ▸ right-click ▸ Export). Or sign in to Xcode with a second, free Apple ID and pick its Personal Team. The iPhone doesn't need to be signed into that Apple ID.
- **"Failed Registering Bundle Identifier"**: `com.example…` is taken. Use your own unique ID and make sure there's no trailing dot.
- **"Your team has no devices"**: connect the iPhone by cable, unlock it, tap *Trust*, and select it as the run destination. Then press **Try Again**.
- Don't re-run `xcodegen` after changing signing in Xcode. It regenerates the project from `project.yml` and resets those settings, so put your Team ID and bundle IDs in `project.yml` if you want them to stick.

### Security note
The pairing code stops casual LAN neighbours from writing to your Downloads folder, but the traffic itself is **not encrypted**. For real use, swap `NWParameters(tls: nil, …)` in `PortalConnection.makeParameters()` for TLS with a pre-shared key derived from the pairing code (`sec_protocol_options_add_pre_shared_key`). Then the code never travels in the clear, and transfers are encrypted end to end.
