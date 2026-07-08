import { addStore, listStores, removeStore } from "~/lib/stores";
import { jsonBody, jsonError, methodNotAllowed } from "../http";

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
