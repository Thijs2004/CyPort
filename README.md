<p align="center"><img src="app/icons/AppIcon1024.png" width="160" alt="CyPort icon"></p>

<h1 align="center">CyPort</h1>
<p align="center"><b>Run your own copy of Cyberpunk 2077 for Mac natively on iPhone and iPad.</b><br>
No emulation, no streaming: the Apple Silicon Mac build runs directly on iOS / iPadOS.</p>

> **CyPort contains no game files.** You need your own legally bought copy of *Cyberpunk 2077* for Mac (GOG, version 2.3.1).
> The app is built on your Mac from that copy. CyPort is an independent fan project and is **not affiliated with or endorsed by
> CD PROJEKT RED**. *Cyberpunk 2077* is a trademark of CD PROJEKT S.A.

---

## Status

| | |
|---|---|
| Boots, main menu, user agreement, settings | ✅ works |
| Gameplay (loading saves, driving, combat) | ✅ works |
| On-screen controls (virtual gamepad + touch-as-mouse in menus) | ✅ works |
| Bluetooth / MFi controllers (Xbox, DualSense, DualShock 4) | ✅ works, on-screen pad hides automatically |
| Resolution picker up to native (2868 × 1320 on iPhone 16 Pro Max) | ✅ works |
| Performance | ⚠️ ~30–60 FPS at 1434 × 660 with low settings on an iPhone 16 Pro Max; CPU-bound, the phone gets hot and throttles in long sessions |
| Online features (GOG Galaxy, CDPR account, crash upload) | ❌ offline only (stubbed) |

Tested on: **iPhone 16 Pro Max (A18 Pro, 8 GB), iOS 27.0.1**, built with Xcode 27.

---

## Requirements

### Device
| | Minimum | Notes |
|---|---|---|
| **OS** | **iOS / iPadOS 18.0** or later | |
| **Chip** | **Apple A17 Pro / A18 / A18 Pro** or newer, or **M1** or newer (iPad) | Needs the newer Apple GPU families the Mac build targets |
| **RAM** | **8 GB** | The game uses ~5–5.5 GB in gameplay. 6 GB devices will be killed by iOS (out of memory). |
| **Free storage** | **~66 GB** | The game data (~61–65 GB) is copied into the app |
| **Port (optional)** | USB-C | Only to import the game from an external SSD (fast with USB 3: iPhone 15 Pro and newer, iPad Pro/Air) |

**Should work** (8 GB RAM, recent GPU): iPhone 15 Pro / Pro Max, iPhone 16 / 16 Plus / 16e / 16 Pro / 16 Pro Max, iPhone 17 series,
iPad Pro (M1 or newer), iPad Air (M1 or newer), iPad mini (A17 Pro).
**Tested:** iPhone 16 Pro Max only. iPad is supported by the app (landscape, iPad icon sizes, touch + controller) but **untested** –
M-series iPads have more RAM and better cooling and should run it as well or better.

**Won't work:** devices with 6 GB RAM or less (e.g. iPhone 15 / 15 Plus, iPhone 14 and older), iOS 17 or older.

### To build it
- A **Mac** with **Xcode 16 or newer** (Xcode 27 tested) and Python 3.
- **Cyberpunk 2077 for Mac from GOG, version 2.3.1**, downloaded on that Mac (the `Cyberpunk 2077` folder with `Cyberpunk2077.app`, `archive`, `engine`, `r6`).
  - Steam / Epic / Mac App Store copies: **untested**. The game data is probably the same for the same version, but CyPort's patches
    target the GOG 2.3.1 executable, the Steam/Epic builds use their own account systems, and the App Store binary is encrypted.
    A newer game version will need updated patches.
- A **paid Apple Developer account** ($99/year). The game needs two capabilities that free accounts cannot get:
  `com.apple.developer.kernel.extended-virtual-addressing` (the engine reserves ~100 GB of address space) and
  `com.apple.developer.kernel.increased-memory-limit`.

---

## Install

