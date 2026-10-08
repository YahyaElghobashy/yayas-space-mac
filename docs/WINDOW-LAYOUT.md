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

A window Window Layout placed, by any route (a shortcut, either menu, a built-in picker or a drag), returns to its size from before the placement as soon as a drag takes it away, with the pointer kept on the same spot of the title bar. A window resized by hand since the placement keeps its size. This works with drag snapping off: the drag listener runs while drag snapping has live areas, or while restoring is on and some placed window is remembered (`WindowDragTracking`). It starts with the first placement and stops when the last placed window is gone. With snapping off it follows only presses on a placed window, never changes the pointer events, and skips the preview, the overlays and the drop. macOS's own tiling only takes the drops, so restoring keeps working beside it.

## Geometry and spacing

`WindowCommandGeometry` turns a grid rectangle into a frame inside the display's visible frame. The screen margin is applied first, then half of the window margin is taken off every edge the area shares with a neighbouring area, which is the rule the built-in placements already followed. "Fit tightly to screen edges" drops the screen margin and keeps the window margin. Both margins are stored in the existing gap preferences. A window that cannot take the exact size stays pinned to the edges its area touches.

## Menus

- **Menu-bar menu** (`App/WindowLayoutMenuBarController.swift`): a separate status item, shown by default and hidden from General, listing the commands marked for it, with glyphs and shortcuts, then Settings (always the General tab), Ignore or Stop ignoring the app in front, Help (this README section), About and Quit. When the menu opens it looks up the front app's own window once, and its commands act on that window only; an app in front without a usable window never hands a command to another app. A command is greyed when it cannot change that window (`WindowCommandAvailability`): no window, an ignored app, a window that does not allow what the command changes (an area, a maximize or a display move needs it to resize as well as move; Center and Restore only to move; Full Screen the full-screen attribute), a display move with one display, nothing to restore, or a result equal to the current frame.
- **Green-button menu** (`WindowGreenButtonService.swift`): the global mouse monitor only records that the pointer moved, and the hover delay is read again only when its preference changes. A single timer waits until the pointer has rested for the hover delay, then, never faster than about 30 Hz, asks the window server which ordinary window is in front under the pointer. Only when the pointer rests in that window's traffic-light corner, and the app is not ignored, is Accessibility asked what is under it; if that is the window's zoom button, the menu of commands marked for it opens for that window. Full-screen windows are skipped.
- **Placement beside the system's menu.** macOS opens its own menu under the green button after a moment. Its real size cannot be read ahead of time, so Window Layout assumes a generous 272 × 340 pt footprint under the button and opens its menu to the right of that footprint, to the left of the window when there is no room, or above the button as a last resort (`WindowGreenButtonMenuPlacement`). The menu closes 0.45 s after the pointer leaves the menu, the button and the corridor between them; the corridor counts as inside, so crossing it, even over the system's menu, never closes the menu on the way. Resting deeper inside the system's menu still lets it close.
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
- **Settings file and sync folder** (`WindowLayoutSyncSupport.swift`, `WindowLayoutSyncController.swift`): Export and Import read and write one JSON file with every Window Layout preference. The file is always called `Yayas Space Window Layout.json`, in every language. A sync folder keeps that file up to date; whichever side changed last wins. This Mac's side is the real time of its last change, 0 when nothing was ever changed here, so an untouched setup never outranks a file someone changed. A conflict, where both sides changed since a sync this Mac already made with the folder, leaves a note in Settings; a fresh Mac or a folder just chosen has no such sync and gets no note. Changes are noticed by observing only the synced preferences and the command sets, settled for half a second, and reach the folder a second later.
- **File work off the main thread.** Every read and write of the sync folder, Export and Import runs on one serial background queue; only applying the preferences a file brings hops back to the main thread. The first folder sync waits a few seconds after the feature starts and never runs inside a preference sync. Before reading, the file system is asked, without opening the file, whether it is a cloud placeholder or a ubiquitous item whose download status is not current; such a file is skipped with "Waiting for the sync file to download" in Settings and looked at again every 30 seconds, up to 20 times. Sync Now, a change or the next launch start over. A file this app could not read is never overwritten.
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
| Restore size after dragging away | on |
| Light up every area while dragging | off |
| Fit tightly to screen edges | off |
| Window and screen margins | 0 pt |

## Checking it

- `./build.sh --test` runs `Tests/WindowCommandTests.swift` with the rest of the suite: grid geometry with margins, set choice on mixed landscape and portrait displays, activation hit-testing and priority, persistence round trips, separator clean-up and migration (shortcuts and margins), shortcut conflicts, greyed states and the capability each command needs, repeat rules by origin, picker routing and printed shortcuts, the drag listener's gate, the green-button corridor, names and VoiceOver descriptions, edge spans kept off corners, and the sync decision, file name, readiness and observed keys.
- Developer builds accept `--window-layout-preview general|commands[:name]|menu|green`, which opens that surface shortly after launch so it can be checked and captured without moving the pointer.
