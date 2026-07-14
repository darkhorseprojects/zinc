import bookmarkSvg from "@phosphor-icons/core/assets/duotone/bookmark-simple-duotone.svg?raw";
import { For, Show } from "solid-js";
import { Icon } from "../shell/Icon";
import { parseIdentifier, tagColor } from "./identifier";

export function IdentifierLabel(props: { value: string; fallback?: string }) { const parts = () => parseIdentifier(props.value); return <span class="identifier-label"><Show when={parts().tags.length} fallback={<Icon svg={bookmarkSvg} size={15} class="identifier-bookmark" />}><For each={parts().tags}>{(tag) => <span class="identifier-tag" data-color={tagColor(tag)}>{tag}</span>}</For></Show><span class="identifier-title">{parts().title || props.fallback || "untitled"}</span></span>; }