1. **Developer portal** (developer.apple.com → Certificates, Identifiers & Profiles):
   create an App ID (e.g. `com.yourname.cyport`) with the capabilities **Extended Virtual Address Space** and
   **Increased Memory Limit**, register your device, and download a *development* provisioning profile for it.
2. **Build** on the Mac:
   ```bash
   git clone https://github.com/Thijs2004/CyPort && cd CyPort
   REBUILD_SHIM=1 \
   GAME_APP="/path/to/Cyberpunk 2077/Cyberpunk2077.app" \
   BUNDLE_ID=com.yourname.cyport \
   PROFILE=~/Downloads/CyPort.mobileprovision \
   SIGN_ID="Apple Development: Your Name (TEAMID)" \
   DEVICE=<udid from: xcrun devicectl list devices> \
   ./build.sh
   ```
   This writes `build/CyPort.ipa` and installs it on the connected device (`DEVICE=`).
   Without `SIGN_ID` you get `build/CyPort-unsigned.ipa`; sign it yourself – the signature **must** include the two entitlements above.
   Or double-click **`Build CyPort.command`** and drag your `Cyberpunk2077.app` into the window (then sign the IPA yourself).
3. **Import the game data** on the device: open CyPort → **Import game…** → pick your `Cyberpunk 2077` folder
   (e.g. on a USB-C SSD, or in iCloud/Files). It is copied into the app (~65 GB, a few minutes over USB 3; the import can be resumed).
   Alternatively copy the folder with the Files app to *On My iPhone → CyPort → Cyberpunk 2077*.
4. Open CyPort, pick a resolution, press **PLAY**.

---

## Using it

### Start screen
- **Resolution** – the size the game renders and outputs at: 717 × 330 … 2868 × 1320 (native) on an iPhone 16 Pro Max.
  1434 × 660 is a good start. All other graphics options are set in the game's own **Settings** menu and are kept between launches.
