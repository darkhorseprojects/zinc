import { Select } from "@kobalte/core/select";
import { createEffect, createSignal } from "solid-js";
import { Icon } from "./Icon";
import caretDownSvg from "@phosphor-icons/core/assets/duotone/caret-down-duotone.svg?raw";
import { revealMenu, revealMenuItems, rotateCaretIcon } from "~/ui/animate";

export interface NavOption {
  label: string;
  value: string;
  icon?: string;
  outlined?: boolean;
  iconOnly?: boolean;
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

  createEffect(() => {
    rotateCaretIcon(caretIconRef, isOpen());
    if (isOpen()) {
      revealMenu(menuRef);
      // Delay item animation to sync with menu
      setTimeout(() => {
        if (menuRef) revealMenuItems(menuRef);
      }, 40);
    }
  });

  const selectedOption = () => props.options.find((option) => option.value === props.value) || null;
  const menuOptions = () => props.options.filter((option) => option.value !== props.value);

  return (
    <Select
      options={menuOptions()}
      value={selectedOption()}
      onChange={(selected: NavOption | null) => {
        if (
          selected?.value &&
          props.options.some((option) => option.value === selected.value)
        ) {
          props.onChange(selected.value);
        }
      }}
      optionValue="value"
      optionTextValue="label"
      onOpenChange={setIsOpen}
      itemComponent={(itemProps) => (
        <Select.Item
          item={itemProps.item}
          class="nav-select-item"
          data-outlined={itemProps.item.rawValue.outlined || undefined}
          data-icon-only={itemProps.item.rawValue.iconOnly || undefined}
        >
          {itemProps.item.rawValue.icon && <span class="nav-select-item-icon"><Icon svg={itemProps.item.rawValue.icon} size={15} /></span>}
          <Select.ItemLabel class="nav-select-item-label">{itemProps.item.rawValue.label}</Select.ItemLabel>
        </Select.Item>
      )}
    >
      <Select.Trigger
        class="nav-field-group"
        data-expanded={isOpen() || undefined}
      >
        <div class="nav-field-label">
          {props.leadingIcon && <Icon svg={props.leadingIcon} size={16} />}
          <span class="nav-field-label-text">
            {selectedOption() ? selectedOption()!.label : props.placeholder}
          </span>
        </div>
        <Select.Icon class="nav-field-chevron">
          <span ref={caretIconRef} class="nav-field-chevron-icon">
            <Icon svg={caretDownSvg} size={16} />
          </span>
        </Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Content ref={menuRef} class="zinc-menu">
          <Select.Listbox />
        </Select.Content>
      </Select.Portal>
    </Select>
  );
}
