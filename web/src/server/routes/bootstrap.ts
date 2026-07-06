import { readThreadBootstrap, stringParam } from "~/thread/bootstrap";
import { jsonError } from "../http";

export async function handleBootstrap(request: Request) {
  try {
    const url = new URL(request.url);
    return Response.json(await readThreadBootstrap(stringParam(url.searchParams.get("store")), stringParam(url.searchParams.get("thread"))));
  } catch (error) {
    return jsonError(error);
  }
}
