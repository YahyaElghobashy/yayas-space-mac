# Window Layout

How Window Layout's commands, drag areas, menus and settings file work. The user-facing summary is in the [README](../README.md#window-layout).

## Commands

Every placement is a `WindowCommand` (`Services/WindowLayout/WindowCommandModel.swift`):

- **Kind.** `area` (fill a rectangle of the display's grid), `maximize`, `marginMaximize`, `fullScreen`, `center`, `restore`, `nextDisplay`, `previousDisplay`, or `separator`.
- **Target.** For areas, a `GridRect` in whole grid cells measured from the top-left of the display's usable area. Targets are stored in grid cells, never points, so they survive resolution changes.
- **Shortcut**, optional, with its own on/off switch.
- **Activation area**, optional, with its own on/off switch (see below).
- **Visibility** in the menu-bar menu and in the green-button menu.
- **Name**, editable for every command, built-ins included. Clearing a built-in's name brings back its own localised one.

Commands live in two sets, `horizontal` and `vertical` (`WindowCommandSetKind`). A display taller than it is wide uses the vertical set; every other display, square ones included, uses the horizontal set. The horizontal grid is 24 columns × 12 rows and the vertical grid is the same grid on its side, 12 × 24. Shortcuts, drags and both menus always use the set that matches the display of the window being acted on.

Every edit (add, remove, move, reset, import) leaves a set exactly as a later launch reads it back: unique ids and no doubled, leading or trailing separators. Emptying a group takes its spare separator with it; a separator is never moved to an end of the list or beside another one, and the + menu puts a new one after the selected command, or before it when after would divide nothing.

### Defaults

`WindowCommandDefaults.swift` holds both default sets and their shortcuts. Both sets share the same keys, so a key does the same kind of thing on either display shape.

| Group | Horizontal set | Vertical set | Shortcuts |
|---|---|---|---|
| Halves | Left, Right, Top, Bottom | same | ⌃⌥← → ↑ ↓ |
| Quarters | Top Left, Top Right, Bottom Left, Bottom Right | same | ⌃⌥U I J K |
| Thirds | Left, Center, Right Third | Top, Center, Bottom Third | ⌃⌥D F G |
| Two-thirds | Left, Center, Right Two Thirds | Top, Center, Bottom Two Thirds | ⌃⌥E R T |
| Displays | Next Display, Previous Display | same | ⌃⌥⌘→ ⌃⌥⌘← |
| Other | Maximize, Center, Restore | same | ⌃⌥↩ C ⌫ |

Separators divide the groups. Restore moved from ⌃⌥R to ⌃⌥⌫ in 1.1.0 so that R takes the middle two-thirds. The remaining built-ins (six sixths, the centred half, full screen, maximize with a margin) are offered in the + menu and keep working in the radial menu, the menu-panel grid and the gestures.

### Names

A placement has one name everywhere: the Commands tab, both menus, the main-panel grid, the radial menu and the command bar all use the command names (`WindowCommandStrings.builtinName`). The portrait set calls its middle row Center Third and Center Two Thirds, as the landscape set calls its middle column. Lists that hold every built-in at once (the radial menu, the command bar) add the set's name only where two built-ins would otherwise read the same, so the portrait ones show as "Center Third (Vertical)" and "Center Two Thirds (Vertical)" there (`WindowCommandStrings.listName`). The command bar still finds the earlier short titles such as "Left 1/3".

## Drag areas

An activation area is one of three shapes, all in the set's grid (`WindowActivationRegion`):

- **Edge span:** one screen edge plus a start and end along it, in columns for the top and bottom edges and rows for the sides. It fires within the edge width of that edge. The top edge also covers the menu bar, where a dragged title bar's pointer ends up.
- **Corner:** reaches one grid cell along both of its edges and fires within the edge width of each. Those two cells belong to the corner: the drag-area editor never lets an edge span cover them, and draws a corner together with them.
- **Interior rectangle:** fires inside its rectangle, scaled around its centre by the inner-area scale.

When several areas hold the pointer, corners beat edges and edges beat interior areas. Between two of the same kind the smaller one wins, and list order breaks any remaining tie (`WindowActivationHitTest`).

Default areas never overlap. In the horizontal set the left and right edges take the halves, the top edge takes Maximize, the corners take the quarters, and the bottom edge is cut into five spans (left third, left two-thirds, center third, right two-thirds, right third), so sliding along it walks through them. The vertical set mirrors that on its side: the top and bottom edges take the halves, one side edge (the left) carries the five third and two-thirds spans, and the other side edge (the right) takes Maximize, the way the bottom edge carries them and the top takes Maximize on a landscape display.

While a window is dragged over an area, the drop preview (`WindowEdgeSnapPreviewView` in `WindowLayoutService.swift`) shows where it will land. It has a style setting (automatic, light, dark or accent colour) and an outline width. Optionally every area lights up for the whole drag; that layer is `WindowLayoutOverlays.swift`.

A confirmed drag reads the displays, the area settings, the command sets and the margins once. Every step is sampled at 30 Hz (a release always samples), the areas are hit-tested first without Accessibility, and the dragged window's frame is read through Accessibility only when the area under the pointer changes to one whose preview depends on the window (Center, Restore and the display moves), then at the same 30 Hz while it does.

### Restore to original size

A window Window Layout placed, by any route (a shortcut, either menu, a built-in picker or a drag), returns to its size from before the placement as soon as a drag takes it away, with the pointer kept on the same spot of the title bar. A window resized by hand since the placement keeps its size. This works with drag snapping off.

Drags are followed by one of two listeners (`WindowDragTracking.listener`), never both:

- **Active**, an event tap, only while drag snapping has live areas and macOS's own tiling is off, because only a drop needs to sit in the input path (it keeps a confirmed window drag off the edge that opens the system's window overview). It follows every press, as before, and gives a placed window its size back on the way.
- **Passive**, a global `NSEvent` monitor for the left button, while only restoring has work: restoring is on and some placed window is remembered. It watches copies of the events on their way to other apps and can never hold, change or delay one. A press away from every placed frame (with a 24 pt slack) is dropped at once, before the window server is asked anything; only a press there goes on to the window-server hit test. It never shows the preview or the overlays and never drops.

