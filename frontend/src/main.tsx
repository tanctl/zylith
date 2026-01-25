import React from "react";
import ReactDOM from "react-dom/client";

import App from "./App";
import { validateConfig } from "./lib/zylith";
import "./globals.css";

validateConfig();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
