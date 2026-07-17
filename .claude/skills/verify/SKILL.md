# Verify — RhythmCoach (macOS SwiftUI app, SPM, CLT-only)

Build / run:
- `swift build --product RhythmCoach` → binary at `.build/debug/RhythmCoach`
- Hermetic tests: `swift run rc-tests` (custom runner; swift-testing is broken under CLT)
- User-visible launch: `Scripts/make-app.sh debug && open dist/RhythmCoach.app` (LaunchServices — survives terminal restart, activates in Dock). A bare `nohup .build/debug/RhythmCoach &` dies quietly; don't use it.

## GUI verification (permissions granted 2026-07-17)

The terminal app has **Screen Recording** and **Accessibility** TCC grants, so:
- Screenshots: `screencapture -x -o -l <windowID>`; get windowID via a small CGWindowListCopyWindowInfo helper (filter `kCGWindowOwnerName == "RhythmCoach"`, height > 200).
- AX driving via System Events **works for**: `set frontmost`, `click button N of …`, `set selected of row N of outline 1 of …` (SwiftUI List selection), `set value of scroll bar 1 of scroll area … to 1.0` (scroll to bottom), `get value of every static text …` (read toolbar readouts — great for numeric assertions).
- **System Events `click at {x,y}` does NOT deliver real mouse events to custom NSViews** (clicks land as AX-only; seek/drag/zoom handlers never fire). For real pointer input compile a CGEvent helper (post `.leftMouseDown/.leftMouseUp/.leftMouseDragged/.mouseMoved/scrollWheelEvent2` to `.cghidEventTap`, set `.mouseEventClickState` for double-clicks). Those are indistinguishable from hardware.
- Caveat: while the user is actively at the machine, synthetic scroll events (delivered at the physical cursor) and click sequences get flaky — prefer numeric AX readouts over screenshots per step, and re-run inconsistent steps.
- Useful AX path (History detail pane): `scroll area 1 of group 2 of splitter group 1 of group 2 of splitter group 1 of group 1 of window 1`; sidebar rows: `row N of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1`.

Fallback if permissions are ever revoked: temporary in-app `ImageRenderer` hook rendering the stateless view layer (e.g. `WaveformCanvasView`) to PNG, driven by env vars; mark every temp edit `// TEMP-VERIFY` and finish with `grep -rn TEMP-VERIFY Sources/` (must be empty).

## Data

- DB: `~/Library/Application Support/RhythmCoach/rhythmcoach.db` (WAL); take WAVs in `Sessions/` next to it. `FileManager.urls(for:.applicationSupportDirectory)` **ignores `$HOME` overrides** — this is always production data; count rows before/after if you must seed, and delete `hit` then `session` rows explicitly (FK cascade off in sqlite3 CLI).
- Synthetic-session seeding recipe (WAV with plucks at exact deviations + INSERT with explicit column list): see git history of this feature or rebuild from `WaveFile.write`.
