import { Toast } from "@kobalte/core/toast";

export function Toasts() {
  return (
    <Toast.Region class="zinc-toast-region">
      <Toast.List class="zinc-toast-list" />
    </Toast.Region>
  );
}

export default Toasts;
