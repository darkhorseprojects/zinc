import * as stylex from "@stylexjs/stylex";
import { createSignal, Show } from "solid-js";
import { IdentifierLabel } from "../thread/IdentifierLabel";
import type { ThreadManifest, ThreadSummary } from "../thread/types";
import { NavSelect, type NavOption } from "./NavSelect";
import { shellStyles } from "./shell.stylex";

export function ThreadIdentity(props: { thread: ThreadManifest | null; threads: ThreadSummary[]; identifier: string; onThread(id: string): void; onIdentifier(value: string): void }) {
  const [editing, setEditing] = createSignal(false), [draft, setDraft] = createSignal("");
  let input!: HTMLInputElement;
  const editor = stylex.attrs(shellStyles.identityEditor), measure = stylex.attrs(shellStyles.identityMeasure), inputStyle = stylex.attrs(shellStyles.identityInput);
  const options = (): NavOption[] => props.threads.map((thread) => ({ value: thread.id, label: thread.title, identifier: thread.identifier }));

  function begin() {
    if (!props.thread || editing()) return;
    setDraft(props.identifier || props.thread.title); setEditing(true);
    queueMicrotask(() => { input.focus(); input.select(); });
  }
  function finish(save: boolean) { if (!editing()) return; if (save) props.onIdentifier(draft()); setEditing(false); }

  return <NavSelect
    options={options()}
    value={props.thread?.id ?? null}
    onChange={(value) => value && props.onThread(value)}
    onLabelClick={begin}
    placeholder="thread"
    labelContent={<Show when={editing()} fallback={<IdentifierLabel value={props.identifier} fallback={props.thread?.title} />}>
      <span class={`${editor.class ?? ""} identifier-editor`} style={editor.style}>
        <span class={measure.class} style={measure.style} aria-hidden="true">{draft() || "\u200b"}</span>
        <input ref={input} size={1} class={`${inputStyle.class ?? ""} identifier-input`} style={inputStyle.style} value={draft()} aria-label="Thread identifier" onInput={(event) => setDraft(event.currentTarget.value)} onBlur={() => finish(true)} onPointerDown={(event) => event.stopPropagation()} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); finish(true); } else if (event.key === "Escape") { event.preventDefault(); finish(false); } }} />
      </span>
    </Show>}
  />;
}
