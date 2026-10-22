# Seasonal appearance collection

One theme selection owns both appearances. Light, Dark and Auto only choose which
variant is displayed; changing mode never substitutes a different theme. Existing
Default, Spring, Winter and Christmas selections remain available.

| Theme | Light | Dark | Signature |
| --- | --- | --- | --- |
| Aurora | Opal white, icy jade and lilac; deep teal controls | Polar teal and indigo; mint controls and violet edges | Broad northern-light ribbons, winter and solstice |
| Ember | Warm porcelain, copper and dusty rose; terracotta controls | Espresso, aubergine and glowing apricot | An off-centre sunset with fine ceramic contours, autumn and Thanksgiving |
| Starlight | Champagne, pearl and amethyst; violet controls | Midnight violet, champagne controls and moonstone edges | Fine celestial orbits and fixed stars, holidays and New Year |

## Design references

- [Apple's Liquid Glass](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/): layered materials and an appearance that adapts coherently between light and dark.
- [Linear's UI redesign](https://linear.app/now/how-we-redesigned-the-linear-ui): shared color roles, clear surface hierarchy and checking whole sets of screens.
- [Material color roles](https://m3.material.io/styles/color/the-color-system/key-colors-tones): coordinated foreground/background pairs rather than isolated accent colors.
- [Fluent materials](https://fluent2.microsoft.design/material): mode-aware surfaces with different elevation and opacity for different purposes.

These are design principles, not copied screens or assets. The original app's native
navigation, typography, bubble shapes and familiar interaction patterns remain.

## App-wide contract

`AppTheme` supplies complete paired palettes to `ThemeSelection`, `Palette`,
`ReadingStyle`, `RimLook`, `LiquidGlass` and `MeshBackground`. Chats, the Fam room,
calls, settings and settings detail pages use those same roles. Native controls and
sheets resolve the same active scheme. The atmosphere is drawn centrally, without
per-page copies, downloaded artwork, particles or a new animation timer.

Surfaces, links, buttons, text, message gradients, card panels, attachment tiles,
profile placeholders, shadows and reaction scrims all follow the theme. Actual
photos, chosen contact rings, partner logos and semantic status colors retain their
meaning.

The atmosphere is one composited layer at at most 14% opacity, including overlaps.
Reduce Transparency and Increase Contrast remove this decoration. Reduce Motion
continues to disable the existing optional mesh drift. Text and links must maintain
4.5:1 contrast, rims 3:1, and message text 4.5:1 through the entire sent-message
gradient. Tests also check the atmospheric tint across interpolated page colors.

## Review coverage

The native screenshot collection includes each new theme in both appearances on
Chats, a direct conversation, the Fam room, calls, Settings, Appearance, the compact
preview and an accessibility variant. The appearance UI test selects all seven
themes in Light, Dark and Auto; settings tests verify persistence after relaunch.
