<p align="center">
  <img src="docs/icon.png" width="128" alt="Ruban icon">
</p>

<h1 align="center">Ruban</h1>

<p align="center">A scrolling window manager for macOS, in the spirit of PaperWM and niri.</p>

<p align="center"><a href="README.fr.md">Version française</a></p>

---

Every window sits side by side on one endless horizontal strip. Nothing overlaps, nothing hides
behind anything else, and opening one more app never shrinks the others: the strip just gets
longer, and you scroll through it with the keyboard or a three-finger swipe.

<p align="center">
  <img src="docs/indicator.png" width="420" alt="The strip indicator: one tile per column, the focused one highlighted">
</p>

> **Status: beta.** Ruban has been built and used on one machine so far: macOS 27, Apple silicon,
> a single built-in display, a French AZERTY keyboard. Multiple displays, Spaces and external
> trackpads are implemented but have not been tested. The settings window is in French for now.

## Features

- **The strip.** New windows open right next to the focused one. Moving focus scrolls the strip just
  far enough to show the window, with an animation that starts the moment you press the key.
- **Trackpad swipe.** Swipe with three fingers (or four) and the strip follows them one to one,
  then glides to rest on the nearest column, carrying the speed of your fingers. A quick flick
  goes to the next column.
- **Widths.** Cycle through preset widths (33 / 50 / 66 % by default, configurable), toggle full
  width, centre a column, nudge it wider or narrower.
- **Drag and drop.** Drag a window by its title bar and drop it onto another window to stack it there
  (above or below, depending on which half you drop on), or near a window's edge or between two
  windows to give it a column of its own. A translucent preview shows where it will land before you
  let go. Works across displays too.
- **Stacks and tabs.** Put several windows in one column, resize them inside the stack, or turn the
  stack into a tabbed column. Ruban learns the minimum height of apps that refuse to get shorter; a
  stack whose windows can't all fit on screen is shown as tabs instead of spilling off the bottom.
- **Pinned columns.** Keep one window at the left or right edge while the rest scrolls beside it.
- **Strip indicator.** A frosted bar with one tile per column appears while you move around. Click
  a tile to jump there; drag it onto another tile to merge the two columns into one stack, or between
  two tiles to move the column there.
- **Mouse resize.** Resize a window by hand and its column takes the new width.
- **One strip per display and per Space**, and a shortcut to send a window to the next display.
- **Floating.** Dialogs, Quick Look and fixed-size windows (Calculator) float on their own. Pick
  apps that should always float, or float any window with a shortcut.
- **Well-behaved.** Native window tabs (Finder, Terminal) take one column. Apps that insist on a
  minimum size keep it and their column widens instead of fighting them. Background apps that open a
  window don't steal focus. The column order comes back after a restart.
- **Native and light.** A Swift menu bar app with a SwiftUI settings window. Every change applies
  instantly. Window moves run on one background queue per app, so a busy app never freezes Ruban.
- **Automation.** A `ruban://` URL scheme and a small `ruban` command-line tool.

## Install

Ruban needs macOS 14 or later on Apple silicon. Download `Ruban-x.y.z.zip` from the
[latest release](https://github.com/niz-coder/ruban/releases/latest), unzip it and move Ruban.app
to your Applications folder.

Ruban is not notarized by Apple, so macOS refuses the first launch. Open System Settings → Privacy &
Security, scroll down to the message about Ruban and click **Open Anyway**. This is needed once.

On first launch, macOS asks for the **Accessibility** permission, which is how any window manager
moves windows: System Settings → Privacy & Security → Accessibility → turn Ruban on. Ruban starts
tiling as soon as it is granted.

### Updates

Ruban looks for a new release on GitHub once a day, and when you choose *Chercher une mise à jour…*
in its menu. Installing one downloads it, checks that it is signed with the same certificate as your
copy, then quits Ruban, swaps the app and opens it again: your windows come back to their places.
The daily check is one request to `api.github.com`; turn it off in Settings → General.

### Build from source

With Xcode (or the Command Line Tools) for Swift 5.9+:

```bash
git clone https://github.com/niz-coder/ruban.git
cd ruban
./build.sh
```

`build.sh` compiles a release build, draws the icon, signs the app and copies it to
`~/Applications/Ruban.app`. It signs with a certificate named *Ruban* when your keychain has one
(the releases are signed with it), otherwise with your *Developer ID* or *Apple Development*
certificate, so the Accessibility permission survives rebuilds; without any, it signs ad hoc and you
will need to grant the permission again after each rebuild. A copy only accepts updates signed like
itself, so one you built with your own certificate does not update itself from the releases.

### Free the three-finger swipe

By default macOS uses three- or four-finger horizontal swipes to switch Spaces. Two apps reacting to
one swipe can leave macOS stuck halfway through a Space switch, so while macOS still uses the gesture,
Ruban leaves it alone, explains why once, and picks it back up as soon as it is free. Go to System Settings → Trackpad → More Gestures →
*Swipe between full-screen applications* and choose **four fingers** (or turn it off), or set Ruban
to four fingers instead. Ruban's *Mac Setup* tab points out this and other conflicts (Rectangle,
Magnet, AeroSpace, Stage Manager…).

