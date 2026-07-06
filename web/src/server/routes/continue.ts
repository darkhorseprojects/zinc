import { activeStore } from "~/lib/config";
import { threadViewToWire } from "~/lib/wire";
import { continueContext } from "~/server/runtime/continueContext";
import { jsonBody, jsonError, methodNotAllowed } from "../http";
import { normalizeContinueBody } from "./continueRequest";

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
