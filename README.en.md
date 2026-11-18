[简体中文](README.md) | **English**

# Pivot

**Sidecar that works in portrait, works remotely, and keeps macOS 27's native touch.**

Pivot turns an iPad into a display for your Mac that you control directly with your fingers. It adds the two things Apple's Sidecar can't do, without giving up what Sidecar does best: how touch feels.

> 📚 **This is a technical reference, not a ready-to-use product.**
> Pivot is a personal project, and a lot of it is tuned to the author's own devices: the iPad's resolution and model, the Mac's network setup, the signing and mesh-network configuration. It is not guaranteed to build or run on other hardware, and there are no installers and no support.
> What this repository offers is **proof that these things can be done, and how**:
> - a portrait virtual display;
> - native touch on a virtual display under macOS 27;
> - capturing Sidecar's raw touches;
> - a mesh VPN embedded inside an iPad app;
> - a UDP real-time channel designed for responsiveness.
>
> Start with [How it works](#how-it-works). The key parts of the code are commented (in Chinese).

## Why Pivot

macOS 27 gave Sidecar native touch: scroll, pinch and long-press on the iPad, and macOS treats it as a real touchscreen. It feels great. But Sidecar has two hard limits:

- **Landscape only.** Reading documents, writing code or browsing is far nicer with the iPad upright, and Sidecar won't do it.
- **Nearby only.** The iPad has to be cabled or close to the Mac.

Remote-desktop apps and third-party second-screen tools can do portrait and remote, but they all *translate* fingers into a mouse: tap becomes click, drag becomes drag, and scrolling, momentum and pinch are emulated. It never feels like Sidecar.

**Pivot does all three at once: portrait, remote, and native touch.**

## Highlights

- 📱 **True portrait.** The extra display on the Mac matches the iPad's physical pixels one to one. Rotate the iPad and the Mac display rotates with it, without scattering your windows.
- ✋ **Native macOS 27 touch.** Finger events go straight into macOS's own touchscreen path. Scroll momentum, pinch-to-zoom and long-press menus are all system behavior, the same as Sidecar.
- 🌏 **Reach your Mac from anywhere.** Wired › LAN › remote, picked automatically, switching paths without dropping the picture. The mesh network is built into the iPad app, so there's no separate VPN to install.
- ⚡ **Built for responsiveness.** Video and touch travel over an encrypted UDP real-time channel:
  - forward error correction;
  - lost frames are skipped, never retransmitted;
  - touch packets are sent redundantly.

  When bandwidth gets tight, Pivot keeps the frame rate and lowers the resolution, and the iPad scales the picture back up with Apple's low-latency super-resolution.
- ✏️ **Apple Pencil.** Pressure, tilt, hover to move the pointer, palm rejection while drawing.
- ⌨️ **Feels local.**
  - A hardware keyboard and trackpad work on the Mac directly.
  - Tapping a text field pops up the iPad's on-screen keyboard.
  - Mac audio plays on the iPad, with a one-tap switch.
  - The clipboard syncs both ways.
  - Each iPad's place in the display arrangement is remembered.
- 🖥 **Three modes.**
  - **Extend:** an extra display.
  - **Mirror:** the iPad shows the Mac's main display.
  - **iPad only:** every window moves to the iPad, handy when you're working remotely.

> ⚠️ **Limitations first.** Pivot requires **macOS 27.3 or later**. Native touch relies on a DriverKit driver and restricted entitlements. Without a paid developer account, it only works on a Mac with **SIP and AMFI disabled**. With a $99 paid account you can request the entitlements instead and keep both enabled. See [Requirements and limitations](#requirements-and-limitations).

---

## How it works

### 1. Portrait: skip Sidecar's display path and build our own display

Sidecar's display orientation is fixed. We tried forcing a rotation with the private SkyLight call `SLSSetDisplayRotation`. The window server accepted it, but Sidecar maps touches without accounting for rotation, so touches landed in the wrong place at both 90° and 270°, and the Sidecar view on the iPad shrank the landscape picture into the middle. So Pivot goes around Sidecar's display path entirely:

- **A virtual display.** CoreGraphics' private `CGVirtualDisplay` class creates a display the system fully recognizes, at the iPad's physical resolution.
- **Separate landscape and portrait mode tables.** If landscape and portrait modes share one table, the system marks some of them unselectable, so they're split. When the iPad rotates, Pivot swaps the whole table on the same display, with the target mode first. Usually the system lands on it directly: about 0.2 s, and windows stay put. If not, Pivot switches modes explicitly. If the new table never installs, Pivot recreates the display with the same identity, and the system puts the windows back. Each step is judged by whether the current mode actually matches the target.
- **Streaming.** ScreenCaptureKit captures that display. VideoToolbox encodes it as low-latency hardware HEVC with no frame buffering. The iPad decodes in hardware and shows each frame as soon as it arrives. If the iPad falls behind, only the newest frame is kept, so latency never piles up.

There's also a **"Sidecar portrait"** mode for people who want to keep Sidecar's own connection:

1. Connect the iPad with Sidecar as a landscape display, with rotation lock on.
2. Pivot creates a portrait virtual display, rotates its image 90° and lays it full-screen over the Sidecar display.
3. The portrait display sits next to the main display, and the Sidecar display is moved out of the way. Only a short seam remains, where the cursor is blocked.
4. Windows that land on the Sidecar display are moved off automatically.

### 2. Native touch: make macOS treat the virtual display as a touchscreen

macOS 27's native touch only works with a touchscreen that is bound to a specific display. Pivot builds one for its virtual display:

1. **A virtual touchscreen.** The Mac app registers a 10-point HID touchscreen with `IOHIDUserDevice`, and puts the display ID and display UUID in the device properties. Public APIs return nothing for a virtual display's UUID, so Pivot gets it from the private `CGSCopyDisplayUUID`.
2. **A DriverKit driver binds it to the display.** Pivot ships a DriverKit driver (`Driver/`) that matches the virtual touchscreen and writes the display UUID as `displayUUID` (lowercase *d*) onto **the driver's own touch service**. It then turns the HID reports into digitizer touch events. If the UUID is written only on the virtual device, WindowServer discards it as an unsupported service. This detail is what makes it work. The approach comes from [WiredPad](https://github.com/takpika/WiredPad) (MIT).
3. **Fingers from the iPad** travel over the network and are written into the touchscreen's reports as normalized coordinates. From there macOS decides everything — how to scroll, how to zoom, when to show a menu — which is why it feels exactly like Sidecar.

When the driver isn't active, Pivot falls back to a **synthetic gesture** backend: it recognizes gestures itself and posts mouse, scroll, zoom and rotate events. It works, but it doesn't feel quite native. Pencil, hover and the hardware trackpad always use the synthetic backend, since they need pressure, tilt and pointer semantics.

### 3. Getting raw touches in Sidecar portrait mode

In Sidecar portrait mode, fingers land on the Sidecar display, but Pivot needs them rotated 90°. On macOS 27, Sidecar touches **don't pass through any event monitor**: neither `CGEventTap` nor global `NSEvent` monitors see them. They are delivered only to gesture recognizers on the window under the finger (Apple TN3212).

The window under the finger is Pivot's own overlay, so Pivot attaches an `NSGestureRecognizer` to it (`SidecarTouchRecognizer`, direct touches only). With the raw touches it:

1. rotates the coordinates by 90°;
2. feeds them into the virtual touchscreen bound to the portrait display — the native path from section 2;
3. hands them to the synthetic backend instead if the driver isn't active.

`NSIsTouchNative` in `Info.plist` stops the system from also turning these touches into mouse events.

### 4. Remote: a mesh network inside one app

- **Mesh network.** The iPad app embeds [EasyTier](https://easytier.cn) (the `easytier-ffi` static library). It runs without a network interface, inside Pivot's own process, so it needs no NetworkExtension entitlement and works with a free developer account. On a cable connection, the Mac hands the mesh settings to the iPad, over USB only. From then on the iPad forwards local port 47110, TCP and UDP, to the Mac's virtual IP. Peers connect directly when hole punching succeeds and through a relay when it doesn't, with routes chosen by latency.
- **Security.**
  - The pairing key is generated on the iPad and handed to the Mac only during a cabled handshake, so only a device that has been paired by cable can connect wirelessly.
  - The control channel uses TLS with a pre-shared key and mutual authentication.
  - The real-time channel uses ChaCha20-Poly1305 with keys derived from the pairing key via HKDF, a random salt per session, and a replay window.
- **UDP real-time channel** (the key to responsiveness):
  - **Shards and parity.** Video is cut into 1100-byte shards with interleaved XOR parity. The parity ratio adapts between 10% and 40% based on the loss rate the iPad reports.
  - **No waiting on lost frames.** A frame that can't be recovered is skipped and the iPad waits for the next keyframe, so one lost packet never stalls everything behind it. Keyframes carry their own parameter sets.
  - **Paced sending.** The Mac sends with a token bucket instead of dumping a whole frame into the Wi-Fi queue at once.
  - **Touch first.** Each touch packet carries the previous two, finger-down and finger-up events are sent two extra times, and packets are marked with video service class.
  - **Fallback.** If UDP is silent for 3 seconds, the stream falls back to the TLS connection without a break.
- **Smoothness first.**
  - Over wireless the frame rate stays high (up to 60 fps remotely). Under pressure the encoding resolution drops and the iPad stretches it to fill the screen; the frame rate only drops at very low bitrates.
  - On iPadOS 26, `VTLowLatencySuperResolutionScaler` upscales small frames in real time, about 2 ms per frame. When it can't keep up, that frame is shown unscaled rather than queued.
  - While a finger drags, Pivot can optionally send the system's predicted touch position, about one frame ahead.

### 5. Everything else

- **Wired.** Connects straight to a port on the iPad through the system's usbmuxd, never touching the network. About 10 ms latency.
- **Audio.** A separate ScreenCaptureKit stream captures system audio only, encoded as Opus (48 kHz stereo, 10 ms packets, about 96 kbps). Remotely it travels over UDP alongside the video. The iPad buffers only 20–120 ms, preferring a brief dropout to audio that drifts later and later.
- **Clipboard.** Copy on the Mac and it's ready to paste on the iPad. The iPad doesn't read its clipboard in the background, to avoid iOS's repeated "Allow Paste" prompt. When you press ⌘V in Pivot, it sends anything newly copied on the iPad to the Mac first, then sends the keystroke.
- **Auto keyboard.** The Mac uses the Accessibility API to check whether the focused element accepts text. The iPad's keyboard pops up only right after you tap the screen, and never when a hardware keyboard is attached.
- **Display placement.** The system doesn't reliably remember where a virtual display sits in the arrangement. Pivot records which side of the main display each iPad was on and where along that edge, and restores it after reconnecting or rotating.

---

## Requirements and limitations

### Hard requirements

| Item | Requirement |
|---|---|
| macOS | **macOS 27.3 or later.** The native touchscreen path is new in macOS 27, and Pivot relies on behavior in 27.3 |
| Mac hardware | Apple silicon (developed and tested on an M5 Pro MacBook Pro) |
| iPadOS | iPadOS 17 or later; super-resolution needs iPadOS 26 on a supported device |
| Native touch | Pivot's DriverKit driver must be active. Either **disable SIP and AMFI and self-sign**, or **get Apple-approved entitlements with a paid developer account** |
| Remote | EasyTier installed and running on the Mac (with a manually assigned virtual IP). Nothing extra on the iPad |

### Things to know

- **Disabling SIP and AMFI has a cost.** It significantly weakens the security of the whole Mac and can break iPad apps on the Mac, Apple Pay and DRM content, or set off security software. Only do it on your own machine.
- **It still works without native touch.** Without the driver, Pivot falls back to synthetic gestures. Usable, but not identical to the native feel.
- **Private APIs.** `CGVirtualDisplay`, `CGSCopyDisplayUUID` and others mean it can't ship on the App Store and may need changes after OS updates.
- **iPad app expiry.** An iPad app signed by a free developer team expires after 7 days and has to be reinstalled over a cable. A paid account extends this to 1 year.
- **Backgrounding disconnects.** iPadOS freezes networking for background apps, so Pivot disconnects when it leaves the foreground.
- **Remote quality depends on the path.** Direct connections are fast. Relayed connections are limited by the relay server's bandwidth, and quality drops noticeably. A proxy app running in TUN mode on the Mac breaks hole punching; see the patch below.
- **Conflicts with Universal Control.** With an iPad on the same Apple ID nearby, pushing the cursor past a screen edge may hand the keyboard and mouse to Universal Control. Consider turning off *System Settings › Displays › Advanced › Push through the edge of a display to connect a nearby Mac or iPad*.
- **The Mac's speakers still play.** Streaming audio to the iPad doesn't mute the Mac.

---

## Enabling native touch

Native touch needs two sets of restricted entitlements:

- **Mac app:** `com.apple.developer.hid.virtual.device`, to create the virtual HID touchscreen.
- **DriverKit driver:** `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.hid` and `com.apple.developer.driverkit.family.hid.eventservice`.

The system only honors these when Apple issues them, which leaves two options.

### Option A: no paid account → disable SIP and AMFI, self-sign

1. Boot into Recovery and run `csrutil disable` in Terminal, then restart.
2. Disable AMFI, then restart:
   ```bash
   sudo nvram boot-args="amfi_get_out_of_my_way=1"
   ```
3. Turn on system extension developer mode:
   ```bash
   systemextensionsctl developer on
   ```
4. Build the Mac app with the driver:
   ```bash
   PIVOT_NATIVE_TOUCH=1 scripts/build.sh mac
   ```
5. Move `Pivot.app` to Applications and launch it. Approve Pivot's driver in *System Settings › General › Login Items & Extensions › Driver Extensions*.
6. When the Mac menu bar shows the touch backend as "原生触摸屏" (native touchscreen), it's working.

To restore security: run `sudo nvram -d boot-args`, restart, then run `csrutil enable` in Recovery. Afterwards, switch back to a build without `PIVOT_NATIVE_TOUCH`. A build signed with restricted entitlements will be refused at launch. Touch then falls back to synthetic gestures.

### Option B: $99 paid developer account → request entitlements, keep SIP and AMFI on

1. **Use your own identifiers.** Replace `bundleIdPrefix` and `DEVELOPMENT_TEAM` in `project.yml` with your own. There are three bundle IDs:
   - Mac app: `<prefix>.pivot.host`
   - driver: `<prefix>.pivot.host.touchdriver`
   - iPad app: `<prefix>.pivot`

   Also update the driver identifier in `Sources/Mac/Input/TouchDriverExtension.swift` and `scripts/build.sh`.
2. **Register App IDs.** In the developer portal, create one App ID for the Mac app and one for the driver. Enable the System Extension capability (`com.apple.developer.system-extension.install`) on the Mac app; paid accounts can enable it directly.
3. **Request the restricted entitlements** on Apple's [System Extension and DriverKit request page](https://developer.apple.com/contact/request/system-extension/). Explain the use case: a virtual touchscreen that delivers the iPad's touches to a virtual display. Request both the Mac app and the driver entitlements listed above.
4. **Create provisioning profiles** with those entitlements for both the Mac app and the driver once they're approved.
   - For your own use: a Development profile that includes your Mac.
   - For distribution: a Developer ID profile, plus notarization.
5. **Change how it's signed.** `scripts/build.sh` is written for Option A and force-adds the entitlements with a development certificate. For Option B, sign with the profiles from the previous step: either select them for the Pivot and PivotTouchDriver targets in Xcode, or embed them when running `codesign`.
6. **Install.** Move `Pivot.app` to Applications, launch it and approve the driver under *Driver Extensions*. There's no need to disable SIP or AMFI, or to run `systemextensionsctl developer on`.

A few caveats:

- **Approval is neither guaranteed nor time-bound.** HID Virtual Device is reviewed manually by Apple. Some developers on the forums have waited more than two months without approval.
- **Option B hasn't been tested.** Pivot was built and verified with Option A. The Option B steps follow Apple's rules for restricted entitlements and system extensions and should work in principle, but expect to sort out provisioning and signing details yourself. A PR is welcome if you get it working.
- **A paid account helps the iPad side too.** The app stays valid for a year instead of 7 days. The mesh network needs no NetworkExtension entitlement, so it works with either account type.

---

## Building

> This is the author's own build process, shared for reference. Building on your devices will most likely require changing the hard-coded parts first: signing, bundle IDs, network configuration.

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The iPad app also needs the embedded EasyTier built once. That takes rustup and `brew install protobuf`. The source goes in `~/data/src/EasyTier` by default; set `EASYTIER_SRC` to use another location.

```bash
scripts/build-easytier.sh
```

Fill in your own `DEVELOPMENT_TEAM` and `bundleIdPrefix` in `project.yml`, then:

```bash
xcodegen generate                           # generate the Xcode project; rerun after adding or removing files
scripts/build.sh mac                        # Mac app (synthetic gestures) → build/Build/Products/Debug/Pivot.app
PIVOT_NATIVE_TOUCH=1 scripts/build.sh mac   # Mac app with the native touch driver (Option A)
scripts/build.sh pad                        # iPad app
scripts/run-pad.sh <iPad device ID>         # install on the iPad and launch (cable required)
```

On first launch, grant the Mac app these permissions in *System Settings › Privacy & Security*:

- **Screen Recording:** to capture video and audio. Reopen Pivot after granting it.
- **Accessibility:** to inject input and detect text fields.
- **Local Network:** for wireless connections. The iPad app asks once too.

## Code map

| Topic | Where |
|---|---|
| Virtual display, rotation | `Sources/Mac/VirtualDisplay.swift` |
| Native touch: virtual HID touchscreen | `Sources/Mac/Input/HIDTouchscreenInjector.swift` |
| Native touch: DriverKit driver (writes `displayUUID`) | `Driver/PivotTouchDriver.cpp` |
| Driver activation and signing | `Sources/Mac/Input/TouchDriverExtension.swift`, `scripts/build.sh` |
| Sidecar portrait, capturing Sidecar touches | `Sources/Mac/SidecarPortrait.swift`, `Sources/Mac/Input/SidecarTouchRecognizer.swift` |
| Synthetic gesture backend | `Sources/Mac/Input/SyntheticInjector.swift` |
| Capture, encoding, adaptive bitrate | `Sources/Mac/StreamSession.swift`, `Sources/Mac/VideoEncoder.swift` |
| UDP real-time channel (crypto, sharding, FEC) | `Sources/Shared/Realtime.swift`, `Sources/Mac/RealtimeHost.swift`, `Sources/Pad/RealtimeClient.swift` |
| Embedded EasyTier mesh | `Sources/Pad/MeshLink.swift`, `scripts/build-easytier.sh` |
| iPad decoding, super-resolution | `Sources/Pad/VideoRenderer.swift` |
| Audio, clipboard | `Sources/Mac/AudioStreamer.swift`, `Sources/Pad/AudioPlayer.swift`, `Sources/Mac/ClipboardSync.swift`, `Sources/Pad/PadClipboard.swift` |
| Wire protocol | `Sources/Shared/Wire.swift` |

## Measurements

iPad mini (2316×1512, 60 Hz) + M5 Pro MacBook Pro:

| | Wired | LAN wireless |
|---|---|---|
| Frame rate | 57–58 fps, no dropped frames | 54–61 fps |
| Latency (capture → shown on iPad and acknowledged) | about 10 ms | 20–45 ms |

## Self-tests and diagnostics

```bash
swiftc -O -o build/rt-selftest Sources/Shared/Wire.swift Sources/Shared/Realtime.swift scripts/rt-selftest/main.swift && ./build/rt-selftest
                                               # UDP channel: crypto, sharding, FEC, lossy loopback
build/Build/Products/Debug/Pivot.app/Contents/MacOS/Pivot --gesture-selftest   # dry-run gestures and keyboard
scripts/wireless-selftest.sh                   # local loopback test of discovery, encryption, authentication
open --env PIVOT_SELFTEST=stats /Applications/Pivot.app       # print fps, bitrate, latency, touch jitter every second
open --env PIVOT_TRANSPORT=remote /Applications/Pivot.app     # accept only EasyTier connections, to simulate remote use
open --env PIVOT_RT=off /Applications/Pivot.app               # disable the UDP real-time channel
python3 scripts/muxprobe.py                    # probe Pivot's port on the iPad over USB
```

The Mac app logs to stderr. Launch it with `open --stderr <file> /Applications/Pivot.app` to capture the log in a file.

**Proxy TUN patch.** When a proxy app on the Mac runs in TUN mode, EasyTier's hole-punching packets get routed into the proxy, the NAT is misdetected as symmetric, and everything goes through the relay. `scripts/easytier-bind-if.patch` binds those sockets to the physical network interface. Build with `scripts/build-easytier.sh mac` and install with `sudo scripts/patch-mac-easytier.sh` (`restore` undoes it).

## Roadmap

- Use reference frame invalidation or intra refresh instead of full keyframes after packet loss, for smoother playback on poor networks.
- Keep the Mac awake during remote sessions; unlock and wake it from the iPad.
- Optionally mute the Mac while streaming.
- Store pairing keys in the Keychain.
- Get Option B (paid account, proper signing) working and built into the scripts.

This is a personal project; plans move with the author's own needs and may never be finished.

## Acknowledgements

- [WiredPad](https://github.com/takpika/WiredPad) (MIT): the key technique for binding a virtual touchscreen to a display. The driver's finger-touch code is ported from it.
- [EasyTier](https://github.com/EasyTier/EasyTier): the embedded mesh network.
- Apple TN3212: how Sidecar touches are delivered on macOS.
