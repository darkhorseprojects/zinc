import { addRecent, getStores, saveStore, unsaveStore } from "~/lib/stores";
import { jsonBody, jsonError, methodNotAllowed } from "../http";

export async function handleStores(request: Request) {
  try {
    if (request.method === "GET") return Response.json(await getStores());
    if (request.method !== "POST") return methodNotAllowed();

    const body = await jsonBody(request);
    const { op, storePath, storeName, meta } = body as any;

    if (op === "recent" || op === "markRecent") {
      return Response.json(await addRecent({ path: storePath, name: storeName, meta }));
    }
    if (op === "save" || op === "pinStore") {
      return Response.json(await saveStore({ path: storePath, name: storeName, meta }));
    }
    if (op === "unsave" || op === "unpinStore") {
      return Response.json(await unsaveStore(storePath));
    }

    return Response.json({ error: `Invalid store op: ${op}` }, { status: 400 });
  } catch (error) {
    return jsonError(error);
  }
}
