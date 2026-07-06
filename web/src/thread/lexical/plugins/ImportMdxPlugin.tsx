import { createEffect } from "solid-js";

export function ImportMdxPlugin(props: {
  mode: "thread" | "prompt";
  mdx: string;
  baseRevision: string;
  dirty: boolean;
  lastImportedMdx: string;
  importClean: (mdx: string, baseRevision: string) => void;
  onAppendTextConsumed?: () => void;
}) {
  let initialized = false;

  createEffect(() => {
    const mode = props.mode;
    const mdx = props.mdx ?? "";
    const baseRevision = props.baseRevision ?? "";

    if (!initialized) {
      initialized = true;
      props.importClean(mdx, baseRevision);
      return;
    }

    if (mode === "thread") {
      if (mdx !== props.lastImportedMdx && !props.dirty) {
        props.importClean(mdx, baseRevision);
      }
      return;
    }

    if (mdx) {
      props.importClean(mdx, "");
      props.onAppendTextConsumed?.();
    }
  });

  return null;
}
