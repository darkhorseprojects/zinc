import * as stylex from "@stylexjs/stylex";
import { tokens } from "../styles/tokens.stylex";

export const styles = stylex.create({
  iconButton: { display: "inline-flex", alignItems: "center", justifyContent: "center", padding: 0, borderWidth: "1px", borderStyle: "solid", borderColor: "transparent", borderRadius: tokens.radiusSm, backgroundColor: "transparent", color: tokens.muted, cursor: "default", ":hover": { backgroundColor: "color-mix(in srgb, var(--z-muted) 18%, transparent)", color: tokens.text }, ":focus-visible": { outline: "1px solid color-mix(in srgb, var(--z-accent) 62%, transparent)", outlineOffset: "2px" } },
  xs: { width: tokens.controlXs, height: tokens.controlXs }, sm: { width: tokens.controlSm, height: tokens.controlSm }, md: { width: tokens.controlMd, height: tokens.controlMd, borderRadius: tokens.radiusMd },
  chip: { display: "inline-flex", alignItems: "center", height: tokens.chip, paddingInline: tokens.space2, borderRadius: tokens.radiusPill, whiteSpace: "nowrap", fontFamily: "Zinc Mono, ui-monospace, monospace", fontSize: "11px", lineHeight: 1 },
  source: { borderWidth: "1px", borderStyle: "solid", borderColor: "color-mix(in srgb, var(--z-text) 14%, transparent)", backgroundColor: "transparent", color: tokens.muted },
  menu: { padding: tokens.space2, borderWidth: "1px", borderStyle: "solid", borderColor: "color-mix(in srgb, var(--z-text) 10%, transparent)", borderRadius: tokens.radiusLg, backgroundColor: tokens.surface },
});
