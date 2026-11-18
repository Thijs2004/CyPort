# Mod support for CyPort: integration and distribution plan

Audience: the CyPort maintainer. This describes the work on the branch `mod-support` (one commit on top of
`main`), how it could be merged in small steps, and how it can be shipped so that **no one's personal signing
certificate is involved**. Sections 1 and 2 describe what exists and runs today; section 3 is a design that is
**not implemented yet**; section 4 is the proposed PR series.

Everything was developed and tested with one game build and one device:

- Cyberpunk 2077 **2.5.0, Steam Mac**, executable UUID `7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC`
  (md5 `4a4f6d008f35d8944914dfc506d37aa3`), single-game build (`GAME_APP=`, not `GAME_APPS=`).
- iPhone 17 Pro, paid developer account (both memory entitlements), `MetalWorkingSetGB=5`.

On that setup the following run in game: RED4ext, TweakXL, ArchiveXL 1.28.8 with its Bundle, Codeware, Cyber Engine
Tweaks with the ImGui overlay, Mod Settings, Input Loader, RedFileSystem, RedData, RedHttpClient, Audioware, script
compilation on the phone (about 0.4 s), import of `.zip` / `.7z` / `.rar` mods, and PC audio mod conversion. Peak
memory with all of them was about 6.2 GB.

---

## 1. Architecture

### 1.1 Baked hooks: why

Every Cyberpunk framework mod (RED4ext and its plugins) works by detouring game functions: it overwrites the first
instructions of a function with a jump. iOS does not let an app write to executable pages or make written pages
executable (ArchiveXL's one run-time code patch killed the game on the first try). So the jump has to be in the
binary **before it is signed**.

CyPort already rewrites the game binary at build time (`tools/ios_retarget.py`), so the hook sites are added there:

```
function entry (3 instructions)   ->   adrp x16, slot@PAGE
                                       ldr  x16, [x16, slot@PAGEOFF]
                                       br   x16
```

`slot` is an 8-byte pointer in the unused padding at the end of the game's `__DATA` segment (the last 0x1000 bytes,
below the existing free-hook slot at end - 0x100; room for 480 sites, 171 used). Data is writable, so hooking a site
at run time is one pointer write. A slot that nobody hooks points to a pass-through trampoline in the shim that
replays the three displaced instructions and jumps to `entry + 12`.

### 1.2 Baked hooks: how

| Piece | File | What it does |
|---|---|---|
| Site table | `tools/baked_sites.py` (`SITES`) and `tools/sites/*.txt` | One line per site: image offset and name. One file per plugin (`archivexl.txt`, `archivexl-128.txt`, `archivexl-ink.txt`, `codeware.txt`, `codeware-extra.txt`, `cet.txt`, `audioware.txt`, `inputloader.txt`, `modsettings.txt`) plus 10 core sites for RED4ext and TweakXL. |
| Safety checks | `baked_sites.py: fill_words` | The binary must have the 2.5.0 UUID; the entry must be a function start (`LC_FUNCTION_STARTS`) of at least 12 bytes; nothing within 128 KiB either side may branch to `entry+4` or `entry+8`. A site that fails is left out of both halves. |
| Binary patch | `ios_retarget.py: patch_baked_hooks` | Rewrites each entry, after comparing the three words with the expected ones. Another game build: logged, nothing patched. |
| Trampolines | `shim/BakedSites.inc` (generated, 1757 lines) | Enum, names, entry addresses, and one assembly trampoline per site. PC-relative displaced instructions (`b.cond`, `cbz`, `tbz`, `b`, `bl`, `adr`, `adrp`, literal `ldr`) are rewritten to reach the same target through `g_bhAux`. |
| Run time | `shim/MacShim.m: MSInstallBakedHooks` | Before the game's `main()`: for each site, checks that the entry really is `adrp x16 / ldr / br x16`, then fills the slot with the pass-through trampoline. `BakedHooks = NO` in `macshim.plist` keeps everything pass-through. The log line `baked hooks: ...` lists every site. |
| Related patch | `ios_retarget.py: patch_worldwidget_limit` | The one byte patch ArchiveXL does at run time on other platforms (one `b.hi` to `nop`), done at build time, with the same search the plugin does and an exact-words check. |