The placed windows live in `WindowPlacements`. A window leaves it as soon as it is no longer where it was placed: when a drag takes it away (its size back or not), when Restore puts it back, or when the window server shows it closed, moved or resized some other way. That last check asks the window server about the remembered windows only, on a press, at most every 5 seconds, never from a timer. The passive monitor starts with the first placement and is removed with the last one, and also when restoring is turned off, the feature is turned off or Window Layout is suspended. A switch between the two listeners asked for during a drag waits until that press ends.

macOS's own tiling switches are cached: they are read again when Window Layout's settings change, when an app becomes active while drops could place (leaving System Settings is one), and before a drop places a window, never on a click. macOS's tiling only takes the drops, so restoring keeps working beside it.

**Looks of the drag areas and the preview.** Lit-up drag areas draw in the accent colour or a colour the user picks (`windowLayoutAreaStyle` automatic/custom, `windowLayoutAreaColor`), with an outline of 0 to 8 pt (`windowLayoutAreaBorderWidth`, default 1; the area under the pointer gets a point more; 0 draws none). The preview's styles are system, light, dark, inverse (the material in the look opposite the app's own effective appearance), accent and custom (`windowLayoutPreviewColor`). Colours are stored as `#RRGGBB` text (`WindowLayoutColor`) so they sync; an empty one means the accent colour.

**Who owns a drag area.** Within a set, two regions claim the same part of the screen when they are the same corner, spans of one edge that share a unit, or inner rectangles that share a cell (`WindowActivationRegion.sharesArea`); regions of different kinds never do, the priority settles them. Drawing an area that claims part of another command's asks first, naming the owners; on Move, each owner keeps `remainder(after:)`: the longer leftover of an edge span (the earlier one on a tie), the largest leftover band of an inner rectangle, nothing of a corner. An owner left with nothing loses its drag area.

