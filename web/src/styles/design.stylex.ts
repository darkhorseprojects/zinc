import * as stylex from "@stylexjs/stylex";

export const palette = stylex.defineConsts({
  background: "var(--z-background)",
  surface: "var(--z-surface)",
  text: "var(--z-text)",
  muted: "var(--z-muted)",
  accent: "var(--z-accent)",
  edge: "var(--z-edge)",
  neutral: "var(--z-neutral)",
  line: "rgb(var(--z-line-rgb) / 0.06)",
  border: "rgb(var(--z-line-rgb) / 0.14)",
  hover: "rgb(var(--z-neutral-rgb) / 0.18)",
  icon: "rgb(var(--z-text-rgb) / 0.34)",
  focus: "rgb(var(--z-line-rgb) / 0.24)",
  positive: "var(--z-positive)",
  negative: "var(--z-negative)",
  warning: "var(--z-warning)",
  info: "var(--z-info)",
  violet: "var(--z-violet)",
});

export const measures = stylex.defineConsts({
  manuscript: "820px",
  pageInset: "24px",
  control: "42px",
  controlSmall: "24px",
  dockHeight: "140px",
  dockPadding: "20px",
  dockEditor: "100px",
  dockInset: "24px",
});

export const corners = stylex.defineConsts({ small: "8px", item: "10px", control: "14px", surface: "16px", dock: "18px", pill: "999px" });
export const type = stylex.defineConsts({ menu: '"Zinc Menu", sans-serif', prose: '"Zinc Prose", serif', mono: '"Zinc Mono", monospace' });
export const layers = stylex.defineConsts({ content: 10, top: 30, dock: 40, menu: 60, toast: 80 });

const surface = "linear-gradient(180deg, rgb(255 255 255 / 0.035) 0%, transparent 60%), var(--z-surface)";
const rim = "linear-gradient(180deg, rgb(var(--z-rim-rgb) / 0.16), rgb(var(--z-rim-rgb) / 0.025) 44%, rgb(var(--z-edge-rgb) / 0.34))";
const rimMask = "linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)";

export const common = stylex.create({
  iconButton: {
    position: "relative",
    width: measures.controlSmall,
    height: measures.controlSmall,
    padding: 0,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flex: "none",
    borderWidth: 0,
    borderRadius: corners.small,
    backgroundColor: "transparent",
    color: palette.icon,
    cursor: "default",
    ":hover": { backgroundColor: palette.hover, color: palette.text },
    ":focus-visible": { outlineWidth: "1px", outlineStyle: "solid", outlineColor: palette.focus, outlineOffset: "2px" },
    ":disabled": { opacity: .36 },
  },
  iconButtonMedium: { width: measures.control, height: measures.control, borderRadius: corners.control },
  interactiveSurface: {
    position: "relative",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: "transparent",
    backgroundColor: "transparent",
    backgroundImage: "none",
    ":hover": { borderColor: palette.edge, backgroundColor: palette.surface, backgroundImage: surface },
    "::before": {
      content: '""',
      position: "absolute",
      inset: 0,
      zIndex: 0,
      padding: "1px",
      borderRadius: "inherit",
      backgroundImage: rim,
      WebkitMask: rimMask,
      WebkitMaskComposite: "xor",
      maskComposite: "exclude",
      pointerEvents: "none",
      opacity: 0,
    },
    ":hover::before": { opacity: 1 },
  },
  persistentSurface: {
    position: "relative",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: palette.edge,
    backgroundColor: palette.surface,
    backgroundImage: surface,
    "::before": {
      content: '""',
      position: "absolute",
      inset: 0,
      zIndex: 0,
      padding: "1px",
      borderRadius: "inherit",
      backgroundImage: rim,
      WebkitMask: rimMask,
      WebkitMaskComposite: "xor",
      maskComposite: "exclude",
      pointerEvents: "none",
    },
  },
  menu: { borderRadius: corners.control },
  toast: { borderRadius: corners.surface, backgroundColor: "rgb(var(--z-surface-rgb) / 0.88)", color: palette.text },
});
