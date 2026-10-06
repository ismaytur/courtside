// Courtside.app: a native window around the Courtside web app.
//
// On launch it makes sure ~/Library/Application Support/Courtside/repo is a clone of the GitHub
// repo, then runs `node scripts/app.mjs` there (which updates from GitHub, starts the server on a
// random port and prints COURTSIDE_PORT=<port>). Exit code 75 means "restart me" (an update was
// pulled); the page is reloaded when the new server is up. Quitting sends SIGTERM so the server can
// commit and push unsaved data first.
//
// Built by scripts/build-mac-app.sh, which also writes Resources/launch.json (node path, PATH, repo URL).

import Cocoa
import WebKit

struct LaunchConfig: Decodable {
    let repoURL: String
    let node: String
    let path: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var server: Process?
    private var port = 0
    private var quitting = false
    private var showingApp = false
    private var lineBuffer = Data()
    private var logHandle: FileHandle?

    private let config: LaunchConfig = {
        guard let url = Bundle.main.url(forResource: "launch", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(LaunchConfig.self, from: data) else {
            fatalError("launch.json missing from the app bundle; rebuild with npm run build:app")
        }
        return cfg
    }()
    private let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Courtside")
    private var repoDir: URL { supportDir.appendingPathComponent("repo") }
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Courtside.log")

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        openLog()
        buildMenu()

        let cfg = WKWebViewConfiguration()
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Courtside"
        window.minSize = NSSize(width: 720, height: 480)
        window.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("CourtsideMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        showStatus("Starting…")
        DispatchQueue.global(qos: .userInitiated).async { self.prepareAndStart() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server, server.isRunning else { return .terminateNow }
        quitting = true
        server.terminate() // SIGTERM: the server saves and pushes, then exits
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: server

    private func prepareAndStart() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
            showStatus("Downloading Courtside from GitHub…")
            try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: repoDir)
            let (ok, output) = run("/usr/bin/env", ["git", "clone", "--branch", "main", config.repoURL, repoDir.path])
            log(output)
            if !ok {
                showError("Couldn't clone \(config.repoURL).", detail: output)
                return
            }
        }
        DispatchQueue.main.async { self.startServer() }
    }

