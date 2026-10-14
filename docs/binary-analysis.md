# Cyberpunk 2077 (GOG Mac build 2.3.1) – iOS feasibility analysis

Source: the user's own GOG copy, `Cyberpunk2077.app` (analysis only, read-only; no files modified).

## Binary facts (measured)
- `Contents/MacOS/Cyberpunk2077`: Mach-O arm64 (not arm64e), MH_EXECUTE, PIE, 151 MB, platform macOS, minos 15.5, sdk 15.2.
- Frameworks: libBink2MacArm64, libGalaxy, libREDGalaxy64, libGameServicesGOG (all platform macOS).
- Game code is a thin Cocoa shell. Only 8 ObjC classes: GameApplicationDelegate, GameWindowController, GameWindow, GameView,
  GameWindowDelegate, ControllerObserver, AkAudioEngineEventListener, MetricKitDelegate.
- Rendering: CAMetalLayer + CAMetalDisplayLink, MetalFX (spatial + temporal), EDR queries, GameController, CoreHaptics, AVAudioEngine (Wwise).

## Linked libraries and what iOS lacks (UNVERIFIED against a real iOS dyld cache – check on device)
| Library | Imported symbols | iOS status |
|---|---|---|
| AppKit | 24: NSApplication, NSWindow, NSView, NSWindowController (game subclasses 3 of them), NSScreen, NSEvent, NSCursor, NSImage, NSMenu, NSTrackingArea, NSWorkspace, NSApp, 8 notification names | missing, needs shim |
| Cocoa | umbrella only (Galaxy libs) | missing, re-export Foundation |
| IOKit | 18 (IOService*/IORegistry*/IODisplay*) – display info, probably GPU/display queries | public API missing, stub |
| CoreAudio | 3 AudioObject*Property* | missing, stub |
| Carbon, AudioUnit | Bink only (links, few/no symbols used) | missing, stub |
| Security | SSL*, Sec* incl. SecItemImport/Export, SecIdentityCreateWithCertificate (macOS-only) | mostly present, 3 macOS-only symbols |
| libcurl.4, libbz2.1.0 | 16 / 3 | libbz2 likely OK, libcurl needs checking |
| Metal, MetalFX, QuartzCore, GameController, CoreHaptics, AVFAudio, AudioToolbox, MetricKit, SystemConfiguration, Foundation, CoreFoundation, CoreGraphics | – | present on iOS |

## Behaviours the shim has to handle
- Startup: `[NSApplication sharedApplication]` -> delegate -> run loop (needs UIApplicationMain bridge).
- Window: `createWindowWithTitle:width:height:windowMode:monitorIndex:`, style masks, fullscreen toggles, cursor lock/hide, tracking areas -> single full-screen UIWindow + CAMetalLayer view.
- Input: keyDown/keyUp/mouse*/scrollWheel, `nextEventMatchingMask`, local event monitor -> GCKeyboard/GCMouse/touch; controllers already via GCController.
- Display: `backingScaleFactor`, `visibleFrame`, `deviceDescription` (NSScreenNumber -> CGDirectDisplayID -> IOKit), EDR max values -> UIScreen / UITraitCollection.
- Paths: `_NSGetExecutablePath` + `realpath` used to find game data (`archive`, `engine`, `r6` sit next to the .app) -> must be redirected to the app container.
- sysctl: reads `hw.memsize, hw.model, hw.ncpu, hw.physicalcpu, hw.tbfrequency, kern.osproductversion, kern.version, machdep.cpu.brand_string` -> some missing/different on iPadOS; need fake values.
- `popen`, `dlopen`, `dlsym`, `mmap/mprotect`, `madvise`: popen will fail in the iOS sandbox.
- The shipped entitlements include `sustained-execution`, `disable-library-validation`, `allow-dyld-environment-variables`.

## Hard constraints (not solved by shimming)
- Memory: Mac minimum is 16 GB RAM. iPadOS jetsam limits need the increased-memory-limit entitlement (paid developer account) or equivalent.
- Data size: ~92 GB (GOG) must live in the app container / Files, not the signed bundle.
- Signing: any modified Mach-O must be re-signed; sideloading rules apply.
- Untested: nothing here has been compiled or run on an iPad. A Mac with Xcode and the iPad are required to build and test.

## Status
- Retarget tool: written and run on the real binary + 4 libraries (all parse afterwards; 661 header bytes changed in the executable, no code bytes).
- Shim: C half compiled to an arm64-iOS object here; ObjC half NOT compiled (no iOS SDK here). Symbol coverage checked: 24/24 AppKit, 37/37 IOKit/CoreAudio/curl, 25/25 macOS-only CoreGraphics, 5/5 macOS-only Security.
- Nothing has been signed, installed or run on an iPad.
