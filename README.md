# Subtitle and Dialogue Controls

Adjust cinematic subtitles, dialogue choices and gameplay subtitles independently in The Blood of Dawnwalker. Choose the vanilla Afacad font or Alegreya for these text areas.

| Setting | Default | Range |
| --- | --- | --- |
| Enabled | On | Off / On |
| Cinematic subtitle size | 75% | 25-200% |
| Dialogue choice size | 100% | 25-200% |
| Gameplay subtitle size | 100% | 25-200% |
| Subtitle and dialogue font | Alegreya | Vanilla (Afacad) / Alegreya |
| Logging | Off | Off / On |

Sizes are percentages of each widget's original size, including any text style supplied by another mod. At 100%, the original size is retained. Cinematic size covers spoken lines, speaker names and movie subtitles. Dialogue choice size covers response choices and their quantity labels. Gameplay size covers bottom-screen lines, accessibility lines and overhead NPC subtitles. Distance scaling and dialogue effects remain controlled by the game. Extremely large text may exceed the game's layout space.

The font selector affects only these subtitle and dialogue text areas. Inventory, journal and other interface fonts retain their current appearance. Both font families are included under unique asset paths, so Alternative Font - Alegreya can remain enabled for the rest of the interface. It is not required by this mod. Language-specific fallback faces continue to come from the game.

## Dependencies

Requires UE4SS with Lua 5.4, native UFunction hooks and delayed game-thread callbacks, such as Vercadi UE4SS RC6 or Framecore UE4SS 2b. Blueprint execution hooks are not required. Dawnwalker Mod Menu 1.0.6 or later is optional for the in-game controls and live Apply; its console bridge requires HookProcessConsoleExec to be enabled in UE4SS.

## Installation

- Vortex: Install Subtitle-and-Dialogue-Controls.zip through Vortex, enable it and deploy.
- Manual: Copy the archive's Dawnwalker folder into the The Blood of Dawnwalker game directory, preserving the folder structure.

## Configuration

Open Mod Settings, select Subtitle and Dialogue Controls, change the values and choose Apply. Visible text updates over the next few frames; new lines receive the same settings. Turning Enabled off restores font and size values still controlled by this mod. Reset restores the defaults above.

Without Mod Settings, launch the game once to create `Dawnwalker/Binaries/Win64/ue4ss/Mods/SubtitleDialogueControls/settings.ini`. Close the game before editing its `[Settings]` section and restart afterward. `subtitlePercent`, `dialoguePercent` and `gameplayPercent` accept whole numbers from 25 to 200. `fontFamily = 0` selects vanilla Afacad; `fontFamily = 1` selects Alegreya. `enabled` and `debugLogging` use 0 for Off and 1 for On. The archive does not contain an active settings.ini.

Turn Logging on to record text-processing counts, aggregate update timings and font-loading failures in `Dawnwalker/Binaries/Win64/ue4ss/UE4SS.log`. Essential capability failures are reported once even with Logging off. If a font package cannot load, size controls continue using the available font.

## Credits

Alegreya by the Alegreya Project Authors and Afacad by the Afacad Project Authors, under the SIL Open Font License 1.1; licenses are included. Alegreya is built from the Google Fonts distribution. The vanilla Afacad faces retain the game's original 1.000 font data. Font package templates retain the game's fallback-language references.

The font choice was inspired by WinterElfeas's [Alternative Font - Alegreya](https://www.nexusmods.com/thebloodofdawnwalker/mods/217); this mod does not redistribute that Nexus archive. Settings storage and validation use the MIT-licensed ue4ss-common helpers. The Mod Menu integration helper is included unchanged from its integration guide. Original game asset metadata belongs to its respective owners. The Lua code is MIT-licensed.

## Source layout

`src` contains the runtime and settings integration. `assets` contains editable font package templates and the licensed font faces. `package` contains installer metadata and the cooked font containers. Convert the font templates with UAssetGUI, assemble their game-relative paths under `Dawnwalker/Content/SubtitleDialogueControls/Fonts`, and convert the legacy assets with retoc `to-zen --version UE5_5`. Package the matching `.ufont` files at those same paths in the companion `.pak`. Lua files belong under `Dawnwalker/Binaries/Win64/ue4ss/Mods/SubtitleDialogueControls/Scripts`.
