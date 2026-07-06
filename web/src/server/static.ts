import { extname, join, normalize } from "node:path";

const CLIENT_ROOT = process.env.ZINC_CLIENT_ROOT || join(import.meta.dir, "..", "client");
const INDEX_PATH = join(CLIENT_ROOT, "index.html");

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".woff2": "font/woff2",
};

export async function serveStaticOrIndex(request: Request) {
  const url = new URL(request.url);
  const pathname = safePathname(url.pathname);
  const filePath = join(CLIENT_ROOT, pathname === "/" ? "index.html" : pathname);
  const file = Bun.file(filePath);

  if (await file.exists()) {
    return new Response(file, { headers: contentHeaders(filePath) });
  }

  return new Response(Bun.file(INDEX_PATH), { headers: { "content-type": CONTENT_TYPES[".html"] } });
}

function safePathname(pathname: string) {
  const decoded = decodeURIComponent(pathname);
  const normalized = normalize(decoded).replace(/^\/+/, "");
  if (!normalized || normalized === ".") return "/";
  if (normalized.startsWith("..") || normalized.includes("/../")) return "/";
  return `/${normalized}`;
}

function contentHeaders(path: string) {
  return { "content-type": CONTENT_TYPES[extname(path)] || "application/octet-stream" };
}
