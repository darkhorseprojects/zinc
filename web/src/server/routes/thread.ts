import { activeStore, getZincConfig } from "~/lib/config";
import { commitThreadMdx, ConflictError, deleteEmptyThread, loadThread, openStore } from "~/lib/db";
import { threadViewToWire } from "~/lib/wire";
import { jsonBody, jsonError, methodNotAllowed } from "../http";

export async function handleThread(request: Request) {
  try {
    const url = new URL(request.url);
    if (request.method === "GET") {
      const id = url.searchParams.get("id");
      if (!id) return Response.json({ error: "Missing thread id" }, { status: 400 });
      return Response.json(threadViewToWire(await loadThread(id, await activeStore(url.searchParams.get("store")))));
    }

    if (request.method === "DELETE") {
      const id = url.searchParams.get("id");
      if (!id) return Response.json({ error: "Missing thread id" }, { status: 400 });
      const deleted = await deleteEmptyThread(id, await activeStore(url.searchParams.get("store")));
      return Response.json({ deleted });
    }

    if (request.method === "PUT") {
      const body = await jsonBody(request);
      const id = typeof (body as any).id === "string" ? (body as any).id : "";
      const revision = typeof (body as any).revision === "string" ? (body as any).revision : "";
      const mdx = typeof (body as any).mdx === "string" ? (body as any).mdx : null;
      if (!id || !revision || mdx === null) return Response.json({ error: "Missing id/revision/mdx" }, { status: 400 });

      const config = await getZincConfig();
      const store = await activeStore((body as any).store ?? null);
      const db = await openStore(store);
      try {
        return Response.json(threadViewToWire(await commitThreadMdx(db, id, revision, mdx, { packetOverflowBytes: config.packetOverflowBytes })));
      } catch (error) {
        if (error instanceof ConflictError) {
          return Response.json({ error: error.message, current: error.current }, { status: 409 });
        }
        throw error;
      } finally {
        db.close();
      }
    }

    return methodNotAllowed();
  } catch (error) {
    return jsonError(error);
  }
}