## Shortcuts

All shortcuts use **⌃⌥** (Control-Option) by default; ⌃⌥⌘ is available in the settings. Letters follow
your keyboard layout, so on AZERTY ⌃⌥Q is the key printed Q.

| Shortcut | Action |
|---|---|
| ⌃⌥ ← → (or H L) | Focus the previous / next column |
| ⌃⌥⇧ ← → | Move the column left / right |
| ⌃⌥ ↑ ↓ (or K J) | Focus up / down in a stack |
| ⌃⌥⇧ ↑ ↓ | Move the window up / down in its stack |
| ⌃⌥⌘ ← → | First / last column |
| ⌃⌥ 1 … 9 | Jump to column 1–9 |
| ⌃⌥ R | Cycle preset widths |
| ⌃⌥ F | Full width, and back |
| ⌃⌥ C | Centre the column |
| ⌃⌥ = / - | Wider / narrower |
| ⌃⌥⇧ = / - | Taller / shorter in a stack |
| ⌃⌥ 0 | Equalize heights in a stack |
| ⌃⌥ ] / [ | Stack into the column on the left / right (the two keys right of P) |
| ⌃⌥⇧ ] / [ | Pop out of the stack to the right / left |
| ⌃⌥⇧ T | Toggle a tabbed column |
| ⌃⌥ T | Float / tile the focused window |
| ⌃⌥ P / ⌃⌥⇧ P | Pin to the left / right edge |
| ⌃⌥ N | Send to the next display |
| ⌃⌥ Q | Pause Ruban: every window comes back on screen, and ⌃⌥ Q again puts each one back in its place |

On the trackpad: three-finger horizontal swipe, or ⌃⌥ + two-finger scroll (also works with a mouse wheel).

## Command line and URL scheme

```bash
~/Applications/Ruban.app/Contents/Resources/ruban focus-right
open -g "ruban://cycle-width"
```

Every action above has a name: `focus-left`, `move-right`, `cycle-width`, `full-width`, `centre`,
`pin-left`, `stack-left`, `pop-right`, `toggle-tabbed`, `toggle-float`, `jump-3`, `toggle`,
`settings`… Run `ruban --help` for the full list.

## How it works

- `Sources/RubanCore` holds the strip model, the geometry and the swipe recogniser. It has no AppKit
  dependency and is covered by `swift test`.
- `Sources/Ruban` is the app: Accessibility observers to follow windows, Carbon hotkeys, an event
  tap for modifier + scroll, the trackpad reader, and the SwiftUI settings.
- Windows that scroll off screen are **parked** at the screen edge with a 1-point sliver visible:
  macOS pulls back a window placed entirely off screen to 40 points, but leaves a 1-point one alone.
  When another display touches that edge, the window goes to the far edge or down to a bottom
  corner instead, so it never hangs over the other display.
- Quitting or pausing brings the parked windows back on screen. A crash or a force quit cannot run
  any code, so Ruban starts a small guardian at launch (`Ruban --guard <pid>`, the same binary): when
  Ruban ends without having brought its windows back, the guardian does it, then exits.
- Scrolling is locked to the display's refresh rate, and a critically damped spring takes over from
  your fingers when you let go.
- The work that waits on other processes over and over stays off the main thread: window scans,
  window moves, title reads and notification sign-ups go to background queues. The scroll tap has
  a thread of its own and is only installed while it has something to do, so a busy app or window
  server can slow the strip down, not scrolling in other apps. Ruban also stops looking while the
  screen is locked, the screen saver runs or the displays sleep.

### Private APIs

Like yabai and AeroSpace, Ruban relies on a few private macOS interfaces, looked up at runtime so a
missing one degrades gracefully instead of crashing:

- `_AXUIElementGetWindow`, to map an Accessibility element to its window number;
- SkyLight (`_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `SLSManagedDisplayGetCurrentSpace`),
  to focus one specific window and to tell Spaces apart;
- MultitouchSupport, to read raw trackpad contacts, since macOS consumes multi-finger swipes
  before any app sees them;
- `responsibility_spawnattrs_setdisclaim`, so the guardian answers for its own Accessibility
  permission once Ruban, which started it, is gone.

No SIP changes and no code injection are needed, but a macOS update can break any of these. This
also means Ruban cannot ship on the Mac App Store.

## Development

```bash
swift test                                  # layout engine and swipe recogniser
swift build && .build/debug/Ruban           # run without installing
.build/debug/Ruban --snapshot /tmp/ruban    # render the settings, the indicator and the update window to PNG
scripts/release.sh 0.2.0 notes.md           # test, build, sign, zip and publish a release on GitHub
```

The engine log is at `~/Library/Logs/Ruban.log`.

## License

[MIT](LICENSE)
