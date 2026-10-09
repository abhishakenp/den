const WebSocket = require("ws");

async function probe(path) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://localhost:7265${path}`);
    const timeout = setTimeout(() => {
      ws.terminate();
      resolve({ error: "timeout" });
    }, 8000);

    let data = "";
    ws.on("message", (msg) => {
      data += msg.toString();
      if (data.length > 500000) { // 500KB cap
        clearTimeout(timeout);
        ws.close();
        resolve({ data: data.slice(0, 500000) });
      }
    });
    ws.on("close", () => {
      clearTimeout(timeout);
      resolve({ data });
    });
    ws.on("error", (err) => {
      clearTimeout(timeout);
      resolve({ error: err.message });
    });
  });
}

(async () => {
  console.log("=== ws://localhost:7265/ ===");
  const r1 = await probe("/");
  console.log(JSON.stringify(r1, null, 2));

  console.log("\n=== ws://localhost:7265/json/list ===");
  const r2 = await probe("/json/list");
  console.log(JSON.stringify(r2, null, 2));

  console.log("\n=== ws://localhost:7265/json ===");
  const r3 = await probe("/json");
  console.log(JSON.stringify(r3, null, 2));

  console.log("\n=== ws://localhost:7265/devtools/page/00000000-0000-0000-0000-000000000000 ===");
  const r4 = await probe("/devtools/page/00000000-0000-0000-0000-000000000000");
  console.log(JSON.stringify(r4, null, 2));
})();