import * as stylex from "@stylexjs/stylex";
import { corners, layers, measures, palette } from "../styles/design.stylex";

export const promptStyles = stylex.create({
  shell: {
    position: "fixed",
    left: "50%",
    bottom: "max(24px, env(safe-area-inset-bottom))",
    zIndex: layers.dock,
    transform: "translateX(-50%)",
    width: "min(820px, calc(100% - 48px))",
    minHeight: measures.dockHeight,
    maxHeight: "min(360px, calc(100svh - 80px))",
    padding: measures.dockPadding,
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
    isolation: "isolate",
    borderWidth: 0,
    borderRadius: corners.dock,
    outline: "none",
    backgroundColor: "transparent",
  },
  glass: {
    backgroundColor: "rgb(var(--z-surface-rgb) / 0.42)",
    backdropFilter: "url(#prompt-glass-distortion)",
  },
  editor: { minHeight: measures.dockEditor, backgroundColor: "transparent", color: palette.text },
});
