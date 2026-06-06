# Zinc computer

Use the computer package for GUI work that is not better handled by files, shell, graphs, or browser CDP.

Tools:

- `computer_observe`: inspect a display/window and optionally capture a screenshot
- `computer_locate`: locate a visible target in a screenshot
- `computer_input`: click, type, key, scroll, or drag

Process:

1. Observe first.
2. Locate when coordinates are needed.
3. Input at the located point.
4. Observe again to verify.

Text input should focus the target before typing. Scrolling should use an explicit target point.

On Linux, native Wayland input may briefly borrow focus. If the backend reports that input is unavailable or not allowed, stop instead of inventing an unsafe fallback.

Tool success means events were sent or a screenshot was captured. It does not prove the app did what the user wanted; verify after acting.
