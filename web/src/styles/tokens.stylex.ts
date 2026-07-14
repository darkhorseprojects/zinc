import * as stylex from "@stylexjs/stylex";

export const tokens = stylex.defineConsts({
  background: "var(--z-background)", surface: "var(--z-surface)", text: "var(--z-text)", muted: "var(--z-muted)", accent: "var(--z-accent)", positive: "var(--z-positive)", negative: "var(--z-negative)", warning: "var(--z-warning)", info: "var(--z-info)", violet: "var(--z-violet)",
  space0: "0", spaceHalf: "2px", space1: "4px", space2: "8px", space3: "12px", space4: "16px", space5: "20px", space6: "24px", space8: "32px", space10: "40px", space12: "48px", space16: "64px",
  controlXs: "24px", controlSm: "32px", controlMd: "40px", chip: "20px", radiusSm: "8px", radiusMd: "12px", radiusLg: "16px", radiusPill: "999px",
  layerContent: "10", layerTop: "30", layerDock: "40", layerMenu: "60", layerToast: "80",
});
