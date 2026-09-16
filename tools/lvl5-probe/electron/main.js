// Minimal Electron probe host: one BrowserWindow over the same probe page
// the chromium legs use (title records every keydown). This is the ticket's
// actual consumer class — the Claude desktop app is an Electron app on the
// native Wayland Ozone path.
const { app, BrowserWindow } = require("electron");
const path = require("path");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 900,
    height: 600,
    show: true,
    title: "PROBE-WAY|boot",
  });
  win.loadFile(path.join(process.env.HOME, "lvl5-probe", "probe-way.html"));
});
