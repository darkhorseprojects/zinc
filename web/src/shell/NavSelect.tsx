import { Select } from "@kobalte/core/select";
import caretDownSvg from "@phosphor-icons/core/assets/duotone/caret-down-duotone.svg";
import * as stylex from "@stylexjs/stylex";
import { animate, utils, type JSAnimation } from "animejs";
import { createEffect, createSignal, onCleanup, Show, type JSX } from "solid-js";
import { common } from "../styles/design.stylex";
import { IdentifierLabel } from "../thread/IdentifierLabel";
import { Icon } from "./Icon";
import { shellStyles } from "./shell.stylex";

export interface NavOption { label: string; value: string; icon?: string; identifier?: string; }
interface NavSelectProps { options: NavOption[]; value: string | null; onChange: (value: string | null) => void; placeholder: string; leadingIcon?: string; labelContent?: JSX.Element; onLabelClick?: () => void; }

export function NavSelect(props: NavSelectProps) {
  const [isOpen, setIsOpen] = createSignal(false);
  let triggerRef: HTMLButtonElement | undefined, caretIconRef: HTMLSpanElement | undefined, menuRef: HTMLDivElement | undefined;
  let caretAnimation: JSAnimation | null = null, menuAnimation: JSAnimation | null = null;
  const field = () => stylex.attrs(common.interactiveSurface, isOpen() && common.persistentSurface, shellStyles.field), label = () => stylex.attrs(shellStyles.label, !hasAlternatives() && shellStyles.labelStatic), labelText = stylex.attrs(shellStyles.labelText), chevron = stylex.attrs(shellStyles.chevron), positioner = stylex.attrs(shellStyles.menuPositioner), menu = stylex.attrs(common.persistentSurface, common.menu, shellStyles.menuMotion), list = stylex.attrs(shellStyles.menuList);

  createEffect(() => {
    const open = isOpen(); caretAnimation?.cancel(); menuAnimation?.cancel();
    if (caretIconRef) caretAnimation = animate(caretIconRef, { rotate: open ? 180 : 0, duration: 130, ease: "outQuad" });
    if (!menuRef) return;
    if (open) {
      utils.set(menuRef, { visibility: "visible", pointerEvents: "auto", opacity: 0, scaleX: .965, scaleY: .94, translateY: -3, transformOrigin: "top center" });
      menuAnimation = animate(menuRef, { opacity: 1, scaleX: [1.012, 1], scaleY: [1.018, 1], translateY: 0, duration: 155, ease: "outBack(1.35)" });
    } else {
      menuAnimation = animate(menuRef, { opacity: 0, scaleX: .965, scaleY: .94, translateY: -3, duration: 110, ease: "inQuad", onComplete: () => { if (!isOpen() && menuRef) utils.set(menuRef, { visibility: "hidden", pointerEvents: "none" }); } });
    }
  });
  onCleanup(() => { caretAnimation?.cancel(); menuAnimation?.cancel(); });

  const selectedOption = () => props.options.find((option) => option.value === props.value) ?? null;
  const hasAlternatives = () => props.options.some((option) => option.value !== props.value);
  const selectedLabel = () => { const selected = selectedOption(); return selected?.identifier !== undefined ? <IdentifierLabel value={selected.identifier} fallback={selected.label} /> : selected?.label ?? props.placeholder; };
  function activateLabel() { if (props.onLabelClick) props.onLabelClick(); else triggerRef?.click(); }

  return <Select
    options={props.options}
    value={selectedOption()}
    onChange={(selected: NavOption | null) => { if (selected?.value && props.options.some((option) => option.value === selected.value)) props.onChange(selected.value); }}
    optionValue="value"
    optionTextValue="label"
    disabled={!hasAlternatives()}
    forceMount
    onOpenChange={(open) => setIsOpen(open && hasAlternatives())}
    itemComponent={(itemProps) => { const hidden = () => itemProps.item.rawValue.value === props.value, attrs = () => stylex.attrs(shellStyles.item, hidden() && shellStyles.itemHidden); return <Select.Item item={itemProps.item} class={`${attrs().class ?? ""} nav-select-item`} style={attrs().style} title={itemProps.item.rawValue.label} aria-hidden={hidden() || undefined}>
      {itemProps.item.rawValue.icon && <span class="nav-select-item-icon"><Icon svg={itemProps.item.rawValue.icon} size={15} /></span>}
      <Select.ItemLabel class="nav-select-item-label">{itemProps.item.rawValue.identifier !== undefined ? <IdentifierLabel value={itemProps.item.rawValue.identifier} fallback={itemProps.item.rawValue.label} /> : itemProps.item.rawValue.label}</Select.ItemLabel>
    </Select.Item>; }}
  >
    <div class={`${field().class ?? ""} nav-field-group`} style={field().style} title={selectedOption()?.label ?? props.placeholder} data-expanded={isOpen() || undefined} data-static={!hasAlternatives() || undefined}>
      <button type="button" class={`${label().class ?? ""} nav-field-label`} style={label().style} onPointerDown={(event) => { event.preventDefault(); event.stopPropagation(); activateLabel(); }}>
        {props.leadingIcon && <Icon svg={props.leadingIcon} size={16} />}
        <span class={`${labelText.class ?? ""} nav-field-label-text`} style={labelText.style}>{props.labelContent ?? selectedLabel()}</span>
      </button>
      <Show when={hasAlternatives()}><Select.Trigger ref={triggerRef} class={`${chevron.class ?? ""} nav-field-chevron`} style={chevron.style} aria-label={`Choose ${props.placeholder}`}>
        <Select.Icon><span ref={caretIconRef} class="nav-field-chevron-icon"><Icon svg={caretDownSvg} size={16} /></span></Select.Icon>
      </Select.Trigger></Show>
    </div>
    <Show when={hasAlternatives()}><Select.Portal><Select.Content class={`${positioner.class ?? ""} zinc-menu-positioner`} style={positioner.style}>
      <div ref={menuRef} class={`${menu.class ?? ""} zinc-menu`} style={menu.style} aria-hidden={!isOpen() || undefined}><Select.Listbox class={list.class} style={list.style} /></div>
    </Select.Content></Select.Portal></Show>
  </Select>;
}
