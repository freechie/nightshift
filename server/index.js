import { listen, loadEnv, publicBase } from "./app.js";

loadEnv();
const port = Number(process.env.PORT || 8787);
const server = listen(port);
server.on("listening", () => {
  console.log(`license server ${publicBase()} port ${port}`);
});
