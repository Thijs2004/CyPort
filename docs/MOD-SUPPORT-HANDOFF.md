# Mod support: handoff for an AI coding assistant

Short, factual brief for whoever (human or AI) picks this branch up. The long version, with the design for shipping
without a personal certificate and the proposed PR series, is `docs/MOD-SUPPORT-INTEGRATION.md`. Read that next.

## What this branch adds

- **Baked hooks.** iOS forbids patching code at run time, so hook sites are written into the game executable at build
  time. `tools/baked_sites.py` reads `tools/sites/*.txt` (one `0x<image offset>  # name` per line), checks every site
  against the Steam Mac 2.5.0 executable (UUID `7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC`: function start, at least 12
  bytes, nothing branches into entry+4/+8) and writes `shim/BakedSites.inc`. `tools/ios_retarget.py` rewrites each
  entry to `adrp x16 / ldr x16 / br x16` through slots at `__DATA end - 0x1000`. Plugins attach through the shim
  exports `MSBakedHookAttach` / `MSBakedHookDetach`. 171 sites today.
- **RED4ext loading.** The shim loads `Frameworks/RED4ext.dylib`, which loads plugins from
  `Documents/Cyberpunk 2077/red4ext/plugins/<Name>/`. Today those plugin dylibs must be signed by the app's team
  (section 3 of the integration doc replaces this with plugins bundled inside the app).
- **Mod manager** (`shim/ModManager*.swift`, `shim/ModManagerCore.c`, libarchive in `shim/third_party/`): import
  .zip/.7z/.rar/.archive from Files, enable/disable, profiles, save backups, PC-to-Mac audio conversion, and on-device
  redscript compilation through `libscc_lib.dylib` (redscript fork, see below). Compiling takes about 0.4 s on an
  iPhone 17 Pro; a failed compile undoes the change and shows the compiler error.
- **CET overlay API** (`MSRegisterOverlayLayer`, `MSOverlaySetToggleHandler`, `MSOverlaySetCapture`,
  `MSOverlayShowKeyboard`), an on-screen keyboard with Esc/Tab/F1-F12/Paste, and controller navigation on the
  start screen.

## Repositories (branch to use)

| Component | Fork | Branch | Upstream |
|---|---|---|---|
| RED4ext loader | github.com/LucasPrado97/RED4ext-macos | `ios-baked-hooks` | codeman101/RED4ext-macos (wopss/RED4ext) |
| TweakXL | github.com/LucasPrado97/cp2077-tweak-xl | `ios` | codeman101, psiberx |
| ArchiveXL | github.com/LucasPrado97/cp2077-archive-xl-macos | `ios-128` (1.28.8; `ios` = 1.27.4) | codeman101, psiberx |
| Codeware | github.com/LucasPrado97/cp2077-codeware | `ios` | codeman101, psiberx |
| Cyber Engine Tweaks | github.com/LucasPrado97/CyberEngineTweaks | `ios-overlay` (`ios` = without the overlay) | codeman101, yamashi |
| Mod Settings | github.com/LucasPrado97/mod_settings | `ios` | codeman101, jackhumbert |
| Input Loader | github.com/LucasPrado97/cyberpunk2077-input-loader | `ios` | jackhumbert |
| RedFileSystem / RedData / RedHttpClient | github.com/LucasPrado97/cp2077-red-{filesystem,data,httpclient} | `ios` | rayshader |
| Audioware | github.com/LucasPrado97/audioware | `ios` | codeman101, cyb3rpsych0s1s (**no licence file upstream**) |
| red4ext-rs (Audioware's base) | github.com/LucasPrado97/red4ext-rs | `ios` | codeman101, jac3km4 |
| redscript (on-device compiler) | github.com/LucasPrado97/redscript | `ios` | jac3km4 |
| RED4ext.SDK | github.com/codeman101/RED4ext.SDK-macos | `mac-next` (unchanged) | codeman101 |

All are MIT except Audioware, which has no licence: do not bundle it in a release until its author confirms.

## Building

1. Clone the plugin forks side by side in one folder (`PLUGINS_ROOT`, default `../CyPort-red4ext` next to this repo)
   with the folder names `tools/build-all.sh` expects: `RED4ext-macos`, `tweak-xl`, `archive-xl`, `codeware`. The
   other plugins have their own stage script (`macos/ios-stage.sh`, `macos/stage-ios.sh`, `ios/build-ios.sh`,
   `ios/stage-deploy.sh`).
2. `cp tools/local.env.example tools/local.env` and set `GAME_APP` (the Steam Mac 2.5.0 `Cyberpunk2077.app`).
   `SIGN_ID`, `PROFILE`, `BUNDLE_ID`, `CYPORT_DEVICE` are optional; without `SIGN_ID` the result is an unsigned IPA
   and ad-hoc signed plugins. `tools/local.env` is git-ignored.
3. `tools/build-all.sh` (or `SKIP_PLUGINS=1 tools/build-all.sh` to reuse built plugins). It regenerates
   `shim/BakedSites.inc`, runs `build.sh` with `REBUILD_SHIM=1`, and stages `build/deploy/Cyberpunk 2077/`.
4. **Always grep `build.log` for `error:`.** `build.sh` prints "signature OK" even when the Swift compile failed.

`build.sh` alone still works the old way; `prebuilt/libMacShim.dylib` is rebuilt from this branch (ad-hoc signed).

## Invariants that are easy to break

- The site offsets and the patch bytes are for the Steam Mac 2.5.0 executable only (md5 `4a4f6d00…`). The shim's
  `kMSGames` table lists GOG builds but not this one; nobody has compared GOG 2.5 with Steam 2.5.0. A build whose UUID
  does not match must get no baked hooks and no RED4ext.
- `shim/BakedSites.inc` is generated but committed (so a plain `build.sh` works). It contains three instruction words
  per site from the game executable; whether to commit it or generate it at build time is an open question.
- Script functions declared in Rust-registered classes get no variable layout on Apple targets; red4ext-rs
  `apple_layout::layout_scripted_functions` runs the game's layout routine (0x109B314) for them. Without it, their
  locals overwrite their parameters (Audioware got `None` event names).
- iOS file names are case-sensitive: plugins resolve paths through `MSResolvePathCase`; the game folder comes from
  `MSGameExecutablePath`.
- The Mac build reads `engine/config/platform/mac/*.ini`, not `pc`, and Mac audio media is
  `base\sound\soundbanks\media\<id>.wem` (PC mods use `base\sound\soundbanks\<id>.wem`; the importer converts).
- Installing a build with `devicectl` while the game runs kills it.

## Verified on device (iPhone 17 Pro, iOS 27.2, Steam Mac 2.5.0)

RED4ext with all frameworks above, CET console and overlay, Mod Settings, Input Loader, Audioware (custom events
play), PC audio replacers after conversion, Virtual Car Dealer and other script/archive mods, 35 mods at once.
Memory peaks at 6.0–6.5 GB with `GPUBudgetGB = 5`; FPS 60–100 with frame generation.

Not verified: 8 GB devices, iPad, iPhone Duo, TV output with the CET layer, free Apple ID and sideload signers,
GOG builds, multi-game builds, cloud-save sync with modded saves, `modlist.txt` load order.

## Suggested first steps

1. Build once with `tools/build-all.sh` and confirm the app runs without any plugin installed (no behaviour change).
2. Read section 4 of the integration doc and cut the independent PRs first (keyboard, start-screen controller
   navigation); they do not depend on mods.
3. Decide the open questions in section 7 (bundled plugins, `BakedSites.inc`, cloud saves) before the loader PRs.
