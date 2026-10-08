# Window Layout

How Window Layout's commands, drag areas, menus and settings file work. The user-facing summary is in the [README](../README.md#window-layout).

## Commands

Every placement is a `WindowCommand` (`Services/WindowLayout/WindowCommandModel.swift`):

- **Kind.** `area` (fill a rectangle of the display's grid), `maximize`, `marginMaximize`, `fullScreen`, `center`, `restore`, `nextDisplay`, `previousDisplay`, or `separator`.
- **Target.** For areas, a `GridRect` in whole grid cells measured from the top-left of the display's usable area. Targets are stored in grid cells, never points, so they survive resolution changes.
- **Shortcut**, optional, with its own on/off switch.
- **Activation area**, optional, with its own on/off switch (see below).
- **Visibility** in the menu-bar menu and in the green-button menu.
- **Name**, editable for commands you add; built-ins keep localised names.

Commands live in two sets, `horizontal` and `vertical` (`WindowCommandSetKind`). A display taller than it is wide uses the vertical set; every other display, square ones included, uses the horizontal set. The horizontal grid is 24 columns × 12 rows and the vertical grid is the same grid on its side, 12 × 24. Shortcuts, drags and both menus always use the set that matches the display of the window being acted on.

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

## Drag areas

An activation area is one of three shapes, all in the set's grid (`WindowActivationRegion`):

- **Edge span:** one screen edge plus a start and end along it, in columns for the top and bottom edges and rows for the sides. It fires within the edge width of that edge. The top edge also covers the menu bar, where a dragged title bar's pointer ends up.
- **Corner:** fires within the edge width of both edges.
- **Interior rectangle:** fires inside its rectangle, scaled around its centre by the inner-area scale.

When several areas hold the pointer, corners beat edges and edges beat interior areas. Between two of the same kind the smaller one wins, and list order breaks any remaining tie (`WindowActivationHitTest`).

Default areas never overlap. In the horizontal set the left and right edges take the halves, the top edge takes Maximize, the corners take the quarters, and the bottom edge is cut into five spans (left third, left two-thirds, center third, right two-thirds, right third), so sliding along it walks through them. In the vertical set the top and bottom edges take the halves, the left edge carries the five third and two-thirds spans, and Maximize moves to the right edge.

While a window is dragged over an area, an overlay previews the destination frame (`WindowLayoutOverlays.swift`). It has a style setting (automatic, light, dark or accent colour) and an outline width. Optionally every area lights up for the whole drag. When a window that Window Layout placed is dragged away from its placement, it returns to its size from before the placement.

## Geometry and spacing

`WindowCommandGeometry` turns a grid rectangle into a frame inside the display's visible frame. The screen margin is applied first, then half of the window margin is taken off every edge the area shares with a neighbouring area, which is the rule the built-in placements already followed. "Fit tightly to screen edges" drops the screen margin and keeps the window margin. Both margins are stored in the existing gap preferences. A window that cannot take the exact size stays pinned to the edges its area touches.

## Menus

- **Menu-bar menu** (`App/WindowLayoutMenuBarController.swift`): a separate status item listing the commands marked for it, with glyphs and shortcuts, then Settings, Ignore or Stop ignoring the app in front, Help (this README section), About and Quit. A command is greyed when it cannot change the focused window: no movable window, an ignored app, a display move with one display, nothing to restore, or a result equal to the current frame (`WindowCommandAvailability`).
- **Green-button menu** (`WindowGreenButtonService.swift`): the global mouse monitor only records that the pointer moved. A single timer waits until the pointer has rested for the hover delay, then asks Accessibility once what is under it, never faster than about 30 Hz. If that element is a window's zoom button, the menu of commands marked for it opens next to the button. Ignored apps and full-screen windows are skipped.
- **Glyphs** (`UI/WindowCommandGlyph.swift`) are drawn from each command's own target rectangle. macOS 27 hides menu item images unless an item asks to keep them, so command rows ask.

## Ignored apps

`windowLayoutIgnoredApps` holds bundle identifiers. Window Layout leaves these apps alone on every route: shortcuts, drags, the menu-bar menu and the green-button menu. Ignore is only offered for an ordinary app in front, never a system agent.

## Storage, migration and sync

- The command sets are stored as versioned JSON (`version`, `horizontal`, `vertical`) in the `windowLayoutCommands` preference (`WindowCommandPersistence.swift`). Each command stores its `kind`, its area `rect` as `[x, y, width, height]` in cells, its `shortcut`, `activation` (`{edge, start, end}`, `{corner}` or `{rect}`), `menuBar` and `greenButton` flags, and a `name` when it has one. Reading is lenient: a command of a kind a later version added is skipped instead of discarding the set, values outside the grid are pulled back in, and doubled or dangling separators are removed.
- **Migration:** on the first run of the command model, a shortcut you had changed under the earlier per-action preferences is carried into the matching command. Untouched shortcuts take the new defaults.
- **Settings file and sync folder** (`WindowLayoutSyncSupport.swift`, `WindowLayoutSyncController.swift`): Export and Import read and write one JSON file with every Window Layout preference. A sync folder keeps that file up to date; whichever side changed last wins, and a conflict, where both sides changed since the last sync, leaves a note in Settings. Real iCloud sync would need an Apple-issued profile that this self-signed app does not have, so syncing is a plain file and the folder's own client moves it between Macs. Nothing here touches the network, and `Tools/check-sealed.sh` enforces that.

## Defaults on upgrade

Shortcuts, drag snapping and the green-button menu stay off after updating. Settings shows a notice with a Quit button while another window manager is running, because two of them fight over the same shortcuts and drags.

| Setting | Default |
|---|---|
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

- `./build.sh --test` runs `Tests/WindowCommandTests.swift` with the rest of the suite: grid geometry with margins, set choice on mixed landscape and portrait displays, activation hit-testing and priority, persistence round trips and migration, shortcut conflicts and greyed states.
- Developer builds accept `--window-layout-preview general|commands[:name]|menu|green`, which opens that surface shortly after launch so it can be checked and captured without moving the pointer.
