# Zinc computer

Use the computer package for GUI work that is not better handled by files, shell, graphs, or browser CDP.

Tools:

- `computer_observe`: inspect a window, app, or display
- `computer_locate`: locate a visible target
- `computer_input`: click, type, key, scroll, or drag

Observe before input. Locate when coordinates are needed. Observe after input to verify.

If the platform backend reports that safe input is unavailable, stop instead of using an unsafe fallback.
