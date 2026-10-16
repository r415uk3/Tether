import AppKit

// A background-only login item: no Dock icon, no menu bar, just the USB watcher on the AppKit run loop
// (NSWorkspace wake notifications need it).
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let opener = TetherOpener()
let watcher = USBArrivalWatcher(onFileTransferArrival: { opener.open() })

app.run()
