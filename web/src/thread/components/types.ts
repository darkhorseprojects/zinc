import type { NodeKey } from "lexical";

/** Props every known component view receives, mirroring MdxComponentDecorator. */
export type MdxComponentProps = {
  nodeKey: NodeKey;
  tag: string;
  props: Record<string, unknown>;
  body: string;
};

export function stringProp(props: Record<string, unknown>, name: string): string {
  const value = props[name];
  return typeof value === "string" ? value : "";
}