A site takes up to 8 chained detours (ArchiveXL, Codeware and CET share some functions).

### 1.3 Shim C API for plugins

All exported from `libMacShim.dylib` and looked up with `dlsym`, so a plugin built for iOS still loads when a
function is missing.

| Function | Used by | Purpose |
|---|---|---|
| `int MSBakedHookAttach(void *target, void *detour, void **original)` | RED4ext (`Platform/BakedHook.cpp`) | Put a detour in the site's slot; `*original` is the previous slot value. |
| `int MSBakedHookDetach(void *target, void *detour)` | RED4ext | Remove the newest detour (refused, and logged, if it is not the newest). |
| `int MSGameExecutablePath(char *buf, uint32_t *size)` | RED4ext and every plugin | The game folder's pretend macOS executable path, so "root = 4 folders up" resolves as on a Mac. |
| `int MSResolvePathCase(const char *path, char *out, size_t cap)` | ArchiveXL, CET, Input Loader, Mod Settings, RedFileSystem | The on-disk spelling of a path (the engine says `archive/mac/mod`, the folder is `archive/Mac/mod`, iOS is case-sensitive). |
| `int MSKeyboardShiftDown(void)` | Codeware | Shift state for key text. |
| `MSRegisterOverlayLayer`, `MSOverlaySetToggleHandler`, `MSOverlaySetCapture`, `MSOverlayShowKeyboard` | CET (`CET_IOS_OVERLAY`) | CET's transparent `CAMetalLayer` over the game view (left out of frame pacing, low latency, FPS counters and TV mirroring), a "CET" button on the touch pad, input capture while the overlay is open, and the iPhone keyboard. |

### 1.4 Loader

`MSLoadRED4ext` (`shim/MacShim.m`) `dlopen`s `Frameworks/RED4ext.dylib` once the game folder is known and before the
game's `main()`, the equivalent of `DYLD_INSERT_LIBRARIES` on macOS. It does nothing when the file is not in the
bundle, when `RED4ext = NO` is set in `macshim.plist`, or in multi-game mode (`Games/<version>/`).
`build.sh` copies the file only when `RED4EXT_DYLIB=` is given.

RED4ext then loads plugins from `Documents/Cyberpunk 2077/red4ext/plugins/<Name>/*.dylib`. **This is the part that
needs a personal certificate today** (section 3 replaces it).

### 1.5 Script compilation on the phone

Script mods and the frameworks' own `.reds` must be compiled into `r6/cache/final.redscripts`. The game cannot run
`scc`, so `redscript-ios` builds redscript 0.5.32's `scc` as a C library (`libscc_lib.dylib`, 2.0 MB, in
`Frameworks/`). `shim/ModManagerCore.c: MSModCompile` loads it on demand and compiles `r6/scripts` plus
`red4ext/plugins/<Name>/Scripts` of every plugin that is on, always against the game's original blob (kept as
`CyPort/final.redscripts.original`). The new blob replaces the old one only when the compile succeeds.

### 1.6 Mod manager

A **Mods** screen on the start screen (`shim/ModManager.swift`, `ModManagerMore.swift`, `ModManagerAudio.swift`,
`ModManagerUI.swift`, `ModManagerCore.c`; about 3,100 lines). The README section "Mods" documents it in full. In short:

- Import of `.zip` / `.7z` / `.rar` / `.archive` through libarchive (static, hidden symbols, in
  `shim/third_party/libarchive`), with a preview before anything is installed. Files are sorted into the game's
  folders. Windows binaries, RED4ext plugin packages and CET itself are refused; nothing from an archive is executed.
- REDmod packages converted on import; PC audio mods converted to the Mac layout (hash table rewritten, no re-encode).
- Per-mod switch, details, delete; dependency detection; conflict detection; load order; profiles; save backups.
- One switch per folder in `red4ext/plugins/` (off = the folder is moved to `CyPort/disabled-plugins/`).
- Fully usable with a controller. The start screen got the same controller navigation (`shim/Launcher.swift`).

### 1.7 Touch keyboard

