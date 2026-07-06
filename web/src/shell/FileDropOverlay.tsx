import { Show } from "solid-js";

interface FileDropOverlayProps {
  active: boolean;
}

export function FileDropOverlay(props: FileDropOverlayProps) {
  return (
    <Show when={props.active}>
      <div class="file-drop-overlay" aria-hidden="true" />
    </Show>
  );
}

export default FileDropOverlay;
