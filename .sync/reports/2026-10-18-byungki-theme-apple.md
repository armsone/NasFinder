# Byungki Style Theme Implementation Report (Apple/iOS/macOS)

- Date: 2026-10-19T00:01:00+09:00
- Task Scope: 병기스타일 테마 (Byungki Style Theme - 6 palettes, fixed order, exact SVG 24x24 geometry, tap cycle, 500ms longpress selection list, persistence mapping)
- Version Bump: 2.18.0 -> 2.19.0 (Build monotonic timestamp: 202610190000)
- Execution Mode: Native file tools only (--file-only), zero shell command execution, zero tests/builds run.

## 1. Summary of Changes

### 1) Palette & Preference Mapping (`NasFinder/App/SkyBreezeTheme.swift`)
- `AppThemePreference`:
  - Exactly 6 themes in order: `light` (밝은), `bkstyle` raw="medium" (중간), `night` raw="dark" (어두운), `jarvis` (자비스), `friday` (프라이데이), `ultron` (울트론).
  - Short descriptions and titles updated to reference contract.
  - Friday configured as light amber theme (`isDark` = false).
  - Legacy mapping: `resolved(_:)` maps `"night"` -> `.night` (dark), `"bkstyle"` -> `.bkstyle` (medium) without overwriting stored values on read.
  - Palettes updated to exact WCAG-aligned hex tokens from reference:
    - `light`: bg `#F5F4F0`, card `#FBFAF7`, surface `#FFFFFF`, surface2 `#ECEBE4`, text `#1F211C`, text2 `#4A4C44`, border `#E2DFD5`, accent `#5C6B3C`, danger `#9C3B2A`, onAccent `#FFFFFF`.
    - `medium`: bg `#D9D3C7`, card `#E6E1D6`, surface `#ECE8DF`, surface2 `#CFC8BA`, text `#1F211C`, text2 `#3A3A34`, border `#BDB6A7`, accent `#46532C`, danger `#8A2F1F`, onAccent `#FFFFFF`.
    - `dark`: bg `#1C1C1A`, card `#242422`, surface `#262622`, surface2 `#2E2E29`, text `#E9E7DF`, text2 `#C2BFB3`, border `#35342E`, accent `#93B163`, danger `#E08674`, onAccent `#14180D`.
    - `jarvis`: bg `#0C1420`, card `#121C2B`, surface `#162337`, surface2 `#1C2D44`, text `#E3EDF7`, text2 `#B3C4D6`, border `#20324A`, accent `#4CC2E6`, danger `#F28B82`, onAccent `#04202B`.
    - `friday`: bg `#F7EFE3`, card `#FFFAF1`, surface `#FFFDF8`, surface2 `#F0E2CC`, text `#2A1F16`, text2 `#55422F`, border `#E8D8C0`, accent `#9A4A12`, danger `#A3204A`, onAccent `#FFFFFF`.
    - `ultron`: bg `#121316`, card `#1A1C20`, surface `#202328`, surface2 `#272A30`, text `#E6E7EA`, text2 `#B8BBC2`, border `#2B2E34`, accent `#F2566A`, danger `#FF9A9A`, onAccent `#1A0508`.

### 2) Exact Native Vector Glyphs (`NasFinder/App/SkyBreezeTheme.swift`)
- `ByungkiThemeGlyph`:
  - Implemented with native SwiftUI `Canvas` and vector `Path` API with zero external dependencies.
  - Exactly reproduces the 24x24 viewBox SVG shapes with stroke 1.7 round, tinting with theme accent or custom foreground tint:
    - `light`: center circle (r=3.8) and 8 radial rays.
    - `medium`: circle (r=8) with right half filled.
    - `dark`: crescent moon path (M19.5 14.6...).
    - `jarvis`: outer dashed circle (dash [15.4, 3.45], rotated -80°), mid ring (stroke 1.4), center dot (r=1.7).
    - `friday`: hexagon outline, center filled circle (r=3), cross lines (stroke 1.4).
    - `ultron`: stylized helmet/mask outline, angular eye cutouts, mouth line (stroke 1.4).

### 3) Common Control Behavior (`NasFinder/App/SkyBreezeTheme.swift`, `ConnectionListView.swift`)
- `ByungkiThemeControlButton`:
  - Replaces both `currentThemeBadge` and `porcelainTrailingItems` theme buttons.
  - Short tap/click cycles to next theme in fixed 6-theme cycle.
  - 500ms `LongPressGesture` (max distance 10px) presents 6-entry selectable dialog titled "병기스타일 테마" with currently selected item marked.
  - Native `contextMenu` also provided for secondary click / long press accessibility.
  - Releasing longpress does not trigger cycle.
  - Accessibility label format: `병기스타일 테마: {현재} (누르면 {다음}, 길게 누르면 목록)`.

### 4) Settings Integration (`NasFinder/Features/Settings/AppSettingsView.swift`)
- Section header updated to "병기스타일 테마".
- Theme cards render exact vector glyphs via `ByungkiThemeGlyph` instead of SF Symbols.
- Existing icon pack (`InterfaceIconStyle`) and launcher app icon picker remain strictly independent and are preserved without reset.

### 5) Product Version Bump
- `NasFinder.xcodeproj/project.pbxproj`:
  - `MARKETING_VERSION` updated from `2.18.0` to `2.19.0` across all 6 targets (`NasFinder`, `NasFinderFileProvider`, `NasFinderTests`, `NasFinderShare`, `NasFinderWidget`, `NasFinderDocumentPicker`).
  - `CURRENT_PROJECT_VERSION` bumped to monotonic code `202610190000`.
- `NasFinder/Info.plist`: references `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` dynamically.

### 6) Contract & Parity Ledger
- `.sync/product-contract.yaml`: updated `settings.theme_icons_awake` specification to describe Byungki 6-theme palette, fixed order, vector glyphs, and tap/longpress gestures.
- `.parity/ledger.json`: created with 6 source-only entries (`theme.palettes.six`, `theme.order.fixed`, `theme.icons.svg_geometry`, `theme.interaction.tap_cycle`, `theme.interaction.longpress_menu`, `theme.persistence.mapping`), all marked `matched: false` pending dual-platform runtime verification.

## 2. Integrity and Syntax Check
- All edited Swift and project files reviewed via read tools.
- Types, initializers, parameter names, and delimiters verified:
  - `AppThemePreference` cases and `palette` mapping syntax sound.
  - `ByungkiThemeGlyph` Canvas drawing logic self-contained.
  - `ByungkiThemeControlButton` gesture and sheet/contextMenu bindings matched.
  - No new Xcode build phases or unreferenced files introduced.
- Strict confirmation: No compilers, tests, or build commands were executed. All changes are uncompiled drafts verified by source inspection.

## 3. Handoff for Execution Specialist
When both Apple and Android implementation branches are complete and shared build resources are released, the execution specialist can verify compile and build with:
```bash
./scripts/xcodebuild_project.sh -scheme NasFinder -configuration Debug -destination 'generic/platform=iOS' build
```
Do not execute now as per headless task restrictions.
