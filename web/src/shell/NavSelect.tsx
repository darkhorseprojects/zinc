import { Select } from "@kobalte/core/select";
import caretDownSvg from "@phosphor-icons/core/assets/duotone/caret-down-duotone.svg?raw";
import { animate, createTimeline, stagger, utils, type JSAnimation } from "animejs";
import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import { IdentifierLabel } from "../thread/IdentifierLabel";
import { Icon } from "./Icon";

export interface NavOption {
  label: string;
  value: string;
  icon?: string;
  identifier?: string;
}

interface NavSelectProps {
  options: NavOption[];
  value: string | null;
  onChange: (value: string | null) => void;
  placeholder: string;
  leadingIcon?: string;
}

export function NavSelect(props: NavSelectProps) {
  const [isOpen, setIsOpen] = createSignal(false);
  let caretIconRef: HTMLSpanElement | undefined;
  let menuRef: HTMLDivElement | undefined;
  let caretAnimation: JSAnimation | null = null;
  let menuAnimation: ReturnType<typeof createTimeline> | null = null;
  let itemAnimation: JSAnimation | null = null;

  createEffect(() => {
    const open = isOpen();
    caretAnimation?.cancel();
    if (caretIconRef) {
      caretAnimation = animate(caretIconRef, {
        rotate: open ? 180 : 0,
        duration: 160,
        ease: "outQuad",
      });
    }
    if (open) queueMicrotask(revealMenu);
    else cancelMenuAnimation();
  });

  onCleanup(() => {
    caretAnimation?.cancel();
    cancelMenuAnimation();
  });

  const selectedOption = () => props.options.find((option) => option.value === props.value) ?? null;
  const hasAlternatives = () => props.options.some((option) => option.value !== props.value);

  function cancelMenuAnimation() {
    menuAnimation?.cancel();
    itemAnimation?.cancel();
    menuAnimation = null;
    itemAnimation = null;
  }

  function revealMenu() {
    if (!menuRef || !isOpen()) return;
    cancelMenuAnimation();

    const items = menuRef.querySelectorAll(".nav-select-item:not([hidden])");
    if (items.length <= 1) {
      utils.set(menuRef, { height: menuRef.scrollHeight, opacity: 1, rotateX: 0, scaleX: 1 });
      return;
    }

    const fullHeight = menuRef.scrollHeight;
    utils.set(menuRef, { height: 0, opacity: 0, rotateX: -20, scaleX: 0.94, transformOrigin: "top center" });
    if (menuRef.parentElement) utils.set(menuRef.parentElement, { perspective: 600 });
    utils.set(items, { opacity: 0 });

    menuAnimation = createTimeline().add(menuRef, {
      height: fullHeight,
      opacity: 1,
      rotateX: [6, -2, 0],
      scaleX: [1.03, 0.99, 1],
      duration: 180,
      ease: "outQuad",
    });
    itemAnimation = animate(items, {
      opacity: 1,
      duration: 100,
      delay: stagger(5, { start: 40 }),
      ease: "outQuad",
    });
  }

  return (
    <Select
      options={props.options}
      value={selectedOption()}
      onChange={(selected: NavOption | null) => {
        if (selected?.value && props.options.some((option) => option.value === selected.value)) {
          props.onChange(selected.value);
        }
      }}
      optionValue="value"
      optionTextValue="label"
      disabled={!hasAlternatives()}
      onOpenChange={(open) => setIsOpen(open && hasAlternatives())}
      itemComponent={(itemProps) => (
        <Select.Item item={itemProps.item} class="nav-select-item" title={itemProps.item.rawValue.label} hidden={itemProps.item.rawValue.value === props.value}>
          {itemProps.item.rawValue.icon && <span class="nav-select-item-icon"><Icon svg={itemProps.item.rawValue.icon} size={15} /></span>}
          <Select.ItemLabel class="nav-select-item-label">{itemProps.item.rawValue.identifier !== undefined ? <IdentifierLabel value={itemProps.item.rawValue.identifier} fallback={itemProps.item.rawValue.label} /> : itemProps.item.rawValue.label}</Select.ItemLabel>
        </Select.Item>
      )}
    >
      <Select.Trigger
        class="nav-field-group"
        title={selectedOption()?.label ?? props.placeholder}
        data-expanded={isOpen() || undefined}
        data-static={!hasAlternatives() || undefined}
      >
        <div class="nav-field-label">
          {props.leadingIcon && <Icon svg={props.leadingIcon} size={16} />}
          <span class="nav-field-label-text">
            {selectedOption()?.identifier !== undefined ? <IdentifierLabel value={selectedOption()!.identifier!} fallback={selectedOption()!.label} /> : selectedOption() ? selectedOption()!.label : props.placeholder}
          </span>
        </div>
        <Show when={hasAlternatives()}>
          <Select.Icon class="nav-field-chevron">
            <span ref={caretIconRef} class="nav-field-chevron-icon">
              <Icon svg={caretDownSvg} size={16} />
            </span>
          </Select.Icon>
        </Show>
      </Select.Trigger>
      <Show when={hasAlternatives()}>
        <Select.Portal>
          <Select.Content ref={menuRef} class="zinc-menu">
            <Select.Listbox />
          </Select.Content>
        </Select.Portal>
      </Show>
    </Select>
  );
}
