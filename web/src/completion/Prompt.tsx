import * as stylex from "@stylexjs/stylex";
import { createSignal, onCleanup, onMount } from "solid-js";
import { PromptEditor } from "../editor/PromptEditor";
import { createLiquidGlassMap, promptLiquidGlassOptions, type LiquidGlassMap } from "../ui/liquidGlass";
import { promptStyles } from "./prompt.stylex";

interface PromptProps {
  onSend: (text: string) => Promise<void> | void;
  disabled: boolean;
  appendText?: string | null;
  onAppendTextConsumed?: () => void;
}

const GLASS_FILTER_ID = "prompt-glass-distortion";

export function Prompt(props: PromptProps) {
  let shellRef: HTMLDivElement | undefined;
  let resizeObserver: ResizeObserver | undefined;
  let animationFrame = 0;
  let geometryKey = "";

  const [glass, setGlass] = createSignal<LiquidGlassMap | null>(null);

  onMount(() => {
    if (!shellRef) return;
    resizeObserver = new ResizeObserver(scheduleGlassUpdate);
    resizeObserver.observe(shellRef);
    scheduleGlassUpdate();
  });

  onCleanup(() => {
    cancelAnimationFrame(animationFrame);
    resizeObserver?.disconnect();
    document.documentElement.style.removeProperty("--dock-occlusion");
  });

  function scheduleGlassUpdate() {
    cancelAnimationFrame(animationFrame);
    animationFrame = requestAnimationFrame(updateGlass);
  }

  function updateGlass() {
    if (!shellRef) return;
    const rect = shellRef.getBoundingClientRect();
    const width = Math.round(rect.width);
    const height = Math.round(rect.height);
    document.documentElement.style.setProperty("--dock-occlusion", `${height + 72}px`);
    const radius = Number.parseFloat(getComputedStyle(shellRef).borderTopLeftRadius);
    if (width < 2 || height < 2 || !Number.isFinite(radius)) return;

    const nextGeometryKey = `${width}x${height}:${radius}`;
    if (nextGeometryKey === geometryKey) return;
    geometryKey = nextGeometryKey;
    setGlass(createLiquidGlassMap(width, height, {
      ...promptLiquidGlassOptions,
      radius,
      thickness: radius * 1.75,
    }));
  }

  const shell = () => stylex.attrs(promptStyles.shell, glass() && promptStyles.glass);
  return (
    <>
      <svg class="liquid-glass-svg" xmlns="http://www.w3.org/2000/svg" width="0" height="0" color-interpolation-filters="sRGB" aria-hidden="true">
        <defs>
          <filter id={GLASS_FILTER_ID} x="0%" y="0%" width="100%" height="100%" color-interpolation-filters="sRGB">
            <feImage href={glass()?.displacement} x="0" y="0" width={glass()?.width ?? 1} height={glass()?.height ?? 1} result="map" preserveAspectRatio="none" />
            <feGaussianBlur in="SourceGraphic" stdDeviation="3" result="softSource" />

            <feDisplacementMap in="softSource" in2="map" scale={String(glass()?.redScale ?? 0)} xChannelSelector="R" yChannelSelector="G" result="dispR" />
            <feDisplacementMap in="softSource" in2="map" scale={String(glass()?.greenScale ?? 0)} xChannelSelector="R" yChannelSelector="G" result="dispG" />
            <feDisplacementMap in="softSource" in2="map" scale={String(glass()?.blueScale ?? 0)} xChannelSelector="R" yChannelSelector="G" result="dispB" />

            <feColorMatrix in="dispR" result="onlyR" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" />
            <feColorMatrix in="dispG" result="onlyG" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" />
            <feColorMatrix in="dispB" result="onlyB" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" />

            <feComposite in="onlyR" in2="onlyG" operator="arithmetic" k1="0" k2="1" k3="1" k4="0" result="rg" />
            <feComposite in="rg" in2="onlyB" operator="arithmetic" k1="0" k2="1" k3="1" k4="0" result="rgb" />

            <feComponentTransfer in="rgb">
              <feFuncR type="identity" />
              <feFuncG type="identity" />
              <feFuncB type="identity" />
              <feFuncA type="identity" />
            </feComponentTransfer>
          </filter>
        </defs>
      </svg>
      <div ref={shellRef} class={`${shell().class ?? ""} prompt-shell`} style={shell().style} data-glass-ready={glass() ? "true" : undefined}>
        <PromptEditor
          appendText={props.appendText ?? ""}
          editable={!props.disabled}
          onSubmit={props.onSend}
          onAppendConsumed={props.onAppendTextConsumed}
        />
      </div>
    </>
  );
}

export default Prompt;