- **Performance overlay** – Off / FPS / Detailed (FPS, frame time, CPU, RAM; *Detailed* also turns on Apple's Metal HUD).
  The system Metal HUD (Settings → Developer → Graphics HUD) is independent of this.
- When you change a setting in-game that needs a restart, CyPort offers to quit; just open it again.
- First launch uses the lowest graphics settings.

### Controls
- **On-screen gamepad** (Xbox layout): left stick (fixed, or touch anywhere on the left half), **swipe on the right half to look**,
  A / B / X / Y, LB / LT / RB / RT, L3 / R3, d-pad, View / Menu, plus Esc / Space / Enter keys. 🎮 hides/shows the pad.
- **Menus:** tap = mouse click, drag = scroll, hold then drag = mouse drag (sliders), two-finger tap = right click.
- **Controllers:** connect an Xbox / DualSense / DualShock 4 / MFi controller – the on-screen pad steps aside.
- **Keyboard / mouse / trackpad** (iPad, or iPhone with a USB-C/Bluetooth keyboard): work as on a Mac.
- Game Mode turns on automatically (lower controller latency, priority CPU/GPU).
- Going to the Home Screen freezes the game (no sound, no CPU use); opening the app again continues, if iOS kept it in memory.

### Options – `Documents/Cyberpunk 2077/macshim.plist`
| Key | Effect |
|---|---|
| `LookSpeed` (number, default 1) | camera speed for swipe-look |
| `LookMode` = `mouse` | swipe-look as mouse motion instead of right stick |
| `TouchControls` = NO / `VirtualController` = NO | no on-screen controls / keyboard-only pad |
| `ShowStatus` = NO | no loading / FPS overlay at all |
| `YieldBackoff` = NO, `BackgroundFreeze` = NO, `RestartPopup` = NO | turn individual fixes off |
| `ResMode` (0–7), `AutoPlay`, `AutoKeys` | testing aids |

Logs: *Files → On My iPhone → CyPort → `macshim.log`* (and `game_output.log`, the engine's own output).

---

## How it works

The Mac build is a normal arm64 Mach-O for Apple Silicon. iOS runs the same CPU instructions and has Metal, so the game code can
run unmodified – what's missing is macOS itself. CyPort fills that gap:

**1. Retargeting (`tools/ios_retarget.py`).** The executable and its libraries are rewritten from *platform macOS* to *platform iOS*
(build-version load commands), macOS-only frameworks (AppKit, IOKit, Carbon, CoreAudio HAL, …) are redirected to the shim, and a few
imports are rerouted to it (`mmap`, `read`, `open`, `sysctl`, `dlopen`, `sched_yield`, …). A handful of byte patches, each checked
against the expected instructions first:
- *pool end / pool sizes* – the engine reserves 16 + 64 + 32 GB memory pools; iOS gives an app ~64 GB of address space, so pools are
  shrunk to 8 GB and the engine is told the real end.
- *watchdog* – the engine's hang watchdog fired during slow loads.
- *free hook* – optional allocator quarantine used while hunting a memory corruption.

**2. The shim (`shim/MacShim.m`, `shim/MacShimC.c`, `libMacShim.dylib`).** A from-scratch implementation of the parts of macOS the game
uses: `NSApplication` / `NSWindow` / `NSView` / `NSEvent` / `NSScreen` / `NSCursor` on top of UIKit, CoreGraphics display modes,
IOKit / CoreAudio stubs, macOS-only Metal selectors added at runtime, an offline libcurl. Some highlights:
- **UIKit first:** iOS kills apps that don't finish launching in 20 s, but the game loads everything before its run loop starts.
  The shim boots UIKit (start screen) first, then enters the game's `main()` from a run-loop timer on a 64 MB stack.
- **`finishLaunching`:** the game calls `[NSApp finishLaunching]` and expects AppKit to call its delegate – that is where it
  registers for controllers and mice. (Missing this was why no controller worked at first.)
- **Input:** touches become `NSEvent` mouse events (the game ignores the mouse until it has "seen" one, so the shim opens that gate);
  a virtual `GCController` drives the game's gamepad callbacks; all pending input is delivered every frame.
- **Display:** the engine outputs at the size of the screen it is told about, so `NSScreen`/display modes report exactly the
  resolution picked on the start screen.
- **Online services:** the GOG Galaxy sign-in reports success offline; the curl stub completes every request with "couldn't connect"
  (an early stub left requests hanging, which corrupted memory and crashed the game after the main menu).
- **Files:** case-insensitive path lookup (the Mac build assumes a case-insensitive disk), robust reads, resumable import.
- **Performance:** Game Mode, thread priorities, spin-wait back-off for the engine's job workers, background freeze.
- **Settings:** only the resolution is written to the game's `UserSettings.json` (as a text edit, so the file stays in the game's own format).

**3. The app.** A SwiftUI start screen (`shim/Launcher.swift`), an original icon, and an `Info.plist` with Game Mode, controller and
file-sharing keys. The game data stays outside the app bundle (Documents), so updating CyPort doesn't touch it.

`docs/binary-analysis.md` has the original analysis of the binary.

**How it was made:** CyPort was developed by reverse engineering the GOG Mac build on an iPhone – disassembling with `llvm-objdump`,
attaching LLDB to the running game on the device, and logging from the shim – together with **Claude Code** (Anthropic's AI coding
agent), which did most of the analysis, debugging and implementation in long interactive sessions.

---

## Troubleshooting
- **Crashes right at launch / before the start screen:** the profile lacks *Extended Virtual Address Space* – check the entitlements
  of the installed app (`codesign -d --entitlements - CyPort.app`).
- **Killed after a while (no crash log):** out of memory – close other apps, lower the resolution/textures, 8 GB devices only.
- **"Corrupt settings" message:** can appear once after updating from an old CyPort build (they rewrote the settings file in a format
  the game rejects). Set your settings again; from then on they are kept.
- **Low FPS after some minutes:** the phone is throttling (log line `thermal HOT`). Cap FPS at 40 in-game (even frame pacing on 120 Hz)
  and remove the case / use a cooler.
- Look in `macshim.log` first – every fix logs what it does.

## License
The CyPort code is **MIT** licensed (see `LICENSE`). It does not include and does not grant any rights to *Cyberpunk 2077* or any
CD PROJEKT RED content.
