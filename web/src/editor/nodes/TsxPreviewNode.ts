import { DecoratorNode, type DOMExportOutput, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";
import { compileTsxSource, mountTsxPreview } from "../../preview";

export type SerializedTsxPreviewNode = Spread<{
  source: string;
  type: "tsx-preview";
  version: 1;
}, SerializedLexicalNode>;

const codeSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="currentColor"><path d="M69.12,94.15,28.5,128l40.62,33.85a8,8,0,1,1-10.24,12.29l-48-40a8,8,0,0,1,0-12.29l48-40a8,8,0,0,1,10.24,12.3Zm176,27.7-48-40a8,8,0,1,0-10.24,12.3L227.5,128l-40.62,33.85a8,8,0,1,0,10.24,12.29l48-40a8,8,0,0,0,0-12.29ZM162.73,32.48a8,8,0,0,0-10.25,4.79l-64,176a8,8,0,0,0,4.79,10.26A8.14,8.14,0,0,0,96,224a8,8,0,0,0,7.52-5.27l64-176A8,8,0,0,0,162.73,32.48Z"/></svg>`;
const baseCss = `
:host { display: block; width: 100%; color: inherit; font: inherit; }
*, *::before, *::after { box-sizing: border-box; }
button, input, textarea, select { font: inherit; }
[part="error"] { color: var(--error, #ef6a6a); font: inherit; white-space: pre-wrap; }
`;

type PreviewState = {
  element: HTMLElement;
  body: HTMLElement;
  app: HTMLElement;
  portal: HTMLElement;
  error: HTMLElement;
  controller?: AbortController;
  dispose?: () => void;
  token: object;
};

const previews = new Map<NodeKey, PreviewState>();

export class TsxPreviewNode extends DecoratorNode<null> {
  __source: string;

  static getType(): string { return "tsx-preview"; }
  static clone(node: TsxPreviewNode): TsxPreviewNode { return new TsxPreviewNode(node.__source, node.__key); }
  static importJSON(serialized: SerializedTsxPreviewNode): TsxPreviewNode { return new TsxPreviewNode(serialized.source || ""); }

  constructor(source: string, key?: NodeKey) {
    super(key);
    this.__source = source;
  }

  exportJSON(): SerializedTsxPreviewNode {
    return { source: this.__source, type: "tsx-preview", version: 1 };
  }

  exportDOM(): DOMExportOutput {
    const element = document.createElement("div");
    element.textContent = this.__source;
    return { element };
  }

  createDOM(_config: EditorConfig): HTMLElement {
    const key = this.getKey();
    disposeTsxPreview(key);
    const element = document.createElement("div");
    element.className = "tsx-preview-card";
    element.contentEditable = "false";

    const button = document.createElement("button");
    button.className = "tsx-preview-source-toggle";
    button.type = "button";
    button.tabIndex = -1;
    button.title = "Source";
    button.innerHTML = codeSvg;
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      event.stopPropagation();
      element.dispatchEvent(new CustomEvent("zinc:tsx-source", { bubbles: true, detail: { key } }));
    });

    const body = document.createElement("div");
    body.className = "tsx-preview-body";
    const shadow = body.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = baseCss;
    const app = document.createElement("div");
    app.part.add("app");
    const portal = document.createElement("div");
    portal.part.add("portal");
    const error = document.createElement("div");
    error.part.add("error");
    error.hidden = true;
    shadow.append(style, app, portal, error);
    element.append(button, body);

    const state: PreviewState = { element, body, app, portal, error, token: {} };
    previews.set(key, state);
    void renderPreview(key, state, this.__source);
    return element;
  }

  updateDOM(previous: TsxPreviewNode, element: HTMLElement): boolean {
    if (previous.__source !== this.__source) {
      const state = previews.get(this.getKey());
      if (state?.element === element) void renderPreview(this.getKey(), state, this.__source);
    }
    return false;
  }

  decorate(): null { return null; }
  isInline(): false { return false; }
  isIsolated(): true { return true; }
  getSource(): string { return this.__source; }
  setSource(source: string): void { this.getWritable().__source = source; }
}

export function disposeTsxPreview(key: NodeKey) {
  const state = previews.get(key);
  if (!state) return;
  previews.delete(key);
  state.controller?.abort();
  state.dispose?.();
  state.app.replaceChildren();
  state.portal.replaceChildren();
}

async function renderPreview(key: NodeKey, state: PreviewState, source: string) {
  state.controller?.abort();
  state.dispose?.();
  state.dispose = undefined;
  state.app.replaceChildren();
  state.portal.replaceChildren();
  state.error.hidden = true;
  state.error.textContent = "";
  state.element.className = "tsx-preview-card";
  const controller = new AbortController();
  const token = {};
  state.controller = controller;
  state.token = token;
  try {
    const result = await compileTsxSource(source, controller.signal);
    if (!current(key, state, token)) return;
    if (!result.ok) { showError(state, result.error); return; }
    const dispose = await mountTsxPreview(result.code, state.app, state.portal);
    if (!current(key, state, token)) { dispose(); return; }
    state.dispose = dispose;
  } catch (error) {
    if (controller.signal.aborted || !current(key, state, token)) return;
    showError(state, error instanceof Error ? error.message : String(error));
  }
}

function current(key: NodeKey, state: PreviewState, token: object) {
  return previews.get(key) === state && state.token === token;
}

function showError(state: PreviewState, message: string) {
  state.element.className = "tsx-preview-card tsx-preview-error";
  state.error.textContent = message;
  state.error.hidden = false;
}

export function $createTsxPreviewNode(source: string): TsxPreviewNode { return new TsxPreviewNode(source); }
export function $isTsxPreviewNode(node: LexicalNode | null | undefined): node is TsxPreviewNode { return node instanceof TsxPreviewNode; }
