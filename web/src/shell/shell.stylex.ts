import * as stylex from "@stylexjs/stylex";
import { corners, layers, measures, palette, type } from "../styles/design.stylex";

export const shellStyles = stylex.create({
  top: { position: "sticky", top: 0, zIndex: layers.top, width: "100%", paddingTop: "max(16px, env(safe-area-inset-top))", paddingRight: measures.pageInset, paddingBottom: "12px", paddingLeft: measures.pageInset, display: "flex", alignItems: "center", justifyContent: "space-between", gap: "16px", backgroundColor: palette.background },
  breadcrumb: { display: "flex", flex: 1, alignItems: "center", gap: "8px", minWidth: 0, overflow: "hidden" },
  controls: { display: "flex", flex: "none", alignItems: "center", gap: "8px" },
  field: { display: "inline-flex", width: "max-content", maxWidth: "min(520px, 55vw)", minWidth: 0, flex: "none", alignItems: "stretch", overflow: "hidden", borderRadius: corners.control, color: palette.muted },
  label: { position: "relative", zIndex: 1, minWidth: 0, height: measures.control, paddingLeft: "12px", paddingRight: "10px", display: "inline-flex", flex: "1 1 auto", alignItems: "center", gap: "8px", overflow: "hidden", borderRadius: 0, color: "inherit", backgroundColor: "transparent", ":hover": { color: palette.text, backgroundColor: palette.hover } },
  labelStatic: { paddingRight: "12px" },
  labelText: { minWidth: 0, maxWidth: "420px", display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontFamily: type.menu, fontSize: "13px", lineHeight: 1 },
  chevron: { position: "relative", zIndex: 1, width: "32px", height: measures.control, padding: 0, display: "inline-flex", flex: "none", alignItems: "center", justifyContent: "center", borderWidth: 0, borderRadius: 0, color: "inherit", backgroundColor: "transparent", ":hover": { color: palette.text, backgroundColor: palette.hover }, ":focus-visible": { outlineWidth: "1px", outlineStyle: "solid", outlineColor: palette.focus, outlineOffset: "-2px" } },
  menuPositioner: { zIndex: layers.menu, overflow: "visible" },
  menuMotion: { minWidth: "180px", padding: "6px", overflow: "visible", transformOrigin: "top center" },
  menuList: { maxHeight: "280px", overflowY: "auto", display: "flex", flexDirection: "column", gap: "2px", scrollbarWidth: "none" },
  item: { position: "relative", width: "100%", minHeight: "34px", paddingLeft: "10px", paddingRight: "10px", display: "grid", gridTemplateColumns: "20px minmax(0, 1fr) 20px", alignItems: "center", borderWidth: 0, borderRadius: corners.item, color: palette.muted, backgroundColor: "transparent", fontFamily: type.menu, fontSize: "13px", lineHeight: 1.4 },
  itemHidden: { display: "none" },
  identityEditor: { minWidth: "1ch", display: "inline-grid", gridTemplateColumns: "minmax(1ch, max-content)", alignItems: "center" },
  identityMeasure: { gridArea: "1 / 1", minWidth: "1ch", visibility: "hidden", whiteSpace: "pre", font: "inherit" },
  identityInput: { gridArea: "1 / 1", width: "100%", minWidth: "1ch", padding: 0, outline: "none", font: "inherit", lineHeight: "inherit" },
});
