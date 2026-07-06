import { activeStore } from "~/lib/config";
import { packetToWire, threadViewToWire, type ContinueEvent } from "~/lib/wire";
import { continuationErrorData, continueContext } from "~/server/runtime/continueContext";
import { jsonBody, methodNotAllowed } from "../http";
import { normalizeContinueBody } from "./continueRequest";

const encoder = new TextEncoder();

export async function handleContinueStream(request: Request) {
  if (request.method !== "POST") return methodNotAllowed();
  const body = await jsonBody(request);
  const normalized = normalizeContinueBody(body);
  if (!normalized) return Response.json({ error: "Missing threadId" }, { status: 400 });
  const store = await activeStore((body as any).store ?? null);

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: ContinueEvent) => controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`));
      try {
        const result = await continueContext(normalized, store, async (frame) => {
          if (frame.output) {
            send({ type: "output", entry: frame.output.entry, stream: frame.output.stream, text: frame.output.text });
          } else if (frame.packet) {
            send({ type: "packet", packet: packetToWire(frame.packet) });
          } else if (frame.thread) {
            send({ type: "thread", thread: threadViewToWire(frame.thread) });
          } else if (frame.error) {
            send({ type: "error", message: continuationErrorData(frame.error).message });
          }
        });
        send({ type: "thread", thread: threadViewToWire(result) });
        controller.close();
      } catch (error) {
        send({ type: "error", message: continuationErrorData(error, "transport").message });
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}
