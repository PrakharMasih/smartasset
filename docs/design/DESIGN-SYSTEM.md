# Design system

SmartAsset uses the native Mac look (plan §12.1). Only the accent color and a few tokens are its own.
Code: `Sources/SmartAsset/UI/`.

## Accent (bama:design-system)

- Default accent follows the Mac (`ThemeStore.defaultID = "system"`). People choose another in Settings ▸ General.
- Views use `.tint`, `Palette.accent`, `Palette.accentText`, `Palette.onAccent`. No hex values in views.

## Tokens

| Token | Value | Use |
| --- | --- | --- |
| `Space.xs/sm/md/lg/xl` | 4 / 8 / 12 / 16 / 20 pt | Every padding and gap (4 pt grid) |
| `Metrics.thumbMin / thumbMax / thumbDefault` | 96 / 320 / 160 pt | Grid cell width range (View ▸ Zoom) |
| `Metrics.cellGap` | 0 pt | Gap between grid cells. The tile's own 4 pt inset is the only space between pictures (8 pt), like a gallery |
| `Surface.content` | light `F3F3F6`, dark `141416` (+ high contrast) | Backdrop behind pictures (the grid, the Search page). Never behind text-only pages |
| `Surface.glow` | accent at 14 % fading out, from the top | The wash behind the Search field on the Search home. A mood, not a color block |
| `Radius.xs / sm / md / lg` | 4 / 8 / 12 / 16 pt | Badges / controls / pictures and the results field / the large Search field |
| `.fieldSurface(cornerRadius:)` | Liquid Glass on macOS 26+, tinted fill before | The Search field only: a floating control on the navigation layer |
| `Metrics.rowHeight` | 32 pt | List rows |
| `Motion.quick` | 0.12 s ease-out | Hover, selection feedback |
| `Motion.standard` | 0.20 s ease-in-out | Panels, inspector, filter bar |
| `Motion.none` | instant | When Reduce Motion is on |

## Rules in use

- Chrome stays system: sidebar, toolbar, inspector, menus, sheets. Glass is for controls and bars only; the thumbnail grid
  is content and gets none. Liquid Glass appears by itself on macOS 26; macOS 14 and 15 use the standard materials.
- Status uses an icon or a word, never color alone: offline = `externaldrive.badge.xmark`, missing = `questionmark.circle`,
  failed = `exclamationmark.triangle`.
- Color Labels are the only fixed colors, because their meaning is the color. They always come with a name in menus and VoiceOver.
- Text over thumbnails (duration, name) sits on a dark scrim capsule.
- Motion respects Reduce Motion (`Motion.none`).
- Thumbnails are never scaled up; a picture smaller than its tile shows at its size, centered. Larger ones crop to fill the square (View ▸ Crop Thumbnails to Squares, on by default) or fit whole (off).
- The grid is a gallery: whole columns that fill the row exactly (each at least the chosen size), so gaps match across and down. File names are off by default (View ▸ Show File Names; the tooltip and Inspector have them). The tile under the pointer lifts 2 pt.
- The one custom animation is the tile-to-Viewer zoom (`Viewer/ZoomTransition.swift`): 0.32 s, ease-out, a panel that is gone when it ends; skipped with Reduce Motion, and slowed 4× only in snapshot runs so it can be captured.
- Premium comes from restraint: a deeper backdrop for pictures, one large heading on the Search page (the only custom-sized type), glass on the one floating control, native chrome everywhere else.

## Checks

`tools/grid-lint.sh` for off-grid numbers, `APP_GRID=1` overlay, `tools/snap.sh` for light and dark snapshots of every page.
