import { Toast, toaster } from "@kobalte/core/toast";
import * as stylex from "@stylexjs/stylex";
import { common } from "../styles/design.stylex";
import { toastStyles } from "./toast.stylex";

export type SystemToast = { title: string; detail?: string; action?: { label: string; run(): void }; persistent?: boolean };
export function showSystemToast(message: SystemToast | string) {
  const toast = typeof message === "string" ? { title: message } : message;
  toaster.show((props) => <SystemToastView id={props.toastId} toast={toast} />);
}
function SystemToastView(props: { id: number; toast: SystemToast }) {
  const surface = stylex.attrs(common.persistentSurface, common.toast, toastStyles.toast), copy = stylex.attrs(toastStyles.copy), title = stylex.attrs(toastStyles.title), detail = stylex.attrs(toastStyles.detail), action = stylex.attrs(toastStyles.action), close = stylex.attrs(toastStyles.close);
  return <Toast toastId={props.id} class={`${surface.class ?? ""} zinc-toast`} style={surface.style} priority="high" persistent={props.toast.persistent}>
    <div class={`${copy.class ?? ""} zinc-toast-copy`} style={copy.style}><Toast.Title class={`${title.class ?? ""} zinc-toast-title`} style={title.style}>{props.toast.title}</Toast.Title>{props.toast.detail && <Toast.Description class={`${detail.class ?? ""} zinc-toast-detail`} style={detail.style}>{props.toast.detail}</Toast.Description>}</div>
    {props.toast.action && <button class={`${action.class ?? ""} zinc-toast-action`} style={action.style} type="button" onClick={() => { props.toast.action?.run(); toaster.dismiss(props.id); }}>{props.toast.action.label}</button>}
    <Toast.CloseButton class={`${close.class ?? ""} zinc-toast-close`} style={close.style} aria-label="Dismiss notification">×</Toast.CloseButton>
  </Toast>;
}
export function describeError(error: unknown) { return error instanceof Error ? error.message : String(error); }
