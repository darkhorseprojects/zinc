export type RouteHandler = (request: Request) => Response | Promise<Response>;

export function jsonError(error: unknown, status = 500) {
  return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status });
}

export async function jsonBody(request: Request) {
  return await request.json().catch(() => ({}));
}

export function methodNotAllowed() {
  return Response.json({ error: "Method not allowed" }, { status: 405 });
}
