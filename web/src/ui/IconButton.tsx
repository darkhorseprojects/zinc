import * as stylex from "@stylexjs/stylex";
import { splitProps, type JSX } from "solid-js";
import { common } from "../styles/design.stylex";

export function IconButton(props: JSX.ButtonHTMLAttributes<HTMLButtonElement> & { size?: "sm" | "md"; raised?: boolean }) {
  const [local, button] = splitProps(props, ["size", "raised", "class", "children"]), attrs = () => stylex.attrs(common.iconButton, local.size === "md" && common.iconButtonMedium, local.raised && common.interactiveSurface);
  return <button {...button} class={`${attrs().class ?? ""} ${local.class ?? ""}`.trim()} style={attrs().style}>{local.children}</button>;
}