A keyboard button on the touch pad opens the iPhone keyboard; typed text reaches the game as key presses, with a bar
above the keyboard for Esc, Tab, F1 to F12 and Paste. Typed keys pass controller-only mode. This is independent of
mods (it is useful for the game's own text fields) but CET and Mod Settings need it.

---

## 2. How CyPort is distributed today (what the design must fit)

Read from `README.md` and `build.sh` at `v1.5`:

- There is **no release IPA**: the game executable is the user's own. Each user runs `build.sh` on a Mac with
  `GAME_APP=` pointing at their copy. The repo carries a prebuilt `prebuilt/libMacShim.dylib`; `REBUILD_SHIM=1`
  compiles it from source.
- With `SIGN_ID` (+ `PROFILE`) `build.sh` signs every `Frameworks/*.dylib`, `Games/*/Frameworks/*.dylib`,
  `Games/*/CyberpunkGame.dylib` and then the app, and can install with `devicectl`.
- Without `SIGN_ID` it ad-hoc signs the same files and writes `CyPort-unsigned.ipa` for SideStore / AltStore /
  Sideloadly / LiveContainer, which re-sign what is inside the bundle with the user's own identity.
- Multi-game mode (`GAME_APPS=a|b`) puts each version in `Games/<version>/` and a starter picks one at launch.
- Game data and all writable state are in `Documents/Cyberpunk 2077/`.

Consequence: whatever is **inside the app bundle** is signed by whoever builds or sideloads the app. Whatever is in
`Documents` is signed by nobody, and iOS refuses to `dlopen` a library there unless it carries a signature from the
same team as the app.

---

## 3. Distribution design (proposed, not implemented)

### 3.1 Principle

- **Code in the bundle, data in Documents.** RED4ext and every framework plugin dylib ship inside the app, so
  Xcode / `build.sh SIGN_ID` / Sideloadly / AltStore / SideStore sign them together with the app.
- **Mods are data** (`.archive`, `.xl`, `.yaml`, `.reds`, `.lua`, `.xml`) and never need signing. The mod manager
  already refuses anything executable.

### 3.2 Layout

```
Cyberpunk2077.app/
  Frameworks/
    libMacShim.dylib, game dylibs            (today)
    libscc_lib.dylib                         script compiler
    RED4ext.dylib
    TweakXL.dylib  ArchiveXL.dylib  Codeware.dylib  cyber_engine_tweaks.dylib  mod_settings.dylib
    input_loader.dylib  RedFileSystem.dylib  RedData.dylib  RedHttpClient.dylib  Audioware.dylib
  ModSupport/
    manifest.json                            pack version, game UUID, per-plugin version + commit + sha256
    licenses/<Plugin>.txt                    every plugin's licence text
    game/                                    a mirror of what goes into "Documents/Cyberpunk 2077/"
      red4ext/bin/x64/cyberpunk2077_addresses.json
      red4ext/plugins/TweakXL/Data/..., Scripts/...
      red4ext/plugins/ArchiveXL/Bundle/..., Scripts/...
      red4ext/plugins/Codeware/Data/..., Scripts/...
      bin/x64/plugins/cyber_engine_tweaks/scripts/json, scripts/IconGlyphs, fonts/
      archive/Mac/mod/ModSettings.archive, ModSettings.archive.xl
      ...
```

The dylibs are flat in `Frameworks/` on purpose: that is where the game's own libraries already are, `build.sh`
signs `Frameworks/*.dylib` with no change, and every sideload signer is known to handle that folder. A nested
folder such as `PlugIns/red4ext/<Name>/` would need each signer checked for whether it finds Mach-O files there.

### 3.3 Run time

1. **Unpack data.** At start, when `ModSupport/manifest.json` has another pack version than the one recorded in
   `Documents/CyPort/modsupport.json`, the shim copies `ModSupport/game/` over the game folder (plugin data only;
   user files such as CET's `config.json`, `bindings.json`, mods and logs are not in the mirror and are untouched).
   Nothing changes for the plugins or for the mod manager: `red4ext/plugins/<Name>/` in Documents is still each
   plugin's home (data, scripts, logs), and the folder's presence is still the on/off switch.
2. **Load code from the bundle.** RED4ext's plugin loader, on iOS, walks `red4ext/plugins/<Name>/` as today, but
   for each folder loads `Frameworks/<name from manifest>.dylib` from the app bundle. A folder moved to
   `CyPort/disabled-plugins/` is not loaded, so the existing plugin switches keep working.
3. **Plugin home.** The psiberx plugins find their data and write their log next to their own dylib (through
   `dladdr`). With the dylib in the read-only bundle that has to be redirected: one new shim function, for example
   `int MSPluginHome(const char *name, char *out, size_t cap)`, returning
   `Documents/Cyberpunk 2077/red4ext/plugins/<Name>`, called from the `#if TARGET_OS_IPHONE` branch each port
   already has in `lib/Core/macOS.hpp` (and the equivalents in the other ports). About ten lines per plugin.
4. **Documents plugins (optional, off by default).** `DocumentsPlugins = YES` in `macshim.plist` makes the loader
   also try `*.dylib` in a plugin folder that has no bundled counterpart. No validation code is needed: iOS itself
   refuses a library whose signature is missing or from another team, and RED4ext logs the `dlopen` error. This
   keeps plugin development possible for people with a developer account and never loads anything unsigned.

### 3.4 Where the plugin binaries come from

`build.sh` gets one new switch, `MODS`:

| Value | Effect |
|---|---|
| `MODS=0` | No baked hooks (`patch_baked_hooks` and `patch_worldwidget_limit` skipped), nothing bundled, no RED4ext. The app is what it is today. |
| `MODS=<folder>` | Bundle the plugin pack in that folder (built locally, section 5). |
| `MODS=1` | Download the pinned pack (`tools/mods.lock`: URL + sha256) and bundle it. |

Suggested default: `MODS=0` for the first release that contains the code, then `MODS=1` once it has had testers.

The pack is a zip with exactly the `Frameworks/` dylibs and the `ModSupport/` folder above, ad-hoc signed. The
natural place to build it is CI in a small separate repo (for example `CyPort-mods`): the plugin forks as git
submodules at pinned commits, a macOS runner, one release asset per pack version. Plugin builds need no game files
(only the RED4ext SDK's address table), so CI can do it. The maintainer never has to build a plugin, and nobody's
certificate is in the pack: ad-hoc signatures are replaced when the app is signed.

### 3.5 Pinning to the game build

Three things have to agree: the game executable, the site table, and the plugin binaries.

- **Game.** The site table is for UUID `7D7382D0-...` only. `fill_words` refuses another UUID, and
  `patch_baked_hooks` also compares every site's three words. On any other build the patch log says
  `NOT applied` and the game is byte-identical to a `MODS=0` build.
- **Pack.** `manifest.json` names the game UUID it was built for. `build.sh` bundles the pack only when the
  UUID of `GAME_APP` matches, and says so otherwise.
- **Run time.** RED4ext must load only when the sites are baked. Today `MSLoadRED4ext` loads the dylib whenever it
  is in the bundle; this needs one more condition (at least the core sites report "baked"), so a mismatched build
  starts as a plain CyPort.
- **Plugin versus site list.** Each `tools/sites/<plugin>.txt` belongs to one plugin version (for example
  `archivexl-128.txt` to ArchiveXL 1.28.8). The manifest should carry a hash of the site table the pack was built
  against; `build.sh` compares it with the repo's.

**GOG 2.3.1:** no addresses exist for it, so no hooks, no RED4ext and no framework mods. What does not depend on
hooks should still work there: plain `.archive` replacers in `archive/Mac/mod`, and the mod manager's file
handling. Script mods and PC audio conversion on 2.3.1 are untested (the media id list and the compiler target were
only checked against 2.5.0). The Mods screen should say "framework mods need game 2.5.0" instead of offering them.

**GOG 2.5:** `kMSGames` in the shim lists GOG 2.5 with md5 `02276ae5...`; the Steam 2.5.0 executable the sites
were made from has md5 `4a4f6d00...` and is **not** in `kMSGames`. Whether the GOG 2.5 code is the same at the same
addresses is unknown (see section 7). If it is, accepting a second UUID is a one-line change, since the per-site
word check stays.

**Multi-game mode:** the baked sites are patched into the 2.5.0 copy, but RED4ext is skipped. Mods stay off there
until someone needs it.

### 3.6 Licences

Read from the `LICENSE` file of each local checkout:

| Component | Upstream | Fork the iOS branch is based on | Licence |
|---|---|---|---|
| RED4ext | WopsS/RED4ext | codeman101/RED4ext-macos | MIT |
| RED4ext.SDK | WopsS/RED4ext.SDK | codeman101/RED4ext.SDK-macos | MIT |
| TweakXL | psiberx/cp2077-tweak-xl | codeman101/cp2077-tweak-xl | MIT |
| ArchiveXL (+ Bundle) | psiberx/cp2077-archive-xl | codeman101/cp2077-archive-xl-macos | MIT |
| Codeware | psiberx/cp2077-codeware | codeman101/cp2077-codeware | MIT |
| Cyber Engine Tweaks | maximegmd/CyberEngineTweaks | codeman101/CyberEngineTweaks | MIT (see note) |
| Mod Settings | jackhumbert/mod_settings | codeman101/mod_settings | MIT |
| Input Loader | jackhumbert/cyberpunk2077-input-loader | none (ported here from upstream) | MIT |
| RedFileSystem / RedData / RedHttpClient | rayshader/cp2077-red-* | none (ported here from upstream) | MIT |
| Audioware | cyb3rpsych0s1s/audioware | codeman101/audioware | no LICENSE file in the checkout: check upstream |
| red4ext-rs | jac3km4/red4ext-rs | codeman101/red4ext-rs | MIT |
| redscript (scc) | jac3km4/redscript | none | MIT |
| libarchive / liblzma | | | BSD 2-clause / 0BSD (already in `NOTICE`) |

Note on CET: the `LICENSE` in the checkout is MIT (Copyright 2018 yamashi). If upstream states something else
elsewhere (it has been described as GPLv3 with a mod exception), that must be settled before a binary is
published; under GPL the pack's release page would have to offer the exact source, which pinned submodules give.

What this means in practice:

- CyPort itself never distributes an IPA, so the only redistribution of plugin binaries is the **pack**.
- MIT asks for the copyright notice and licence text to travel with the binary: `ModSupport/licenses/` in the pack,
  and one paragraph in CyPort's `NOTICE`.
- Statically linked dependencies need the same treatment (LuaJIT, sol2, Dear ImGui, nlohmann json, spdlog, fmt,
  yaml-cpp, pugixml, SQLite, kira and the other Rust crates, CET's fonts). The pack's CI should collect them.
- Courtesy: ask codeman101 and the plugin authors before publishing builds of their work under the CyPort name.

### 3.7 App size

All plugin dylibs together are about 33 MB (CET with overlay 9.8, Codeware 5.1, Audioware 3.6, ArchiveXL 3.6,
RED4ext 2.5, TweakXL 2.3, scc 2.0, RedData 1.2, the rest under 1 MB each), plus a few MB of data (ArchiveXL Bundle
1.6 MB, two fonts, scripts, tables). The two static libraries for libarchive add 1.3 MB to the repo and somewhat less to the shim. Next to 65 GB of game data it
does not matter; the copy of plugin data in Documents doubles those few MB.

### 3.8 Taking plugin updates from upstream

1. Upstream releases; codeman101 merges it into his Mac branch (that is how ArchiveXL 1.28.8 arrived).
2. The iOS branch is rebased on it. Each iOS branch is 1 to 3 commits, all behind `TARGET_OS_IPHONE`. The best end
   state is these commits merged into codeman101's repos, so there is no iOS fork to maintain at all.
3. If the plugin hooks new functions, its `tools/sites/<plugin>.txt` gets the new offsets, `BakedSites.inc` is
   regenerated, and the app must be rebuilt (sites live in the game binary). A plugin that asks for an address that
   is not baked gets a failed attach and only that feature is off.
4. The pack repo bumps the submodule pin and the pack version; CyPort bumps `tools/mods.lock`.

A new **game** version means new addresses for every site, on top of CyPort's own patches. The site lists are
offsets found by hand and by pattern search on 2.5.0; there is no automatic port.

---

## 4. Proposed PR series

Sizes are added lines. The branch `mod-support` is one commit on top of `main` (0568bc9), so the PRs are cut by
file and by section of `shim/MacShim.m`, not by commit. It also carries two local tweaks that were already reported
as separate issues and are **not** part of this series: the "Play from the SSD" button and `FakeSonyAsXbox`.

Each PR leaves the app working and changes nothing for a user who does not opt in. PRs 1, 2 and 6 are independent
of mods and can go in any order.

| # | Title | Files | Size | Risk | Test |
|---|---|---|---|---|---|
| 1 | Touch keyboard (button, Esc/Tab/F-keys/Paste bar, typed keys in controller-only mode) | `shim/MacShim.m` | ~150 | Low. Touches the touch pad and key event path. | Type in the game's own fields (save name, search); controller-only mode still ignores pad noise; hardware keyboard unchanged. |
| 2 | Start screen controller navigation | `shim/Launcher.swift`, `shim/StoresUI.swift` | ~330 | Low, UI only. | Every control reachable with a pad; touch unchanged. |
| 3 | Baked-hook mechanism, core sites only, no consumer | `tools/baked_sites.py`, `tools/ios_retarget.py`, `shim/BakedSites.inc`, `shim/MacShim.m`, `build.sh` (`MODS`) | ~450 hand-written + generated include | **Medium**: patches the game binary. Mitigated by the UUID check, per-site word check, function-start and branch-into checks, run-time re-check, `BakedHooks = NO`, `MODS=0`. | 2.3.1: retarget log says `NOT applied`, output identical to before. 2.5.0: log lists every site as pass-through; play 30+ minutes; compare FPS with `MODS=0`. |
| 4 | Plugin C API + RED4ext loader behind a flag | `shim/MacShim.m` (`MSBakedHookAttach/Detach`, `MSGameExecutablePath`, `MSResolvePathCase`, `MSKeyboardShiftDown`, `MSLoadRED4ext` with the "sites baked" condition), `build.sh` (`RED4EXT_DYLIB`) | ~120 | Low without a RED4ext in the bundle (nothing runs). | Build without `RED4EXT_DYLIB`: no change. With it and an empty plugins folder: `RED4ext: loaded`, game plays. |
| 5 | Plugin site lists + world widget patch | `tools/sites/*.txt`, regenerated `BakedSites.inc`, `ios_retarget.py: patch_worldwidget_limit` | ~200 lines of lists + generated | Medium: 161 more functions go through a slot. Same checks as PR 3. | As PR 3, plus one long play session; the log must show no `not baked` and no `left out`. |
| 6 | Mod manager, part 1: Mods screen, import, on/off, delete, libarchive | `shim/ModManager.swift`, `ModManagerUI.swift`, `ModManagerCore.c`, `shim/third_party/libarchive/*`, `build.sh`, `NOTICE`, `Launcher.swift`, `README.md` | ~1,550 + vendored headers and two `.a` files | Medium: large, but only runs from the start screen and only moves files under the game folder. | Import each archive type; switch a mod off and on; delete; a plain `.archive` replacer shows in game (works on 2.3.1 too). |
| 7 | On-phone script compile | `ModManagerCore.c: MSModCompile`, `ModManager.swift`, `build.sh` (`SCC_DYLIB`) | ~250 | Medium: replaces `final.redscripts`. Original blob is kept; replaced only on success. | A script mod compiles and works; a broken one is rolled back with the compiler's message; deleting all script mods restores the original blob. |
| 8 | Mod manager, part 2: REDmod, dependencies, conflicts, load order, profiles, save backups | `ModManagerMore.swift`, `ModManagerUI.swift`, `ModManager.swift` | ~1,400 | Low to medium (file moves, renames in `archive/Mac/mod`). | The README's "Mods" list, item by item. |
| 9 | PC audio mod conversion | `ModManagerAudio.swift`, `shim/CyPortMacMedia.txt`, `tools/test_mod_audio*` | ~460 + a 4,822-line id list | Low: writes a converted copy, byte-compared with the Mac converter by `tools/test_mod_audio.sh`. | Run the test script; import a PC audio replacer and hear it in game. |
| 10 | CET overlay API | `shim/MacShim.m` (`MSRegisterOverlayLayer` etc., "CET" button, input capture) | ~100 | Low when no plugin calls it. Touches the present path (the overlay layer must be skipped by pacing and TV mirroring). | Without CET: no change, FPS overlay and pacing the same. With CET: open and close the console, type, AirPlay. |
| 11 | Bundled plugins (section 3): `MODS=1` / `MODS=<folder>`, `ModSupport/` unpack, `tools/mods.lock`, licences, `MSPluginHome` | `build.sh`, `shim/MacShim.m`, `NOTICE`, `README.md`, plus the loader change in RED4ext and ~10 lines per plugin port | new work, estimated ~300 in CyPort | Medium: new code, **not written yet**. | Unsigned IPA through Sideloadly, AltStore and SideStore on a free Apple ID: all plugins load (`red4ext.log`), no file in Documents is a dylib. Update the app with a newer pack: plugin data refreshed, user config kept. |
| 12 | `tools/build-all.sh` for people who build the plugins themselves | `tools/build-all.sh` | ~130 | None for users. | Runs on a clean machine with only the documented env vars. |

Notes:

- `prebuilt/libMacShim.dylib` on the branch is rebuilt from the branch's `shim/` (ad-hoc signed, no team), so a
  default build has all of this. Each PR cut from the branch should rebuild it from that PR's own `shim/`, or leave it
  to the maintainer.
- Personal build settings (signing identity, profile, bundle id, device, local paths) live in `tools/local.env`,
  which is git-ignored; `tools/local.env.example` shows the format. No script on the branch has one as a default.
- PR 6 to 9 can also be offered as one PR if four reviews of the same files is more work than one long one.
- The branch is based on `main` at 0568bc9 (v1.5 plus the Ko-fi README change).

---

## 5. Building each plugin for iOS

Common requirements: Xcode with the iOS SDK, CMake, Ninja; Rust through rustup for the two Rust projects.
Common CMake arguments (`IOS` below):

```
-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0
```

All iOS work is on local branches that are **not pushed anywhere yet**.

| Repo (branch) | Based on | Build | Output |
|---|---|---|---|
| `RED4ext-macos` (`ios-baked-hooks`, 1 commit) | codeman101 `main` | `cmake -S . -B build-ios $IOS && ninja -C build-ios RED4ext.Dll` | `build-ios/libs/RED4ext.dylib`; also ship `deps/red4ext.sdk/cyberpunk2077_addresses.json` to `red4ext/bin/x64/` |
| `tweak-xl` (`ios`, 1 commit) | codeman101 `mac-v1-2.5` | `cmake -S . -B build-ios $IOS && ninja -C build-ios` | `TweakXL.dylib`, `data/ExtraFlats.dat`, `data/InheritanceMap.dat`, `scripts/*.reds` |
| `archive-xl` (`ios-128` = 1.28.8; `ios` = 1.27.4) | codeman101 `mac-next-1.28` + psiberx v1.28.8 merged | `cmake -S macos -B build-ios $IOS && ninja -C build-ios` | `ArchiveXL.dylib`, `scripts/*.reds`, and the Bundle from the 1.28.8 release |
| `codeware` (`ios`, 2 commits) | codeman101 `mac-v1-1.21` | `cmake -S macos -B build-ios $IOS -DRED4EXT_SDK_DIR=<RED4ext.SDK-macos, mac-next-sdk1212> && ninja -C build-ios`, then compose the scripts as `tools/build-all.sh` does (`tools/compose-redscripts.py`, minus `tools/build-cache.exclude`) | `Codeware.dylib`, `data/KnownHashes.txt`, `Scripts/*.reds` |
| `mod-settings` (`ios`, 1 commit) | codeman101 `mac-next-0.2.28` | `macos/ios-stage.sh` | `mod_settings.dylib`, `ModSettings.archive` + `.xl`, scripts |
| `input-loader` (`ios`, 1 commit) | jackhumbert `main` (the Mac port is in this commit) | `macos/stage-ios.sh` | `input_loader.dylib` |
| `cet` (`ios` headless, `ios-overlay`) | codeman101 `mac-next` | `cmake -S macos -B build-ios-overlay $IOS -DCET_IOS_OVERLAY=ON -DRED4EXT_SDK_DIR=<sdk1212> -DCODEWARE_DIR=<codeware> && cmake --build build-ios-overlay && ios/stage-deploy.sh build-ios-overlay "" deploy-overlay`; dependency sources in `../vendor-mac/` (LuaJIT interpreter-only, sol2, nlohmann json, hopscotch-map, TiltedCore, fmt, spdlog) | `cyber_engine_tweaks.dylib`, `scripts/json`, `scripts/IconGlyphs`, two fonts. Details in `cet/ios/README.md` |
| `cp2077-red-filesystem`, `cp2077-red-data`, `cp2077-red-httpclient` (`ios`, 1 commit each) | rayshader `master` (the Mac port is in this commit) | `macos/ios-stage.sh` in each | `RedFileSystem.dylib`, `RedData.dylib`, `RedHttpClient.dylib`, scripts |
| `audioware` (`ios`) + `red4ext-rs` (`ios`) | codeman101 `macos` / `macos-dev` | `ios/build-ios.sh` (cargo, target `aarch64-apple-ios`; needs `../red4ext-rs` and `../RED4ext.SDK-macos`) | `Audioware.dylib`, `Scripts/`, `mac-hooks.txt` |
| `redscript-ios` (`ios`, 1 commit on 0.5.32) | jac3km4 | `./build-ios.sh` (`--test` also compiles on the Mac) | `dist/ios/libscc_lib.dylib` |
| `audio-mac` | local | Python reference converter (`convert.py`); only used by `tools/test_mod_audio.sh` | |

`tools/build-all.sh` in CyPort does the first four plus the site table, the app and a staging folder in one go.
After any change to a hook list: `python3 tools/baked_sites.py > shim/BakedSites.inc` (needs the 2.5.0 executable).

---

## 6. What is NOT verified

- Any device other than one iPhone 17 Pro. In particular **8 GB devices**: peak memory with everything on was
  about 6.2 GB; the README says the plain game uses 5 to 5.5 GB and 8 GB is the minimum.
- iPad, iPhone Duo, AirPlay / TV output with the CET overlay layer.
- **The whole of section 3.** Today the plugins are in Documents, signed with a developer certificate. Bundled
  plugins, the data unpack, `MSPluginHome` and the loader change are designed, not built.
- Free Apple ID, SideStore, AltStore, Sideloadly, LiveContainer. Also the compact memory layout used without
  extended virtual addressing, together with plugins.
- GOG 2.5 (whether its code matches the Steam 2.5.0 sites), GOG 2.3.1 with the mod manager, multi-game builds.
- Building on Linux.
- Cloud saves together with mods: CyPort uploads phone saves to GOG / Steam / Epic. A save made with mods then
  reaches the PC or Mac, which may not have those mods.
- Sessions longer than a normal test run with all plugins loaded; thermal behaviour with them.
- `modlist.txt` load order (off by default, never confirmed running).
- Some plugin READMEs and commit messages still say "not run on a device yet" (RedFileSystem, RedData,
  RedHttpClient, the CET overlay). They were run afterwards; the texts were not updated.

---

## 7. Open questions for the maintainer

1. **Do you want this at all, and behind which default?** `MODS=0` by default for a release or two, or on from the
   start?
2. **Committed or generated `BakedSites.inc`?** Committed, it works with the prebuilt shim but holds three
   instruction words of the game per site (about 500 words in total) and is tied to one game build. Generated at
   build time from `GAME_APP`, it needs `REBUILD_SHIM=1` (so no prebuilt shim for modded builds) but holds no game
   code and could follow whatever build the user has sites for.
3. **Steam 2.5.0 versus GOG 2.5.** Can you compare the two executables' `__text` (or just the three words at a
   handful of sites)? If equal, the UUID check takes two values. Should the Steam md5 also be in `kMSGames`?
4. **Who hosts the plugin pack?** A `CyPort-mods` repo under your account with CI, or under the contributor's, or
   no pack at all and only `MODS=<folder>` for people who build the plugins themselves?
5. **Flat `Frameworks/` or a subfolder** for the plugin dylibs? Flat is the safe choice for sideload signers.
6. **The prebuilt shim.** With libarchive it grows, and the static libraries (1.3 MB) are added to
   the repo. Acceptable, or should the mod manager be a compile-time option of the shim?
7. **Cloud saves.** Should save sync pause, or warn, while framework mods are on?
8. **Upstreaming the ports.** Is it fine to propose the iOS commits to codeman101 first, so CyPort depends on his
   repos instead of on a contributor's forks?
9. **Multi-game mode.** Is RED4ext wanted there, or is "mods need a single-game 2.5.0 build" acceptable?
10. `CyPortMacMedia.txt` (Wwise media ids of the Mac build) and the optional `MAC_HASHES` resource list are derived
    from game data (numbers only, no content). Commit them, or generate them from the user's copy at build time?
