import { activeStore } from "~/lib/config";
import { createThread_, listThreads } from "~/lib/db";
import { threadViewToWire } from "~/lib/wire";
import { jsonBody, jsonError, methodNotAllowed } from "../http";

export async function handleThreads(request: Request) {
  try {
    const url = new URL(request.url);
    if (request.method === "GET") {
      const store = await activeStore(url.searchParams.get("store"));
      return Response.json({ threads: await listThreads(store) });
    }
    if (request.method === "POST") {
      const body = await jsonBody(request);
      return Response.json(threadViewToWire(await createThread_(await activeStore((body as any).store ?? null))));
    }
    return methodNotAllowed();
  } catch (error) {
    return jsonError(error);
  }
}
