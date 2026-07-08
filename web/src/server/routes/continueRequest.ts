import type { ContinueRequest } from "~/server/runtime/continueContext";

export function normalizeContinueBody(body: any): ContinueRequest | null {
  const threadId = typeof body.threadId === "string" ? body.threadId : "";
  if (!threadId) return null;
  return {
    threadId,
    input: typeof body.draft === "string" ? body.draft : typeof body.input === "string" ? body.input : "",
    ...(typeof body.baseRevision === "string" ? { baseRevision: body.baseRevision } : {}),
  };
}
