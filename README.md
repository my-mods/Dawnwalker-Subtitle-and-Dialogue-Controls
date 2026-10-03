# UI and Subtitles - Configurable Font and Text Size

Adjust cinematic subtitles, dialogue choices, gameplay subtitles and supported interface labels independently in The Blood of Dawnwalker. Choose the vanilla Afacad font or Alegreya separately for subtitles/dialogue and other UI text.

| Setting | Default | Range |
| --- | --- | --- |
| Enabled | On | Off / On |
| Cinematic subtitle size | 75% | 25-200% |
| Dialogue choice size | 100% | 25-200% |
| Gameplay subtitle size | 100% | 25-200% |
| Subtitle and dialogue font | Alegreya | Vanilla (Afacad) / Alegreya |
| Other UI text size | 100% | 25-200% |
| Other UI font | Keep current | Keep current / Vanilla (Afacad) / Alegreya |
| Logging | Off | Off / On |

Sizes are percentages of the original text style or widget size, including any text style supplied by another mod. At 100%, the original size is retained. Cinematic size covers spoken lines, speaker names and movie subtitles. Dialogue choice size covers response choices and their quantity labels. Gameplay size covers bottom-screen lines, accessibility lines and overhead NPC subtitles. Distance scaling and dialogue effects remain controlled by the game. Extremely large text may exceed the game's layout space.

Other UI controls cover main-menu and title-screen text, settings, inventory names and descriptions, item tooltips, stats, the glossary, court, crafting, character development and the journal. UI styles and widget defaults are prepared at game startup, save loading and settings changes. Opening a menu inherits those defaults without running another scaling pass. Shared UI styles also affect other labels that use them. Rich-text body text is supported; separately authored spans and inline icons can retain their own formatting. Graphical lettering is unchanged. These controls do not resize entire panels or rearrange layouts.

The two font selectors are independent. Other UI starts at 100% with Keep current, preserving its existing font. Both font families are included under unique asset paths, so Alternative Font - Alegreya can remain enabled for the rest of the interface. It is not required by this mod. Language-specific fallback faces continue to come from the game.

## Dependencies

Requires UE4SS with Lua 5.4, native UFunction hooks and delayed game-thread callbacks, such as Vercadi UE4SS RC6 or Framecore UE4SS 2b. Persistent UI defaults also require StaticConstructObject and reflected object arrays. NotifyOnNewObject retains existing labels for the next Apply; it does not apply settings when menus open. Blueprint execution hooks are not required. Dawnwalker Mod Menu 1.0.6 or later is optional for the in-game controls and live Apply; its console bridge requires HookProcessConsoleExec to be enabled in UE4SS.

## Installation

- Vortex: Install UI-and-Subtitles-Configurable-Font-and-Text-Size.zip through Vortex, enable it and deploy.
- Manual: Copy the archive's Dawnwalker folder into your The Blood of Dawnwalker installation directory, preserving the folder structure.

## Configuration

Open Mod Settings, select UI and Subtitles - Configurable Font and Text Size, change the values and choose Apply. UI defaults and existing labels update progressively after startup, save loading or Apply; a large screen may take a few seconds. Subsequent menu openings inherit the prepared defaults. Independent subtitle controls still respond when the game creates or restyles spoken lines. Turning Enabled off restores font and size values still controlled by this mod. Reset restores the defaults above.

Without Mod Settings, launch the game once to create `Dawnwalker/Binaries/Win64/ue4ss/Mods/UIAndSubtitles/settings.ini`. Close the game before editing its `[Settings]` section and restart afterward. `subtitlePercent`, `dialoguePercent`, `gameplayPercent` and `uiPercent` accept whole numbers from 25 to 200. `fontFamily = 0` selects vanilla Afacad; `fontFamily = 1` selects Alegreya. `uiFontFamily` uses the same values, plus 2 for Keep current. `enabled` and `debugLogging` use 0 for Off and 1 for On. At startup, an older valid preferences file receives only the missing UI keys with their defaults. Its previous contents are retained in `settings.ini.before-ui-controls`; existing values, comments and other sections are preserved. If a previous upgrade backup or temporary file needs attention, the log reports it instead of overwriting it. The archive does not contain an active settings.ini.

Turn Logging on to record UI preparation reasons, style/template counts, writes, operation timings, subtitle update counts and font-load timings in `Dawnwalker/Binaries/Win64/ue4ss/UE4SS.log`. Essential capability failures are reported once even with Logging off. Selected fonts load during startup or settings changes and are retained for the session. If a font package cannot load, size controls continue using the available font.

## Credits

Alegreya by the Alegreya Project Authors and Afacad by the Afacad Project Authors, under the SIL Open Font License 1.1; licenses are included. Alegreya is built from the Google Fonts distribution. The vanilla Afacad faces retain the game's original 1.000 font data. Font package templates retain the game's fallback-language references.

The font choice was inspired by WinterElfeas's [Alternative Font - Alegreya](https://www.nexusmods.com/thebloodofdawnwalker/mods/217); this mod does not redistribute that Nexus archive. Settings storage and validation use the MIT-licensed ue4ss-common helpers. The Mod Menu integration helper is included unchanged from its integration guide. Original game asset metadata belongs to its respective owners. The Lua code is MIT-licensed.

## Source layout

`src` contains the runtime and settings integration. `assets` contains editable font package templates and the licensed font faces. `package` contains installer metadata and the cooked font containers. Convert the font templates with UAssetGUI, assemble their game-relative paths under `Dawnwalker/Content/UIAndSubtitles/Fonts`, and convert the legacy assets with retoc `to-zen --version UE5_5`. Package the matching `.ufont` files at those same paths in the companion `.pak`. Lua files belong under `Dawnwalker/Binaries/Win64/ue4ss/Mods/UIAndSubtitles/Scripts`.
