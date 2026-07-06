import { Toast, toaster } from "@kobalte/core/toast";

export type SystemToast = {
  title: string;
  detail?: string;
};

export function showSystemToast(message: SystemToast | string) {
  const toast = typeof message === "string" ? { title: message } : message;
  toaster.show((props) => (
    <Toast toastId={props.toastId} class="zinc-toast" priority="high">
      <div class="zinc-toast-copy">
        <Toast.Title class="zinc-toast-title">{toast.title}</Toast.Title>
        {toast.detail && <Toast.Description class="zinc-toast-detail">{toast.detail}</Toast.Description>}
      </div>
      <Toast.CloseButton class="zinc-toast-close" aria-label="Dismiss notification">×</Toast.CloseButton>
    </Toast>
  ));
}

export function describeError(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
