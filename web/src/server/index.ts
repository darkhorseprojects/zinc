import { serveStaticOrIndex } from "./static";
import { handleBootstrap } from "./routes/bootstrap";
import { handleStores } from "./routes/stores";
import { handleThread } from "./routes/thread";
import { handleThreads } from "./routes/threads";
import { handleContinue } from "./routes/continue";
import { handleContinueStream } from "./routes/continueStream";

const port = Number(process.env.PORT || process.env.ZINC_PORT || 5173);

const server = Bun.serve({
  port,
  hostname: process.env.HOST || "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/api/bootstrap" && request.method === "GET") return handleBootstrap(request);
    if (url.pathname === "/api/stores") return handleStores(request);
    if (url.pathname === "/api/threads") return handleThreads(request);
    if (url.pathname === "/api/thread") return handleThread(request);
    if (url.pathname === "/api/thread/continue") return handleContinue(request);
    if (url.pathname === "/api/thread/continue/stream") return handleContinueStream(request);

    if (url.pathname.startsWith("/api/")) {
      return Response.json({ error: "Not found" }, { status: 404 });
    }

    return serveStaticOrIndex(request);
  },
});

console.log(`zinc web listening on http://${server.hostname}:${server.port}`);