**Apps Window Layout cannot arrange.** Where Magnet shows an app it does not support, the menu-bar menu replaces the Ignore item with a greyed "“App” can’t be arranged" line (`WindowLayoutFrontAppState`): the window it would act on cannot move, resize or go full screen, or the window server shows the app's ordinary windows (on screen, level 0, at least 40 pt each way) while Accessibility offers none Window Layout can use. Magnet decides this from a built-in list of old apps; Window Layout asks the windows themselves. An app with no window open keeps its Ignore item, and an ignored app always offers Stop Ignoring.

**Reset.** Reset Everything, Reset Commands Only (both sets back to defaults: placements, shortcuts, drag areas) or Reset Settings Only (every other preference on the two tabs, `WindowLayoutSettingsActions.resettableKeys`).

**Taking macOS's drag tiling over, the way Magnet does.** Only the two switches a plain drag runs into count against snapping: `EnableTilingByEdgeDrag` and `EnableTopTilingByEdgeDrag` in `com.apple.WindowManager` (a switch never written is on). Holding Option to tile (`EnableTilingOptionAccelerator`) is the user asking for macOS on purpose: it is never touched, and while Option is held during a drag, snapping hides its preview and leaves the drop to macOS. While snapping can run (feature on, Accessibility granted, snapping on, at least one live drag area), `WindowSystemTiling` switches both drag switches off, having first remembered what it found (`windowLayoutSystemTilingSaved`, `…Written`; machine-only, never registered or exported). When snapping stops (switched off, no live areas, Accessibility gone, quitting) the values found go back, unless someone changed a switch in the meantime; that change stands, and the values left in place are remembered (`…HandedBack`). If macOS's tiling is switched back on behind snapping's back, either while it runs or while Yaya's Space was not running, nothing is changed silently: Yaya's Space asks once whether to keep Window Layout snapping (tiling goes off again, and the user's latest choice is what comes back later) or to switch to macOS tiling (snapping goes off and macOS's tiling stays). The rules are pure and tested (`WindowSystemTilingTakeover`).

## Geometry and spacing

`WindowCommandGeometry` turns a grid rectangle into a frame inside the display's visible frame. The screen margin is applied first, then half of the window margin is taken off every edge the area shares with a neighbouring area, which is the rule the built-in placements already followed. "Fit tightly to screen edges" drops the screen margin and keeps the window margin. Both margins are stored in the existing gap preferences. A window that cannot take the exact size stays pinned to the edges its area touches.

## Menus

- **Menu-bar menu** (`App/WindowLayoutMenuBarController.swift`): a separate status item, shown by default and hidden from General, listing the commands marked for it, with glyphs and shortcuts, then Settings (always the General tab), Ignore or Stop ignoring the app in front, Help (this README section), About and Quit. When the menu opens it looks up the front app's own window once, and its commands act on that window only; an app in front without a usable window never hands a command to another app. A command is greyed when it cannot change that window (`WindowCommandAvailability`): no window, an ignored app, a window that does not allow what the command changes (an area, a maximize or a display move needs it to resize as well as move; Center and Restore only to move; Full Screen the full-screen attribute), a display move with one display, nothing to restore, or a result equal to the current frame.
- **Green-button menu** (`WindowGreenButtonService.swift`): the global mouse monitor only records that the pointer moved, and the hover delay is read again only when its preference changes. A single timer waits until the pointer has rested for the hover delay, then, never faster than about 30 Hz, asks the window server which ordinary window is in front under the pointer. Only when the pointer rests in that window's traffic-light corner, and the app is not ignored, is Accessibility asked what is under it; if that is the window's zoom button, the menu of commands marked for it opens for that window. Full-screen windows are skipped.
- **Three layouts.** A list (glyph, name and shortcut per row), a compact grid (glyphs only; each group starts a row of up to five) and a horizontal row (glyphs only, every command in one row, groups set apart by upright hairlines with 6 pt either side). The two glyph layouts name the command under the pointer in a caption underneath. Sizes come from `WindowGreenButtonMenuGeometry`; a row wider than the screen scrolls sideways.
- **Hanging from the button; the system's menu waits for a key.** The menu hangs from the green button where macOS opens its own menu: its left edge 26 pt left of the button's middle and an arrow whose tip sits 1 pt under the button. It stays on screen; the arrow follows the button as far as the rounded corners allow, the menu opens above the button when only that fits, and a menu taller than the room scrolls on the roomier side (`WindowGreenButtonMenuPlacement.layout`). While the menu runs, macOS's own green-button menu shows only while Control (or Command, in Settings) is held, and resting on the button with that key held leaves it to macOS. This uses AppKit's own global preference `NSZoomButtonMenuOption`, which every app reads on each hover (0 shows the system menu as usual, 1 never, 2 with Command, 3 with Control); Window Layout writes 3 or 2 when the menu starts and puts back what it found when the menu stops, by being switched off, losing Accessibility or quitting (`WindowSystemZoomMenu`, rules in `WindowSystemZoomMenuPreference`). What it found is remembered on this Mac only (`windowLayoutSystemZoomMenuSaved`, `windowLayoutSystemZoomMenuWritten`, never exported) before anything is written, and a value someone else wrote in the meantime is left in place. The menu closes 0.45 s after the pointer leaves the menu, the button and the corridor between them.
- **Pointer, VoiceOver and the keyboard in the green-button menu.** The menu never takes the keyboard: its panel cannot become the key window, is shown with `orderFrontRegardless()` only and never activates Yaya's Space, so the app in front keeps every keystroke, with the pointer over the menu or not. Commands are picked with the pointer. Escape closes the menu through key monitors that only watch (a global one, plus a local one for when Yaya's Space itself is the app in front), so the key still reaches the app in front. VoiceOver sees a group named Window Layout with one button per command, each with its name, its shortcut, its enabled state and a press action, which works without keyboard focus. Moving through the menu with the arrow keys and Return is left for a later version.
- **Repeat rules.** Only shortcuts and the built-in pickers repeat: Left or Right twice crosses to the display beside, Top twice maximizes. A command chosen from either menu, or tried from Settings, does exactly what it names every time (`WindowCommandOrigin`).
- **Glyphs** (`UI/WindowCommandGlyph.swift`) are drawn from each command's own target rectangle. macOS 27 hides menu item images unless an item asks to keep them, so command rows ask. The status item's own mark is drawn in the same language: a small screen outline with its left two-thirds filled.