    private func startServer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.node)
        p.arguments = ["--no-warnings=ExperimentalWarning", "scripts/app.mjs"]
        p.currentDirectoryURL = repoDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config.path
        env["PORT"] = String(port) // 0 the first time (random); then the same port across restarts
        env["COURTSIDE_APP"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lineBuffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.serverExited(proc.terminationStatus) }
        }
        do {
            try p.run()
            server = p
        } catch {
            showError("Couldn't start Node at \(config.node).", detail: "\(error)\n\nRebuild the app with `npm run build:app` if Node moved.")
        }
    }

    private func serverExited(_ code: Int32) {
        server = nil
        if quitting { NSApp.reply(toApplicationShouldTerminate: true); return }
        if code == 75 {
            log("[app] restarting after update")
            startServer()
            return
        }
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").suffix(40).joined(separator: "\n") ?? ""
        showError("The Courtside server stopped (exit code \(code)).", detail: tail)
    }

    private func consume(_ data: Data) {
        logHandle?.write(data)
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if line.hasPrefix("COURTSIDE_PORT="), let n = Int(line.dropFirst("COURTSIDE_PORT=".count)) {
                DispatchQueue.main.async { self.serverReady(port: n) }
            } else if line.hasPrefix("COURTSIDE_STATUS=") {
                showStatus(String(line.dropFirst("COURTSIDE_STATUS=".count)))
            }
        }
    }

    private func serverReady(port n: Int) {
        port = n
        if showingApp, webView.url?.port == n {
            webView.reload() // restarted after an update: keep the current filters (URL hash)
        } else {
            showingApp = true
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(n)/")!))
        }
    }

    @objc private func restartServer() {
        if let server, server.isRunning { server.terminate(); return } // exit is handled by serverExited
        DispatchQueue.global(qos: .userInitiated).async { self.prepareAndStart() }
    }

    // MARK: status / error pages

    private func showStatus(_ message: String) {
        DispatchQueue.main.async {
            guard !self.showingApp else { return } // restarts are quick; keep the page
            self.webView.loadHTMLString(Self.page(body: """
                <div class="spinner"></div><p>\(Self.escape(message))</p>
                """), baseURL: nil)
        }
    }

    private func showError(_ message: String, detail: String) {
        DispatchQueue.main.async {
            self.showingApp = false
            self.webView.loadHTMLString(Self.page(body: """
                <h2>\(Self.escape(message))</h2>
                <p><a href="courtside://retry">Try again</a> · <a href="courtside://logs">Open log</a></p>
                <pre>\(Self.escape(detail))</pre>
                """), baseURL: nil)
        }
    }

    private static func page(body: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#0d0f12;color:#e8ebf0;font:14px -apple-system,sans-serif}
        body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:24px;box-sizing:border-box}
        a{color:#f26b1d} h2{margin:0;font-size:18px} p{margin:0;color:#8b93a1}
        pre{max-width:900px;max-height:50vh;overflow:auto;background:#151920;border:1px solid #262c37;border-radius:10px;padding:12px;font:12px ui-monospace,monospace;color:#8b93a1;white-space:pre-wrap}
        .spinner{width:28px;height:28px;border-radius:50%;border:3px solid #262c37;border-top-color:#f26b1d;animation:s .8s linear infinite}
        @keyframes s{to{transform:rotate(360deg)}}
        </style>\(body)
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: web view

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "courtside" {
            if url.host == "retry" { restartServer() }
            if url.host == "logs" { NSWorkspace.shared.open(logURL) }
            return decisionHandler(.cancel)
        }
        let local = url.host == "127.0.0.1" || url.host == "localhost"
        if local || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url) // Mega, source pages, .torrent downloads: default browser
        decisionHandler(.cancel)
    }

    // target="_blank" links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); let menu = NSMenu(title: title)
            items.forEach(menu.addItem); item.submenu = menu; main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i
        }
        submenu("Courtside", [
            item("About Courtside", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Courtside", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Courtside", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Reload", #selector(reloadPage), "r"),
            item("Open in Browser", #selector(openInBrowser), "o", [.command, .shift]),
            .separator(),
            item("Restart Server", #selector(restartServer), "r", [.command, .shift]),
            item("Show Log", #selector(showLog), "l", [.command, .shift]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    @objc private func reloadPage() { if showingApp { webView.reload() } else { restartServer() } }
    @objc private func openInBrowser() {
        if port > 0 { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!) }
    }
    @objc private func showLog() { NSWorkspace.shared.open(logURL) }

    // MARK: helpers

    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        log("---- Courtside launched \(Date())")
    }

    private func log(_ s: String) { logHandle?.write((s + "\n").data(using: .utf8)!) }

    private func run(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config.path
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus == 0, out)
    }
}

// MARK: icon rendering (used by the build script: Courtside --render-icon out.png)

func renderIcon(to path: String) {
    let size = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // macOS icon grid: 824pt rounded square centered in 1024.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1))!.draw(in: bg, angle: -90)
    // basketball
    let r: CGFloat = 270, c = NSPoint(x: s / 2, y: s / 2)
    let ball = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSGradient(starting: NSColor(red: 1.0, green: 0.52, blue: 0.2, alpha: 1),
               ending: NSColor(red: 0.85, green: 0.35, blue: 0.08, alpha: 1))!.draw(in: ball, angle: -60)
    NSColor(red: 0.1, green: 0.06, blue: 0.03, alpha: 1).setStroke()
    let seams = NSBezierPath()
    seams.lineWidth = 16
    seams.move(to: NSPoint(x: c.x - r, y: c.y)); seams.line(to: NSPoint(x: c.x + r, y: c.y))
    seams.move(to: NSPoint(x: c.x, y: c.y - r)); seams.line(to: NSPoint(x: c.x, y: c.y + r))
    for side: CGFloat in [-1, 1] {
        seams.move(to: NSPoint(x: c.x + side * r * 0.7, y: c.y + r * 0.71))
        seams.curve(to: NSPoint(x: c.x + side * r * 0.7, y: c.y - r * 0.71),
                    controlPoint1: NSPoint(x: c.x + side * r * 0.18, y: c.y + r * 0.3),
                    controlPoint2: NSPoint(x: c.x + side * r * 0.18, y: c.y - r * 0.3))
    }
    seams.stroke()
    ball.lineWidth = 16
    ball.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: main

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--render-icon" {
    renderIcon(to: args[2])
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
