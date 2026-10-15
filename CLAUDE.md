# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Da10bayo — a macOS 14+ "Dynamic Island" for the MacBook notch. Pure Swift Package (no Xcode project, no third-party dependencies), AppKit + SwiftUI, runs as an accessory app (`LSUIElement`, no Dock icon). UI strings and code comments are in Russian — keep it that way.

## Commands

```bash
swift build                 # quick debug compile check (no bundle)
./build.sh                  # release build → build/Da10bayo.app (Info.plist, icon, bridge dylib, codesign)
./build.sh --install        # build, copy to /Applications, kill the old instance and launch
```

There are no tests and no linter. Debug builds (`#if DEBUG`) listen for the distributed notification `da10bayo.debug` to force states without real events — see `installDebugHooks()` in `AppDelegate.swift` (`power`, `banner`, `open`, `drag`/`dragend`, `track`, `convui:<path>`, `conv:<path>|<ext>`, `claudetab`, `acttab`, `vpnstrip`, `vpntoggle` (really toggles the VPN), `dump:<file>`, `snap:<file>.png`, `filmopen:<dir>`/`filmclose:<dir>` for 30 fps frame dumps of the morph — the last writes a PNG of the island window, useful when screen recording isn't permitted). A raw `.build/debug/Da10bayo` started from a sandboxed shell can't reach the WindowServer; wrap it in a throwaway `.app` with a different bundle id and `open` it. Running the raw `swift build` binary works for UI iteration but has no Info.plist, so TCC prompts (Automation, Calendar, Bluetooth) behave differently — use `build.sh` to test permissions. `build.sh` signs with the first "Apple Development" identity in the keychain (override with `SIGN_IDENTITY`, `-` = ad-hoc), so the Accessibility grant survives rebuilds. With ad-hoc signing TCC pins the grant to the cdhash and silently stops matching after every rebuild (tccd logs "Failed to match existing code requirement"); recovery is `tccutil reset Accessibility com.da10bayo.app` and granting again. In zsh `log` is a builtin — read diagnostics with `/usr/bin/log show --predicate 'subsystem == "com.da10bayo.app"'`.

## Architecture

**Wiring** — `App/AppDelegate.swift` owns every service and the single `NotchViewModel`, and connects service callbacks (`onChange`, `onPowerChange`, `onConnect`, `onUpcoming`, `onFinish`…) to `vm.showBanner(...)` / `vm.showPower(...)`. New notification sources should follow the same pattern: service exposes a closure, AppDelegate turns it into a `Banner`.

**State model** — `Notch/NotchViewModel.swift` is the source of truth. The island is in exactly one of: open (`isOpen`, showing a `tab`, the converter when `showConverter`, or the drop-target menu while `isFileDragActive`), a transient `peek` (`.power` / `.vpn` strip or `.banner`, auto-dismissed via `present(_:for:)`), or compact (`compactKind`: media/timer/none). `islandSize`, `topRadius`, `bottomRadius` are derived from that state; the view only animates toward them. The VM forwards `objectWillChange` of all services and `AppSettings`, so views can read services through `vm`. Shared spring curves live in the `Animation` extension (`.notchOpen`, `.notchClose`, `.notchPeek`).

**Window & input** — `Notch/NotchController.swift` places a fixed-size, transparent `NotchPanel` (level above main menu, all spaces, full-screen auxiliary) centered on the notch; the panel is larger than the island. Clicks pass through (`ignoresMouseEvents`) unless the cursor is inside `islandRect()`, computed from `vm.islandSize`. Hover-to-open/close-on-leave is driven by global+local mouse monitors plus a 0.25s fallback timer; file drags are detected via the drag pasteboard `changeCount`. Two-finger scroll gestures (open/close, next/prev track) are only seen by the local monitor, i.e. when the cursor is over the panel.

**Geometry** — `Notch/NotchGeometry.swift` picks the notched screen and measures the notch from `auxiliaryTopLeftArea/RightArea`; screens without a notch get a virtual 180pt notch of menu-bar height. `Views/NotchShape.swift` draws the island (flat top, concave top "ears" of `topRadius`, rounded bottom corners), both radii animatable. Content is padded horizontally by `topRadius` so it stays inside the ears.

**Views** — `Views/IslandView.swift` morphs one black `NotchShape` and swaps content (Open / Power / Banner / Compact) with `.islandContent`/`.peekContent` blur transitions. The shape is drawn from `vm.shapeWidth/shapeHeight/shapeTop/shapeBottom`, not `islandSize` directly: `IslandView` calls `vm.morph(from:to:)` on every `islandSize` change, which animates width and height separately — opening from the notch grows height first then width (the "drop" from the reference video), closing shrinks width first then height; resizes while open use one spring. `NotchShape` ears always start at the screen bezel (`shoulder` stays 0; the parameter is kept for experiments). Sizes per state live in `openSize`/`compactSize`/`powerSize`/… in the view model (player layout ≈ 2.06× notch width so three header icons fit beside the notch; header hidden unless hovered — `minimalHeader`). Each state's content is laid out at its *final* fixed size and the animated shape clips it — never size content to the animating `islandSize`, or it squashes mid-animation; keep the per-state frames in `content` in sync with `islandSize`. Drops go through a single `IslandDropDelegate` on the island; the target is picked from frames reported by `DropTargetsView` via `DropTargetFramesKey` in the `"island"` coordinate space. `AroundNotch` (in `Components.swift`) lays out left/right content around the physical notch gap — use it for anything shown in the collapsed/peek states. `OpenIslandView.swift` holds the tabs (home/media, shelf, claude, notifications, activities). Volume/brightness HUD was removed on purpose — the system indicator is used.

**Media** — `Services/MediaService.swift` polls Spotify and Apple Music via AppleScript (compiled once, executed on a serial queue) every second plus their distributed notifications. Every other player (Yandex Music `ru.yandex.desktop.music`, browsers…) arrives as `Source.other` from `Services/NowPlayingBridge.swift`: MediaRemote is closed to non-Apple processes since macOS 15.4, so `Helpers/MediaRemoteBridge.m` is built by `build.sh` into `Contents/Resources/libD10MediaRemote.dylib` and loaded into the Apple-signed `/usr/bin/perl` via `Helpers/mediaremote.pl`; it streams JSON lines on stdout and takes commands (`toggle`, `next`, `seek <s>`…) on stdin. AppleScript sources win over the bridge for the same app. The bridge only exists inside the `.app` bundle — a bare `swift build` binary has no Now Playing support for other players. AppleScript numbers come back with a comma decimal in the Russian locale — parse via the existing `number()` helper.

**Claude** — `Services/ClaudeService.swift` streams Messages API answers over raw HTTP/SSE (no Swift SDK) with `claude-opus-5-5`, `effort: low`, `fallbacks: "default"`; the API key lives in the Keychain (`Keychain` enum), set in Settings → Claude. Without a key the question is copied to the clipboard and the Claude app (`com.anthropic.claudefordesktop`) is opened. `vm.keepOpen` blocks auto-close while the field is focused or a reply streams; the tab makes the non-activating panel key for typing and re-activates the frontmost app on disappear.

**VPN** — `Services/VPNService.swift` drives a system VPN configuration (default `incy`, the INCY app's Network Extension config, `AppSettings.vpnName`) through `/usr/sbin/scutil --nc start|stop|status|list`; polls status every 2 s (0.5 s while connecting) and fires `onChange` on settled transitions, including ones made in the VPN app itself → `vm.showVPN(on:)` strip. UI: shield button in the header (left of the notch), `VPNCard` in Activities, island context menu.

**Other apps' notifications** — `Services/AppNotificationService.swift` polls (Accessibility API) the Notification Center process for banner groups (`AXNotificationCenter*` subroles) and the Dock for `AXStatusLabel` badges; there is no public API for this, and it requires the Accessibility grant.

**Converter** — `Services/FileConverter.swift`: ImageIO for images, `AVAssetExportSession` for MP4/MOV/M4A, `AVAssetReader`→`AVAssetWriter` for PCM (WAV/AIFF/CAF). No MP3 (no system encoder).

**Settings** — `Settings/AppSettings.swift` is a singleton of `@Published` properties each persisted to `UserDefaults` in `didSet`. Adding a setting = property + default in `init` + control in `SettingsView.swift`. Hidden actions (preview, test banner) are posted from settings via `Notification.Name.d10Preview` / `.d10TestBanner`.

**Shelf** — `Services/ShelfStore.swift` persists dropped files (optionally copied) across launches; `Views/ShelfViews.swift` handles drag-out, QuickLook thumbnails, AirDrop.

## Notes

- On first launch from `/Applications` the app registers itself as a login item (`SMAppService.mainApp`, flag `didSetupLaunchAtLogin`); after that the Settings toggle owns it.

- New framework imports must also be added to `linkerSettings` in `Package.swift`.
- New permissions need a usage-description key in `Resources/Info.plist`.
- `build/` and `.build/` are generated output.
