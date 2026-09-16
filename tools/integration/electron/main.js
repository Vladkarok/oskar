const { app, BrowserWindow } = require("electron");
const path = require("path");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 640,
    height: 320,
    show: true,
    title: "OSK-ELECTRON|boot",
  });
  win.loadFile(path.join(__dirname, "probe.html"));
});
