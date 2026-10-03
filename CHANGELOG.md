# Changelog

## 0.1.0

- Add independent cinematic subtitle, dialogue choice and gameplay subtitle sizes.
- Add vanilla Afacad and Alegreya font selection for subtitle and dialogue text.
- Add independent size and font controls for supported menu, settings, inventory and journal labels, with Keep current as the UI font default.
- Retain existing subtitle preferences when the new UI settings are absent.
- Add live Mod Settings controls, persistent settings and optional logging.
- Pick up main-menu text at startup, including buttons that keep their initial text.
- Keep text sizes stable across repeated refreshes and font assignments.
- Prepare selected fonts at startup or settings changes.
- Extend Other UI to inventory names and descriptions, glossary body text, court text and additional hub labels.
- Apply settings to static text and large screens without leaving most labels at their previous size.
- Keep menu text settings ready between openings; apply changes at game load or when settings change.
- Batch settings changes to reduce the delay and the visible spread of updates across a screen.