## Built-in pickers and shortcuts

The main-panel grid, the radial menu and the command bar list the built-ins. Picking one runs the user's command for that built-in from the set of the display the window is on, so an edited area, a renamed command or a new shortcut is what runs; only a set without that built-in runs it as shipped (`WindowCommandRouting`). The shortcut they print next to a built-in is that command's, shown only when every connected kind of display agrees on it.

A shortcut looks its window up once and takes the command set from that same window's display. A window that cannot take the command (a fixed-size one, for a placement that resizes) is passed over for the next candidate, as every placement always did; a combination only the other set uses does nothing.

## Ignored apps

`windowLayoutIgnoredApps` holds bundle identifiers. Window Layout leaves these apps alone on every route: shortcuts, drags and restoring their size, the menu-bar menu, the green-button menu, the main-panel grid, the radial menu, the command bar, the directional gesture and the modifier move and resize gesture. Ignore is only offered for an ordinary app in front, never a system agent.

## Storage, migration and sync

- The command sets are stored as versioned JSON (`version`, `horizontal`, `vertical`) in the `windowLayoutCommands` preference (`WindowCommandPersistence.swift`). Each command stores its `kind`, its area `rect` as `[x, y, width, height]` in cells, its `shortcut`, `activation` (`{edge, start, end}`, `{corner}` or `{rect}`), `menuBar` and `greenButton` flags, and a `name` when it has one. Reading is lenient: a command of a kind a later version added is skipped instead of discarding the set, values outside the grid are pulled back in, and doubled or dangling separators are removed.
- **Migration:** on the first run of the command model, a shortcut you had changed under the earlier per-action preferences is carried into the matching command. Untouched shortcuts take the new defaults. The earlier window gap and screen gap become one margin: the window gap when it is set, else the screen gap, with "fit tightly" on when the screen gap was zero beside a window gap. Both gaps are then stored to match, so the margin Settings shows is the one windows get.
- **Choosing a folder that already holds settings.** Before a newly chosen folder is used, the app checks for the settings file there (a stat, no read) and asks whether to use the folder's settings or keep this Mac's (Cancel keeps the old folder). The answer goes into the first sync as `FirstSyncChoice` and overrides last-writer-wins for that one sync (`WindowLayoutSyncSupport.decide(…, choice:)`); a missing file still means writing this Mac's. The choice is used once and forgotten when a sync settles, or when the folder changes.
- **Settings file and sync folder** (`WindowLayoutSyncSupport.swift`, `WindowLayoutSyncController.swift`): Export and Import read and write one JSON file with every Window Layout preference. The file is always called `Yayas Space Window Layout.json`, in every language. A sync folder keeps that file up to date; whichever side changed last wins. This Mac's side is the real time of its last change, 0 when nothing was ever changed here, so an untouched setup never outranks a file someone changed. A conflict, where both sides changed since a sync this Mac already made with the folder, leaves a note in Settings; a fresh Mac or a folder just chosen has no such sync and gets no note. Changes are noticed by observing only the synced preferences and the command sets, settled for half a second, and reach the folder a second later.
- **File work off the main thread.** Every read and write of the sync folder, Export and Import runs on one serial background queue; only applying the preferences a file brings hops back to the main thread. The first folder sync waits a few seconds after the feature starts and never runs inside a preference sync. Before reading, the file system is asked, without opening the file, whether it is a cloud placeholder or a ubiquitous item whose download status is not current. Such a file is never waited for: the background queue asks the system to fetch it (`FileManager.startDownloadingUbiquitousItem(at:)`; the folder's own client, such as iCloud Drive or Dropbox, does the download, and this app adds no network code), Settings shows "Waiting for the sync file to download to this Mac", and the file is looked at again every 30 seconds, up to 20 times. If it has still not arrived after the last look, Settings says plainly that syncing stopped trying and that Sync Now tries again. Sync Now, a change or the next launch start over. A file this app could not read is never overwritten.
- Real iCloud sync would need an Apple-issued profile that this self-signed app does not have, so syncing is a plain file and the folder's own client moves it between Macs. Nothing here touches the network, and `Tools/check-sealed.sh` enforces that.

## Defaults on upgrade

Shortcuts, drag snapping and the green-button menu stay off after updating. The menu-bar icon is shown: its commands act only when one is clicked, so it never competes with another window manager. Settings shows a notice with a Quit button while another window manager is running, because two of them fight over the same shortcuts and drags.

| Setting | Default |
|---|---|
| Window Layout menu-bar icon | shown |
| Edge width | 8 pt |
| Inner-area scale | 80 % |
| Preview outline | 2 pt |
| Green-button hover delay | 100 ms |
| Green-button menu layout | list |
| Key that shows the macOS green-button menu | Control |
| Restore size after dragging away | on |
| Light up every area while dragging | off |
| Fit tightly to screen edges | off |
| Window and screen margins | 0 pt |

## Checking it

- `./build.sh --test` runs `Tests/WindowCommandTests.swift` with the rest of the suite: grid geometry with margins, set choice on mixed landscape and portrait displays, activation hit-testing and priority, persistence round trips, separator clean-up and migration (shortcuts and margins), shortcut conflicts, greyed states and the capability each command needs, repeat rules by origin, picker routing and printed shortcuts, the drag listener's gate and its passive or active choice, the placed-window rules (kept first size, forgotten when dragged away, closed, moved or resized), the green-button corridor, names and VoiceOver descriptions, edge spans kept off corners, and the sync decision, file name, readiness and observed keys.
- Developer builds accept `--window-layout-preview general|commands[:name]|menu|green`, which opens that surface shortly after launch so it can be checked and captured without moving the pointer.
