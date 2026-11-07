# Spektraplus — changes from SpektraLab

Spektraplus is an unofficial, modified version of
[SpektraLab](https://github.com/JamesQiu2005/SpektraLab) (GPL-3.0-or-later),
based on SpektraLab `main` at `213741f` (1.3.6, build 21). This file is the
notice GPL-3.0 §5(a) asks a modified work to carry: what was changed, and when.
It is not endorsed by the SpektraLab project or by spektrafilm.

The spektrafilm film and paper profiles and the print LUTs (CC BY-SA 4.0, by
Andrea Volpato, <https://github.com/andreavolpato/spektrafilm>) are **not
modified**. The render engine is not modified.

## 0.1.0 Alpha — 2026-11-07

Changed by Broksd.

**Library**
- A folder browser as a page of the left rail (Folders / Film and Print), with
  Places (home, Pictures, mounted disks) and Favorites kept between launches.
- Flags (P keep, X reject, U clear) and a flag filter (⌥⌘1–4); ⌘A selects
  what the filter shows.
- A record beside the photographs, `SpektraLab.folder.json`: flags, filter,
  the open frame, the dragged order and every edit, restored when the folder
  is opened again, here or on another Mac. It can be turned off in Settings.
- A grid view of the folder (G) beside the single photo (E).
- Folders with no photographs of their own open to an empty strip.
- Import Photos (⇧⌘I): from the open folder (all or selected) or another
  folder or card, copied — never moved or deleted — into a destination filed
  by capture date (`2026/2026-11-07`, as Lightroom Classic files them, and
  other layouts). The last source and destination are remembered.
- The Navigator is no longer listed in Film and Print.

**Identity**
- Named Spektraplus, with its own icon and bundle id
  (`com.broksd.spektraplus`), as SpektraLab's trademark notice asks of
  published forks. Versions count from 0.1.0.
- The About window, the launch screen, the bundled licence notes and the
  README say that this is an unofficial, modified SpektraLab and credit the
  spektrafilm engine by Andrea Volpato.
- Check for Updates reads this fork's releases
  (<https://github.com/Broksd/SpektraPLUS/releases>), not SpektraLab's.
- Kept on purpose, so existing edits keep working: the edits folder
  (`~/Library/Application Support/SpektraLab`), the cache and log folders, the
  folder record's file name and the agent id `spektralab`.
