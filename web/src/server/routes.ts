import { readThreadBootstrap, stringParam } from "~/thread/bootstrap";
import { addStore, listStores, removeStore } from "~/lib/stores";
import { activeStore, getZincConfig } from "~/lib/config";
import { commitThreadMdx, ConflictError, createThread_, deleteEmptyThread, listThreads, loadThread, openStore } from "~/lib/db";
import { packetToWire, threadViewToWire, type ContinueEvent } from "~/lib/wire";
import { continuationErrorData, continueContext, type ContinueRequest } from "~/server/loop";

export function jsonError(error: unknown, status = 500) {
  return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status });
}

async function jsonBody(request: Request) {
  return await request.json().catch(() => ({}));
}

function methodNotAllowed() {
  return Response.json({ error: "Method not allowed" }, { status: 405 });
}

export async function handleBootstrap(request: Request) {
  try {
    const url = new URL(request.url);
    return Response.json(await readThreadBootstrap(stringParam(url.searchParams.get("store")), stringParam(url.searchParams.get("thread"))));
  } catch (error) {
    return jsonError(error);
  }
}

export async function handleStores(request: Request) {
  try {
    if (request.method === "GET") return Response.json({ stores: await listStores() });
    if (request.method !== "POST") return methodNotAllowed();

    const body = await jsonBody(request);
    const { op, storePath, storeName } = body as any;
    if (op === "add") return Response.json({ stores: await addStore({ path: storePath, name: storeName }) });
    if (op === "remove") return Response.json({ stores: await removeStore(storePath) });
    return Response.json({ error: `Invalid store op: ${op}` }, { status: 400 });
  } catch (error) {
    return jsonError(error);
  }
}

export async function handleThreads(request: Request) {
  try {
    const url = new URL(request.url);
    if (request.method === "GET") return Response.json({ threads: await listThreads(await activeStore(url.searchParams.get("store"))) });
    if (request.method === "POST") {
      const body = await jsonBody(request);
      return Response.json(threadViewToWire(await createThread_(await activeStore((body as any).store ?? null))));
    }
    return methodNotAllowed();
  } catch (error) {
    return jsonError(error);
  }
}

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
      return Response.json({ deleted: await deleteEmptyThread(id, await activeStore(url.searchParams.get("store"))) });
    }

    if (request.method === "PUT") {
      const body = await jsonBody(request);
      const id = typeof (body as any).id === "string" ? (body as any).id : "";
      const revision = typeof (body as any).revision === "string" ? (body as any).revision : "";
      const mdx = typeof (body as any).mdx === "string" ? (body as any).mdx : null;
      if (!id || !revision || mdx === null) return Response.json({ error: "Missing id/revision/mdx" }, { status: 400 });

      const config = await getZincConfig();
      const db = await openStore(await activeStore((body as any).store ?? null));
      try {
        return Response.json(threadViewToWire(await commitThreadMdx(db, id, revision, mdx, { packetOverflowBytes: config.packetOverflowBytes })));
      } catch (error) {
        if (error instanceof ConflictError) return Response.json({ error: error.message, current: error.current }, { status: 409 });
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

function normalizeContinueBody(body: any): ContinueRequest | null {
  const threadId = typeof body.threadId === "string" ? body.threadId : "";
  if (!threadId) return null;
  return {
    threadId,
    input: typeof body.draft === "string" ? body.draft : typeof body.input === "string" ? body.input : "",
    ...(typeof body.baseRevision === "string" ? { baseRevision: body.baseRevision } : {}),
  };
}

export async function handleContinue(request: Request) {
  try {
    if (request.method !== "POST") return methodNotAllowed();
    const body = await jsonBody(request);
    const normalized = normalizeContinueBody(body);
    if (!normalized) return Response.json({ error: "Missing threadId" }, { status: 400 });
    return Response.json(threadViewToWire(await continueContext(normalized, await activeStore((body as any).store ?? null))));
  } catch (error) {
    return jsonError(error);
  }
}

const ndjsonEncoder = new TextEncoder();

export async function handleContinueStream(request: Request) {
  if (request.method !== "POST") return methodNotAllowed();
  const body = await jsonBody(request);
  const normalized = normalizeContinueBody(body);
  if (!normalized) return Response.json({ error: "Missing threadId" }, { status: 400 });
  const store = await activeStore((body as any).store ?? null);

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: ContinueEvent) => controller.enqueue(ndjsonEncoder.encode(`${JSON.stringify(event)}\n`));
      try {
        const result = await continueContext(normalized, store, async (frame) => {
          if (frame.output) send({ type: "output", entry: frame.output.entry, stream: frame.output.stream, text: frame.output.text });
          else if (frame.packet) send({ type: "packet", packet: packetToWire(frame.packet) });
          else if (frame.thread) send({ type: "thread", thread: threadViewToWire(frame.thread) });
          else if (frame.error) send({ type: "error", message: continuationErrorData(frame.error).message });
        });
        send({ type: "thread", thread: threadViewToWire(result) });
        controller.close();
      } catch (error) {
        send({ type: "error", message: continuationErrorData(error, "transport").message });
        controller.close();
      }
    },
  });

  return new Response(stream, { headers: { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store" } });
}
