enum WebAssets {
    static let indexHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iPhone iOS Remote Screen</title>
<style>
  :root { color-scheme: light dark; --bg:#f4f4f6; --fg:#1c1c1e; --muted:#6e6e73; --panel:#ffffff; --border:#d2d2d7; --accent:#0a84ff; }
  @media (prefers-color-scheme: dark) { :root { --bg:#111113; --fg:#f2f2f7; --muted:#98989d; --panel:#1c1c1e; --border:#38383a; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:14px -apple-system, system-ui, sans-serif; height:100vh; display:flex; flex-direction:column; }
  header { display:flex; gap:8px; align-items:center; padding:10px 16px; background:var(--panel); border-bottom:1px solid var(--border); flex-wrap:wrap; }
  header h1 { font-size:15px; margin:0 12px 0 0; }
  button { font:inherit; padding:6px 12px; border-radius:8px; border:1px solid var(--border); background:var(--bg); color:var(--fg); cursor:pointer; }
  button:hover { border-color:var(--accent); }
  button.danger { color:#ff453a; }
  button.danger:hover { border-color:#ff453a; }
  #status { margin-left:auto; color:var(--muted); font-variant-numeric:tabular-nums; }
  main { flex:1; display:flex; align-items:center; justify-content:center; padding:16px; min-height:0; }
  #screen { max-width:100%; max-height:100%; border-radius:28px; background:#000; touch-action:none; outline:none; cursor:crosshair; }
  #screen:focus { box-shadow:0 0 0 3px var(--accent); }
  #empty { color:var(--muted); text-align:center; max-width:420px; line-height:1.5; }
  .hint { color:var(--muted); font-size:12px; }
</style>
</head>
<body>
<header>
  <h1>iPhone iOS Remote Screen</h1>
  <button data-action="home" title="Cmd-1 in iPhone Mirroring">Home</button>
  <button data-action="appSwitcher" title="Cmd-2 in iPhone Mirroring">App Switcher</button>
  <button data-action="spotlight" title="Cmd-3 in iPhone Mirroring">Spotlight</button>
  <span class="hint">Click the screen to type</span>
  <button id="stop" class="danger" hidden title="Stop the relay on the server and close the tunnel">Stop session</button>
  <span id="status">connecting…</span>
</header>
<main>
  <canvas id="screen" tabindex="0" hidden></canvas>
  <div id="empty">Waiting for the iPhone Mirroring window on the server. Make sure the app is open, connected, and the server has Screen Recording permission.</div>
</main>
<script>
(() => {
  const token = new URLSearchParams(location.search).get("token") || "";
  const canvas = document.getElementById("screen");
  const ctx = canvas.getContext("2d");
  const statusEl = document.getElementById("status");
  const empty = document.getElementById("empty");
  const stopBtn = document.getElementById("stop");
  let stopped = false;
  function showStopped() {
    statusEl.textContent = "session stopped";
    canvas.hidden = true; empty.hidden = false;
    empty.textContent = "Session stopped. The relay on the server has exited and the SSH tunnel is closing. You can close this tab.";
    stopBtn.hidden = true;
  }
  stopBtn.addEventListener("click", () => {
    stopped = true;
    send({ t: "shutdown" });
    setTimeout(showStopped, 300);
  });
  let ws, frames = 0, lastFpsAt = performance.now(), fps = 0, server = {}, pending = null, drawing = false, down = false, lastMove = 0;

  function connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(`${proto}//${location.host}/ws?token=${encodeURIComponent(token)}`);
    ws.binaryType = "blob";
    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") {
        const msg = JSON.parse(ev.data);
        if (msg.t === "status") { server = msg; stopBtn.hidden = !msg.allowShutdown; render(); }
        if (msg.t === "stopped") { stopped = true; showStopped(); }
        return;
      }
      pending = ev.data;
      if (!drawing) drawNext();
    };
    ws.onclose = () => {
      if (stopped) return showStopped();
      statusEl.textContent = "disconnected, retrying…";
      setTimeout(connect, 1000);
    };
    ws.onopen = () => render();
  }

  async function drawNext() {
    if (!pending) return;
    drawing = true;
    const blob = pending; pending = null;
    try {
      const bmp = await createImageBitmap(blob);
      if (canvas.width !== bmp.width || canvas.height !== bmp.height) { canvas.width = bmp.width; canvas.height = bmp.height; }
      ctx.drawImage(bmp, 0, 0);
      bmp.close();
      canvas.hidden = false; empty.hidden = true;
      frames++;
    } catch (e) {}
    drawing = false;
    if (pending) drawNext();
  }

  function render() {
    const now = performance.now();
    if (now - lastFpsAt >= 1000) { fps = frames * 1000 / (now - lastFpsAt); frames = 0; lastFpsAt = now; }
    const parts = [ws && ws.readyState === 1 ? "connected" : "connecting…", `${fps.toFixed(0)} fps`];
    if (server.viewOnly) parts.push("view only");
    if (server.inputAvailable === false) parts.push("input unavailable for this source");
    statusEl.textContent = parts.join(" · ");
  }
  setInterval(render, 500);

  const send = (o) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); };
  function norm(e) {
    const r = canvas.getBoundingClientRect();
    return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
  }
  canvas.addEventListener("pointerdown", (e) => {
    canvas.focus(); canvas.setPointerCapture(e.pointerId); down = true;
    send({ t: "down", ...norm(e) }); e.preventDefault();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!down) return;
    const now = performance.now();
    if (now - lastMove < 16) return;
    lastMove = now; send({ t: "move", ...norm(e) });
  });
  const end = (e) => { if (!down) return; down = false; send({ t: "up", ...norm(e) }); };
  canvas.addEventListener("pointerup", end);
  canvas.addEventListener("pointercancel", end);
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const k = e.deltaMode === 1 ? 16 : 1;
    send({ t: "scroll", ...norm(e), dx: e.deltaX * k, dy: e.deltaY * k });
  }, { passive: false });
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());

  canvas.addEventListener("keydown", (e) => {
    const mods = [];
    if (e.shiftKey) mods.push("shift");
    if (e.ctrlKey) mods.push("control");
    if (e.altKey) mods.push("option");
    if (e.metaKey) mods.push("command");
    const printable = e.key.length === 1 && !e.ctrlKey && !e.metaKey;
    if (printable) send({ t: "text", s: e.key });
    else if (!["Shift", "Control", "Alt", "Meta"].includes(e.key)) send({ t: "key", code: e.code, mods });
    e.preventDefault();
  });
  canvas.addEventListener("paste", (e) => {
    const s = e.clipboardData.getData("text");
    if (s) send({ t: "text", s: s.slice(0, 4000) });
    e.preventDefault();
  });

  document.querySelectorAll("[data-action]").forEach((b) =>
    b.addEventListener("click", () => { send({ t: "action", name: b.dataset.action }); canvas.focus(); }));
  connect();
})();
</script>
</body>
</html>
"""#
}
