/** Installs window-level drag/drop listeners. Detects a dropped store file path (by extension) vs. arbitrary dropped text/files. */
export function installDropController(options: { active: (active: boolean) => void; drop: (data: DataTransfer) => void | Promise<void> }) {
  let depth = 0;
  const enter = (event: DragEvent) => { if (!event.dataTransfer) return; claim(event); depth++; options.active(true); };
  const over = (event: DragEvent) => { if (!event.dataTransfer) return; claim(event); event.dataTransfer.dropEffect = "copy"; options.active(true); };
  const leave = (event: DragEvent) => { if (!event.dataTransfer) return; event.stopPropagation(); depth = Math.max(0, depth - 1); if (depth === 0 || !event.relatedTarget) options.active(false); };
  const drop = (event: DragEvent) => { if (!event.dataTransfer) return; claim(event); depth = 0; options.active(false); void options.drop(event.dataTransfer); };

  for (const target of dropTargets()) {
    target.addEventListener("dragenter", enter as EventListener, true);
    target.addEventListener("dragover", over as EventListener, true);
    target.addEventListener("dragleave", leave as EventListener, true);
    target.addEventListener("drop", drop as EventListener, true);
  }
  return () => {
    for (const target of dropTargets()) {
      target.removeEventListener("dragenter", enter as EventListener, true);
      target.removeEventListener("dragover", over as EventListener, true);
      target.removeEventListener("dragleave", leave as EventListener, true);
      target.removeEventListener("drop", drop as EventListener, true);
    }
  };
}

export function droppedStorePath(data: DataTransfer): string | null {
  const uriPath = fileUrlPath(data.getData("text/uri-list"));
  if (uriPath && isDatabasePath(uriPath)) return uriPath;
  const textPath = absolutePath(data.getData("text/plain"));
  if (textPath && isDatabasePath(textPath)) return textPath;
  for (const file of Array.from(data.files)) {
    const exposedPath = absolutePath((file as any).path) || absolutePath((file as any).webkitRelativePath);
    if (exposedPath && isDatabasePath(exposedPath)) return exposedPath;
  }
  return null;
}

export async function droppedText(data: DataTransfer | null): Promise<string> {
  if (!data) return "";
  const uriPath = fileUrlPath(data.getData("text/uri-list")) || fileUrlPath(data.getData("text/plain"));
  if (uriPath) return dirname(uriPath);
  const files = [...data.files];
  if (!files.length) return "";
  const labels = await Promise.all(files.map((file) => droppedFileLabel(file)));
  return labels.filter(Boolean).join("\n");
}

async function droppedFileLabel(file: File) {
  const exposedPath = absolutePath((file as any).path) || absolutePath((file as any).webkitRelativePath);
  if (exposedPath) return dirname(exposedPath);
  if (file.type.startsWith("text/") || /\.(md|markdown|kdl|txt|json|ts|tsx|js|jsx)$/i.test(file.name)) {
    const text = await file.text().catch(() => "");
    if (text.trim()) return [`${file.name}:`, "", text].join("\n");
  }
  return file.name;
}

function claim(event: DragEvent) {
  event.preventDefault();
  event.stopPropagation();
}
function dropTargets(): EventTarget[] {
  return [window, document, document.documentElement, document.body].filter(Boolean);
}
function fileUrlPath(value: string) {
  const first = value.split(/\r?\n/).find((line) => line && !line.startsWith("#"));
  return first?.startsWith("file://") ? decodeURIComponent(new URL(first).pathname) : null;
}
function dirname(path: string) {
  const index = path.lastIndexOf("/");
  return index > 0 ? path.slice(0, index) : path;
}
function absolutePath(value: unknown) {
  return typeof value === "string" && value.startsWith("/") ? value : null;
}
function isDatabasePath(path: string) {
  return /\.(db|sqlite|sqlite3)$/i.test(path);
}
