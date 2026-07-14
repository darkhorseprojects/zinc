import * as stylex from "@stylexjs/stylex";
import type { JSX } from "solid-js";
import { styles } from "./Chrome.stylex";

export function IconButton(props: JSX.ButtonHTMLAttributes<HTMLButtonElement> & { size?: "xs" | "sm" | "md" }) { const attrs = () => stylex.attrs(styles.iconButton, styles[props.size ?? "xs"]); return <button {...props} class={`${attrs().class ?? ""} ${props.class ?? ""}`.trim()} style={attrs().style}>{props.children}</button>; }
export function Chip(props: JSX.HTMLAttributes<HTMLSpanElement> & { kind?: "tag" | "source" }) { const attrs = () => stylex.attrs(styles.chip, props.kind === "source" && styles.source); return <span {...props} class={`${attrs().class ?? ""} ${props.class ?? ""}`.trim()} style={attrs().style}>{props.children}</span>; }
export function MenuSurface(props: JSX.HTMLAttributes<HTMLDivElement>) { const attrs = stylex.attrs(styles.menu); return <div {...props} class={`${attrs.class ?? ""} ${props.class ?? ""}`.trim()} style={attrs.style}>{props.children}</div>; }
