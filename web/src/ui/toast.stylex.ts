import * as stylex from "@stylexjs/stylex";
import { corners, layers, palette, type } from "../styles/design.stylex";

export const toastStyles = stylex.create({
  region: { position: "fixed", right: "24px", bottom: "24px", zIndex: layers.toast, width: "min(380px, calc(100vw - 48px))", pointerEvents: "none" },
  list: { display: "flex", flexDirection: "column", gap: "8px" },
  toast: { display: "flex", alignItems: "flex-start", gap: "12px", padding: "12px", pointerEvents: "auto" },
  copy: { minWidth: 0, flex: 1 },
  title: { fontFamily: type.mono, fontSize: "13px" },
  detail: { marginTop: "4px", color: palette.muted, fontFamily: type.mono, fontSize: "12px", whiteSpace: "pre-wrap" },
  action: { paddingTop: "3px", paddingRight: "7px", paddingBottom: "3px", paddingLeft: "7px", borderWidth: "1px", borderStyle: "solid", borderColor: palette.border, borderRadius: corners.small, color: palette.text, fontFamily: type.mono, fontSize: "11px" },
  close: { color: palette.muted },
});
