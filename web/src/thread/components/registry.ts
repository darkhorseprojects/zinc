import type { Component } from "solid-js";
import { Reasoning } from "./Reasoning";
import { Shell } from "./Shell";
import { ErrorBlock } from "./Error";
import { Source } from "./Source";
import { RawBlock } from "./RawBlock";
import type { MdxComponentProps } from "./types";

/**
 * Tag name -> Solid component. This is the entire "add a known component" surface: one file,
 * one line here. Any tag not listed renders via RawBlock (its exact MDX source, still editable).
 */
export const componentRegistry: Record<string, Component<MdxComponentProps>> = {
  Reasoning,
  Shell,
  Error: ErrorBlock,
  Source,
};

export function resolveComponent(tag: string): Component<MdxComponentProps> {
  return componentRegistry[tag] ?? RawBlock;
}
