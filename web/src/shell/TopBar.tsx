import { Show } from "solid-js";
import { NavSelect, type NavOption } from "./NavSelect";
import { Icon } from "./Icon";
import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg?raw";
import gitBranchSvg from "@phosphor-icons/core/assets/duotone/git-branch-duotone.svg?raw";
import plusSvg from "@phosphor-icons/core/assets/duotone/plus-duotone.svg?raw";
import type { StoreRef } from "~/lib/stores";

type ThreadNavItem = { id: string; title?: string; revision: string; updated: number };

interface TopBarProps {
  store: StoreRef | null;
  stores: StoreRef[];
  thread: ThreadNavItem | null;
  threads: ThreadNavItem[];
  isSaving?: boolean;
  isDirty?: boolean;
  onStoreChange: (storePath: string | null) => void;
  onThreadChange: (threadId: string | null) => void;
  canNewThread?: boolean;
  onNewThread: () => void;
}

export function TopBar(props: TopBarProps) {
  const storeOptions = (): NavOption[] => [
    ...props.stores.map((store) => ({ label: store.name || store.path.split(/[/\\]/).pop() || store.path, value: store.path })),
  ];

  const threadOptions = (): NavOption[] => [
    ...props.threads.map((t) => ({ label: t.title || t.id, value: t.id, icon: gitBranchSvg })),
  ];

  const handleStoreChange = (value: string | null) => {
    props.onStoreChange(value);
  };

  const handleThreadChange = (value: string | null) => {
    props.onThreadChange(value);
  };

  return (
    <div class="top-zone">
      <div class="breadcrumb-row">
        <NavSelect
          options={storeOptions()}
          value={props.store ? props.store.path : null}
          onChange={handleStoreChange}
          placeholder="store"
          leadingIcon={databaseSvg}
        />
        <Show when={props.store}>
          <span class="breadcrumb-sep">/</span>
          <Show when={props.threads.length > 0} fallback={
            <button class="nav-square-button" title="New thread" disabled={!props.canNewThread} onClick={() => props.onNewThread()}>
              <Icon svg={plusSvg} size={18} />
            </button>
          }>
            <NavSelect
              options={threadOptions()}
              value={props.thread ? props.thread.id : null}
              onChange={handleThreadChange}
              placeholder="thread"
              leadingIcon={gitBranchSvg}
            />
          </Show>
        </Show>
      </div>

      <Show when={props.store && props.threads.length > 0}>
        <div class="top-controls">
          <Show when={props.thread}>
            <span class="save-status-indicator">
              <Show when={props.isSaving}>Saving...</Show>
              <Show when={!props.isSaving && props.isDirty}>Unsaved changes</Show>
              <Show when={!props.isSaving && !props.isDirty}>Saved</Show>
            </span>
          </Show>
          <button class="nav-square-button" title="New thread" disabled={!props.canNewThread} onClick={() => props.onNewThread()}>
            <Icon svg={plusSvg} size={18} />
          </button>
        </div>
      </Show>
    </div>
  );
}