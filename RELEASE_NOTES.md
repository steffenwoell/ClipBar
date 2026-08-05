# Release Notes

## ClipBar 1.4 "Frija"

### New

- Added built-in formatting actions for bold, italic and underlined text. The group and each action can be disabled separately.
- Added a built-in offline thesaurus for German and English. Suggestions replace editable selections and can be copied from read-only contexts.

### Changes

- Improved source application detection for selections in menu bar app popovers.
- Reduced the delay before the popup appears for regular webpage selections in Safari.
- ClipBar now explicitly targets macOS 13 or later.

### Fixed

- Added text selection support for Pages and the Tot menu bar popover.
- Improved formatting compatibility with Microsoft Word, PowerPoint, Mellel, Ulysses and Markdown editors.
- Prevented unrelated keyboard shortcuts from being triggered by formatting actions.
- Diagnostic exports now preserve an existing destination file if the new export cannot be completed.

## ClipBar 1.3.4 "Frija"

### Fixed

- Fixed actions in grouped popovers, including the AI submenu, being dismissed before execution.
- Added support for the `codex://` URL scheme used by the Ask ChatGPT action.
- Added diagnostic logging when a plugin URL is rejected or cannot be opened.

## ClipBar 1.3.3 "Frija"

### Fixed

- Fixed Finder file copy and move operations becoming unavailable while ClipBar was running.
- Prevented Finder from entering the synthetic clipboard fallback, preserving Finder-specific pasteboard metadata required by `⌘V` and `⌘⌥V`.

## ClipBar 1.3.2 "Frija"

### Fixes

- Prevented file drag-and-drop between applications from triggering ClipBar.
- Prevented double-clicks on downloads, list rows, cells, and other controls from being treated as text selections.
- Rejected stale Accessibility selections whose bounds do not match the current mouse gesture.
- Corrected paragraph counting for wrapped text.
- Ensured newly bundled plugins are installed without overwriting existing user files.

---

## ClipBar 1.3.1 "Frija"

### New

- Added **Recover After Crashes** option.
- ClipBar can now automatically restart after an unexpected crash using a LaunchAgent.
- Crash recovery can be enabled or disabled from the Settings menu.
- Added search plugins for:
  - DuckDuckGo Images
  - Google Maps
  - IMDb

### Changes

- Added popover appearance setting:
  - System
  - Light
  - Dark
- The selected appearance is applied immediately without restarting ClipBar.
- Diagnostic log files are now automatically trimmed when they exceed the configured size limit, keeping the most recent entries.
- Updated bundled search plugins and documentation.

---

## ClipBar 1.3 "Frija"

### New

- Added configurable popover appearance (System, Light, Dark).

### Changes

- Diagnostic log files are automatically limited in size by removing the oldest log entries.
- Theme preference is stored in the configuration file.
- Updated README and documentation.

---

## ClipBar 1.2.2 "Frija"

### Changes

- Improved Finder compatibility by preventing the popup from appearing during drag-and-drop operations.
- Added line count to the Word Count plugin.
- Improved ordering of built-in plugins.

---

## ClipBar 1.2.1 "Frija"

### Changes

- Improved selection detection reliability.
- Refined clipboard fallback behavior.
- General stability improvements.

---

## ClipBar 1.2 "Frija"

### New

- Added plugin groups.
- Added built-in plugins:
  - Word Count
  - Remove Line Breaks
  - Case Converter

### Changes

- Improved plugin management.
- Improved Preview and PowerPoint compatibility.
- Improved clipboard fallback logic.

---

## ClipBar 1.1 "Frija"

### New

- Added URL detection.
- Added email detection.
- Added DOI detection.
- Added ISBN detection.
- Added file path detection.
- Added blacklist support.
- Added diagnostics.
- Added Launch at Login.
- Added configuration folder.

### Changes

- Improved popup positioning.
- Improved compatibility across supported applications.
- Numerous UI refinements and stability improvements.

---

## ClipBar 1.0 "Frija"

Initial public release.

### Features

- Contextual action bar for selected text.
- Web search.
- Copy selected text.
- Open URLs.
- Open email links.
- Open file paths in Finder.
- Lightweight native macOS implementation.
- Plugin architecture.
- Configurable settings.
- MIT licensed.
