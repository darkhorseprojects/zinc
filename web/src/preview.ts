import * as anime from "animejs";
import * as solid from "solid-js";
import * as solidWeb from "solid-js/web";
type CompileResult = { ok: true; code: string } | { ok: false; error: string };

export async function compileTsxSource(source: string, signal?: AbortSignal): Promise<CompileResult> {
  const response = await fetch("/api/tsx/compile", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ source }),
    signal,
  });
  if (!response.ok) return { ok: false, error: await response.text() };
  return await response.json() as CompileResult;
}

export async function mountTsxPreview(code: string, element: HTMLElement, portal: HTMLElement): Promise<() => void> {
  const kobalte = await import("@kobalte/core");
  const module = { exports: {} as Record<string, unknown> };
  const exports = module.exports;
  const require = (name: string) => {
    if (name === "solid-js") return solid;
    if (name === "solid-js/web") return solidWeb;
    if (name === "@kobalte/core") return kobalte;
    if (name === "animejs") return anime;
    throw new Error(`Unsupported TSX preview module: ${name}`);
  };
  const load = new Function("require", "module", "exports", `${code}\nreturn module.exports.default ?? exports.default;`);
  const Component = load(require, module, exports);
  if (typeof Component !== "function") throw new Error("TSX preview default export is not a component");
  const dispose = solidWeb.render(() => solid.createComponent(Component, { portal }), element);
  return () => {
    dispose();
    element.replaceChildren();
    portal.replaceChildren();
  };
}
