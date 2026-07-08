import { onMount } from "solid-js";

/** Grows a textarea to fit its content. `use:autoResize` on any <textarea>. */
export function autoResize(el: HTMLTextAreaElement) {
  const resize = () => {
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  };
  el.addEventListener("input", resize);
  onMount(() => setTimeout(resize, 0));
}

declare module "solid-js" {
  namespace JSX {
    interface Directives {
      autoResize: true;
    }
  }
}
