import { startServer } from "./server.js";

const server = await startServer();
await new Promise<void>((done) => {
  const stop = () => void server.close().then(done);
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
});
