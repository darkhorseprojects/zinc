import { render } from "solid-js/web";
import App from "./app";
import { zincClient } from "./client";
import "katex/dist/katex.min.css";
import "./styles/reset.css";
import "./styles/editor.css";

history.scrollRestoration = "auto";
const query = new URLSearchParams(location.search);
const initial = await zincClient.bootstrap(query.get("store"), query.get("thread"));
const root = document.getElementById("app");
if (!root) throw new Error("Missing #app root element.");
render(() => <App initial={initial} />, root);
