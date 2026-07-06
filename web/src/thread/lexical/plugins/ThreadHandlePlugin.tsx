import { createEffect, onCleanup } from "solid-js";
import type { ZincEditorHandle } from "~/thread/ZincEditor";

export function ThreadHandlePlugin(props: {
  enabled: boolean;
  handle: ZincEditorHandle;
  bind?: (handle: ZincEditorHandle | null) => void;
}) {
  let bound = false;

  createEffect(() => {
    if (props.enabled && !bound) {
      props.bind?.(props.handle);
      bound = true;
    } else if (!props.enabled && bound) {
      props.bind?.(null);
      bound = false;
    }
  });

  onCleanup(() => {
    if (bound) props.bind?.(null);
  });

  return null;
}
