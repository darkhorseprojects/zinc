import { Toast } from "@kobalte/core/toast";
import * as stylex from "@stylexjs/stylex";
import { toastStyles } from "../ui/toast.stylex";

export function Toasts() {
  const region = stylex.attrs(toastStyles.region), list = stylex.attrs(toastStyles.list);
  return (
    <Toast.Region class={`${region.class ?? ""} zinc-toast-region`} style={region.style}>
      <Toast.List class={`${list.class ?? ""} zinc-toast-list`} style={list.style} />
    </Toast.Region>
  );
}

export default Toasts;
