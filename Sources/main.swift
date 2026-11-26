// Artifact Widgets — pin claude.ai artifacts (or any web page) to the macOS desktop as live widgets.
// Each widget is a chrome-less window at desktop level holding a WKWebView. A small pill appears on hover:
// drag it to move the widget, click ≡ to switch artifacts or change settings. ⌘-drag anywhere also moves a widget.
// All widgets share one persistent website data store, so one claude.ai sign-in covers them all.

import AppKit
import WebKit
import ServiceManagement

let safariUASuffix = "Version/26.0 Safari/605.1.15"

// MARK: - Config

struct LibraryItem: Codable, Equatable {
    var title: String
    var url: String
}

/// Saved list starts empty for new users; "From Your Account" lists their artifacts automatically.
let defaultLibrary: [LibraryItem] = []

struct WidgetConfig: Codable {
    var id: String = UUID().uuidString
    var url: String
    var title: String = ""
    var x: Double = 200
    var y: Double = 200
    var w: Double = 520
    var h: Double = 380
    var refreshMinutes: Int = 15
    var zoom: Double = 1.0
    var trimTop: Double = 0
    var clean: Bool = true

    init(url: String, title: String = "") {
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case id, url, title, x, y, w, h, refreshMinutes, zoom, trimTop, clean }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 200
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 200
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 520
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 380
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 15
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        trimTop = try c.decodeIfPresent(Double.self, forKey: .trimTop) ?? 0
        clean = try c.decodeIfPresent(Bool.self, forKey: .clean) ?? true
    }
}

struct AppConfig: Codable {
    var widgets: [WidgetConfig] = []
    var library: [LibraryItem] = defaultLibrary
    var onTop: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey { case widgets, library, onTop }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        widgets = try c.decodeIfPresent([WidgetConfig].self, forKey: .widgets) ?? []
        library = try c.decodeIfPresent([LibraryItem].self, forKey: .library) ?? defaultLibrary
        onTop = try c.decodeIfPresent(Bool.self, forKey: .onTop) ?? false
    }
}

enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ArtifactWidgets")
    static let file = dir.appendingPathComponent("widgets.json")
    static let logFile = dir.appendingPathComponent("log.txt")
    /// Create this (empty) file to have every frame log a short content summary after load.
    static let debugFlag = dir.appendingPathComponent("debug")

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }
    static var debug: Bool { FileManager.default.fileExists(atPath: debugFlag.path) }

    static func load() -> AppConfig {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: file) else { return AppConfig() }
        do { return try JSONDecoder().decode(AppConfig.self, from: data) } catch {
            log("config parse error: \(error)")
            return AppConfig()
        }
    }

    static func save(_ c: AppConfig) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(c) { try? data.write(to: file, options: .atomic) }
    }
}

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: Store.logFile) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: Store.logFile)
    }
}

func normalizedURL(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if !s.contains("://") { s = "https://" + s }
    guard let u = URL(string: s), u.host != nil else { return nil }
    return u.absoluteString
}

// MARK: - Clean mode (hide claude.ai chrome)

/// claude.ai artifact page: top bar, bottom "Ask Claude" toolbar, tips.
let pageCSS = """
#top-edge, header#hdr, main > .cds-root { display: none !important; }
main { position: fixed !important; inset: 0 !important; margin: 0 !important; padding: 0 !important; height: 100vh !important; }
#frame-slot { position: absolute !important; inset: 0 !important; height: 100% !important; }
#frame-content { width: 100% !important; height: 100% !important; }
[data-radix-popper-content-wrapper], [role="tooltip"], [popover] { display: none !important; }
"""

/// Artifact frame (*.claudeusercontent.com): the runtime toolbar ("Updated now", Design, History, Sources) and scrollbars.
let frameCSS = """
header.tb-root { display: none !important; }
::-webkit-scrollbar { width: 0 !important; height: 0 !important; background: transparent !important; }
"""

let cleanModeJS = """
(() => {
  const h = location.hostname;
  let css = null;
  if (window === window.top && /(^|\\.)claude\\.ai$/.test(h)) css = \(String(reflecting: pageCSS));
  else if (/\\.claudeusercontent\\.com$/.test(h)) css = \(String(reflecting: frameCSS));
  if (!css) return;
  // claude.ai's CSP blocks <style> tags, but constructed stylesheets are allowed.
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(css);
  const ensure = () => {
    if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  };
  ensure();
  let n = 0;
  const t = setInterval(() => { ensure(); if (++n > 30) clearInterval(t); }, 1000);
})();
"""

let debugProbeJS = """
setTimeout(() => { try {
  const tb = document.querySelector('header.tb-root');
  window.webkit.messageHandlers.awProbe.postMessage(location.host + ' ' + innerWidth + 'x' + innerHeight +
    ' textLen=' + (document.body ? document.body.innerText.length : -1) +
    ' toolbar=' + (tb ? getComputedStyle(tb).display : 'none-found') +
    ' text=' + JSON.stringify((document.body ? document.body.innerText : '').slice(0, 160)));
} catch (e) {} }, 15000);
"""

final class ProbeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        log("probe: \(message.body)")
    }
}

func makeWebConfig() -> WKWebViewConfiguration {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default()
    cfg.applicationNameForUserAgent = safariUASuffix
    return cfg
}

// MARK: - Small UI helpers

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", on: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let m = NSMenu(title: title)
    items.forEach { m.addItem($0) }
    item.submenu = m
    return item
}

func disabledItem(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

@MainActor
func prompt(_ title: String, _ info: String, value: String, placeholder: String = "") -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = value
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

/// Asks for a URL (prefilled from the clipboard when it looks like one) and an optional name.
@MainActor
func urlDialog(title: String, info: String, button: String, withRefresh: Bool) -> (url: String, title: String, refresh: Int)? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info

    let width: CGFloat = 360
    let h: CGFloat = withRefresh ? 86 : 56
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
    let urlField = NSTextField(frame: NSRect(x: 0, y: h - 26, width: width, height: 24))
    urlField.placeholderString = "https://claude.ai/artifact/…"
    if let clip = NSPasteboard.general.string(forType: .string), clip.contains("claude.ai/") || clip.hasPrefix("http") {
        urlField.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let titleField = NSTextField(frame: NSRect(x: 0, y: h - 56, width: width, height: 24))
    titleField.placeholderString = "Name (e.g. Pipeline Dashboard)"
    let refresh = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26))
    let options = [0, 5, 15, 30, 60]
    refresh.addItems(withTitles: options.map { $0 == 0 ? "No auto-refresh" : "Refresh every \($0) min" })
    refresh.selectItem(at: 2)
    v.addSubview(urlField)
    v.addSubview(titleField)
    if withRefresh { v.addSubview(refresh) }
    alert.accessoryView = v
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = urlField

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    guard let u = normalizedURL(urlField.stringValue) else {
        let a = NSAlert()
        a.messageText = "That doesn't look like a URL."
        a.runModal()
        return nil
    }
    return (u, titleField.stringValue.trimmingCharacters(in: .whitespaces), options[max(0, refresh.indexOfSelectedItem)])
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ContainerView: NSView {
    var onLayout: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func resizeSubviews(withOldSize oldSize: NSSize) { onLayout?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Drag area of the hover pill: dragging it moves the widget.
final class DragHandle: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// MARK: - Widget

@MainActor
final class WidgetController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var config: WidgetConfig
    unowned let app: AppDelegate
    let window: WidgetWindow
    let container = ContainerView()
    let clip = NSView()
    let webView: WKWebView
    let pill = NSVisualEffectView()
    let grip = DragHandle()
    let gripIcon = NSImageView()
    let menuButton = NSButton()
    var timer: Timer?
    var lastLoaded: Date?
    var statusNote: String?
    private var hovering = false

    init(config: WidgetConfig, app: AppDelegate) {
        self.config = config
        self.app = app
        webView = WKWebView(frame: .zero, configuration: makeWebConfig())
        window = WidgetWindow(
            contentRect: NSRect(x: config.x, y: config.y, width: config.w, height: config.h),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        buildWindow()
        rescueIfOffscreen()
        applyLevel()
        load()
        scheduleTimer()
        window.orderFrontRegardless()
    }

    private func buildWindow() {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.minSize = NSSize(width: 200, height: 140)
        window.hasShadow = true
        window.delegate = self

        container.frame = NSRect(origin: .zero, size: window.frame.size)
        container.autoresizesSubviews = true
        container.onLayout = { [weak self] in self?.layoutWidget() }
        container.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.updatePill(animated: true)
        }
        window.contentView = container

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.clipsToBounds = true
        container.addSubview(clip)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.pageZoom = config.zoom
        webView.isInspectable = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        // Keep pages running while covered by other windows, so live data is current when you glance at the desktop.
        // (WebKit otherwise suspends pages in occluded windows. KVC reaches the private _setWindowOcclusionDetectionEnabled:.)
        if webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        } else {
            log("occlusion setting unavailable; widgets may pause while covered")
        }
        applyUserScripts()
        clip.addSubview(webView)

        // Hover pill: [move grip | ≡ menu]
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 13
        pill.layer?.masksToBounds = true
        pill.alphaValue = 0
        container.addSubview(pill)

        let small = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        gripIcon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                 accessibilityDescription: "Move")?.withSymbolConfiguration(small)
        gripIcon.contentTintColor = .secondaryLabelColor
        grip.toolTip = "Drag to move (or ⌘-drag anywhere on the widget)"
        grip.addSubview(gripIcon)
        pill.addSubview(grip)

        menuButton.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Widget menu")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.contentTintColor = .labelColor
        menuButton.toolTip = "Switch artifact and widget settings"
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        pill.addSubview(menuButton)

        layoutWidget()
        updateTitle()
    }

    func layoutWidget() {
        let b = container.bounds
        clip.frame = b
        webView.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height + CGFloat(config.trimTop))
        let pw: CGFloat = 60, ph: CGFloat = 26
        pill.frame = NSRect(x: b.width - pw - 10, y: b.height - ph - 10, width: pw, height: ph)
        grip.frame = NSRect(x: 0, y: 0, width: 30, height: ph)
        gripIcon.frame = NSRect(x: 9, y: 6, width: 14, height: 14)
        menuButton.frame = NSRect(x: 30, y: 0, width: 26, height: ph)
    }

    func updatePill(animated: Bool) {
        let visible = hovering || statusNote != nil
        menuButton.contentTintColor = statusNote != nil ? .systemOrange : .labelColor
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                pill.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            pill.alphaValue = visible ? 1 : 0
        }
    }

    private func rescueIfOffscreen() {
        let f = window.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }), let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2))
            saveFrame()
        }
    }

    func applyLevel() {
        if app.config.onTop {
            window.level = .floating
        } else {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    func applyUserScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        if config.clean {
            ucc.addUserScript(WKUserScript(source: cleanModeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if Store.debug {
            ucc.removeScriptMessageHandler(forName: "awProbe")
            ucc.add(ProbeHandler(), name: "awProbe")
            ucc.addUserScript(WKUserScript(source: debugProbeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
    }

    // MARK: loading

    func load() {
        guard let u = URL(string: config.url) else { statusNote = "bad URL"; updateTitle(); return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(retryLoad), object: nil)
        webView.load(URLRequest(url: u))
    }

    func switchTo(_ item: LibraryItem) {
        config.url = item.url
        config.title = item.title
        statusNote = nil
        lastLoaded = nil
        updateTitle()
        app.persist()
        load()
    }

    @objc private func retryLoad() { load() }
    @objc private func timerFired() { load() }
    @objc func reloadWidget(_ sender: Any?) { load() }

    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard config.refreshMinutes > 0 else { return }
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(config.refreshMinutes * 60), target: self,
                                     selector: #selector(timerFired), userInfo: nil, repeats: true)
        timer?.tolerance = 10
    }

    var displayName: String {
        if !config.title.isEmpty { return config.title }
        if let item = app.config.library.first(where: { $0.url == config.url }), !item.title.isEmpty { return item.title }
        return URL(string: config.url)?.host ?? "Widget"
    }

    func updateTitle() {
        window.title = displayName
        updatePill(animated: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastLoaded = Date()
        let path = webView.url?.path ?? ""
        let pageTitle = webView.title ?? ""
        if path.contains("login") || pageTitle.lowercased().hasPrefix("sign in") {
            statusNote = "Sign in needed"
        } else {
            statusNote = nil
            if config.title.isEmpty, !pageTitle.isEmpty, pageTitle != "Claude Artifact", pageTitle != "Claude" {
                config.title = pageTitle
                app.persist()
            }
        }
        log("loaded \(config.url) -> \(webView.url?.absoluteString ?? "?") title=\"\(pageTitle)\"")
        updateTitle()
        // The artifact page renders its "Sign in to view this page" gate client-side, so check the text shortly after load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkSignInGate() }
    }

    private func checkSignInGate() {
        webView.evaluateJavaScript("(document.body && document.body.innerText || '').slice(0, 400)") { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            if text.lowercased().contains("sign in to view") {
                self.statusNote = "Sign in needed"
                log("sign-in gate shown for \(self.config.url)")
                self.app.signInNeeded()
            } else if self.statusNote == "Sign in needed" {
                self.statusNote = nil
            }
            self.updateTitle()
        }
    }

    private func handleFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted
        log("load failed \(config.url): \(ns.localizedDescription)")
        statusNote = "Offline, retrying"
        updateTitle()
        perform(#selector(retryLoad), with: nil, afterDelay: 30)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handleFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { handleFailure(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Links clicked in the main frame that leave claude.ai open in the default browser.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           let u = action.request.url, let host = u.host, !host.hasSuffix("claude.ai") {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    // MARK: window

    func saveFrame() {
        let f = window.frame
        config.x = f.origin.x; config.y = f.origin.y; config.w = f.width; config.h = f.height
        app.persist()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    func close() {
        timer?.invalidate()
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        webView.stopLoading()
        window.delegate = nil
        window.close()
    }

    // MARK: burger menu

    @objc private func menuClicked() {
        app.account.refreshIfStale()
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: menuButton)
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        if let note = statusNote {
            m.addItem(disabledItem("⚠︎ \(note)"))
            if note == "Sign in needed" {
                m.addItem(ActionItem("Sign in to claude.ai…") { [weak self] in self?.app.openLogin() })
            }
            m.addItem(.separator())
        }

        m.addItem(NSMenuItem.sectionHeader(title: "Show artifact"))
        m.addItem(submenu("From Your Account", app.accountMenuItems(current: config.url) { [weak self] a in
            self?.switchTo(LibraryItem(title: a.title, url: a.url))
        }))
        m.addItem(.separator())
        var currentInLibrary = false
        for item in app.config.library {
            let isCurrent = artifactKey(item.url) == artifactKey(config.url)
            currentInLibrary = currentInLibrary || isCurrent
            m.addItem(ActionItem(item.title.isEmpty ? item.url : item.title, on: isCurrent) { [weak self] in
                guard let self, !isCurrent else { return }
                self.switchTo(item)
            })
        }
        if !currentInLibrary {
            m.addItem(ActionItem(displayName, on: true) {})
        }
        m.addItem(ActionItem("Add Artifact to List…") { [weak self] in
            guard let self, let r = urlDialog(title: "Add Artifact", info: "Paste a claude.ai artifact link. It will show in every widget's list.",
                                              button: "Add & Show", withRefresh: false) else { return }
            let item = LibraryItem(title: r.title, url: r.url)
            self.app.addToLibrary(item)
            self.switchTo(item)
        })
        if currentInLibrary {
            m.addItem(ActionItem("Remove “\(displayName)” from List") { [weak self] in
                guard let self else { return }
                self.app.config.library.removeAll { artifactKey($0.url) == artifactKey(self.config.url) }
                self.app.persist()
            })
        }

        m.addItem(.separator())
        m.addItem(ActionItem("Reload") { [weak self] in self?.load() })
        m.addItem(submenu("Auto-refresh", [0, 1, 5, 15, 30, 60, 240].map { mins in
            ActionItem(mins == 0 ? "Off" : "Every \(mins) min", on: config.refreshMinutes == mins) { [weak self] in
                self?.config.refreshMinutes = mins
                self?.scheduleTimer()
                self?.app.persist()
            }
        }))
        m.addItem(submenu("Zoom", [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25].map { z in
            ActionItem("\(Int((z * 100).rounded()))%", on: abs(config.zoom - z) < 0.001) { [weak self] in
                self?.config.zoom = z
                self?.webView.pageZoom = z
                self?.app.persist()
            }
        }))
        m.addItem(ActionItem("Hide claude.ai Toolbars", on: config.clean) { [weak self] in
            guard let self else { return }
            self.config.clean.toggle()
            self.applyUserScripts()
            self.app.persist()
            self.load()
        })
        m.addItem(ActionItem("Open in Browser") { [weak self] in
            if let s = self?.config.url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        })
        if let t = lastLoaded {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            m.addItem(disabledItem("Loaded at \(f.string(from: t))"))
        }

        m.addItem(.separator())
        m.addItem(submenu("New Widget", app.newWidgetMenuItems()))
        m.addItem(ActionItem("Remove This Widget") { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Remove the “\(self.displayName)” widget?"
            a.informativeText = "This only removes the widget from your desktop. The artifact itself is not touched."
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { self.app.remove(self) }
        })
        return m
    }
}

// MARK: - Sign-in window

@MainActor
final class LoginController: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    var popups: [NSWindow] = []
    let onClose: () -> Void
    private var closing = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let rect = NSRect(x: 0, y: 0, width: 980, height: 780)
        webView = WKWebView(frame: rect, configuration: makeWebConfig())
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Sign in to Claude (closes automatically once you're in)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.center()
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let u = webView.url, u.host?.hasSuffix("claude.ai") == true else { return }
        let p = u.path
        if p == "/new" || p.hasPrefix("/chat") || p.hasPrefix("/recents") || p.hasPrefix("/project") {
            log("sign-in complete (\(p))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.window.close() }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // OAuth (e.g. Google) opens a popup; give it a real window sharing the same session.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let pv = WKWebView(frame: w.contentLayoutRect, configuration: configuration)
        pv.uiDelegate = self
        w.contentView = pv
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return pv
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = webView.window, w !== window {
            w.close()
            popups.removeAll { $0 === w }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        popups.forEach { $0.close() }
        popups.removeAll()
        onClose()
    }
}

// MARK: - Account artifacts (live list from claude.ai)

struct AccountArtifact: Codable {
    var title: String
    var url: String
    var rel: String        // "mine" or "shared"
    var kind: String
    var lastViewed: String
}

/// Fetches the signed-in user's artifacts by loading claude.ai's Artifacts gallery in a hidden, off-screen web view
/// and copying the list the page itself requests (GET /api/frame/artifacts). Uses the app's existing claude.ai session.
@MainActor
final class AccountArtifacts: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var items: [AccountArtifact] = []
    private(set) var lastFetch: Date?
    private(set) var fetching = false
    private(set) var lastError: String?
    private var window: NSWindow?
    private var webView: WKWebView?
    static let cacheFile = Store.dir.appendingPathComponent("account_artifacts.json")
    static let galleryURL = URL(string: "https://claude.ai/artifacts")!

    /// Runs in the gallery page before its own scripts: copies the page's own artifact-list response to us.
    static let sniffJS = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.awArtifacts.postMessage(m); } catch (e) {} };
      const of = window.fetch;
      window.fetch = async function(input, init) {
        const r = await of.apply(this, arguments);
        try {
          const u = typeof input === 'string' ? input : (input && input.url) || String(input);
          if (u.includes('/api/frame/artifacts?')) {
            r.clone().json().then(j => post(JSON.stringify({ ok: r.ok, status: r.status,
              artifacts: (j.artifacts || []).filter(a => a.open_url).map(a => ({
                title: a.title || '', url: a.open_url, rel: a.rel || '', kind: a.kind || '', lastViewed: a.last_viewed_at || ''
              })) }))).catch(() => post(JSON.stringify({ ok: false, status: r.status })));
          }
        } catch (e) {}
        return r;
      };
      setTimeout(() => {
        if (/login/.test(location.pathname) || /sign in/i.test(document.body ? document.body.innerText.slice(0, 300) : ''))
          post(JSON.stringify({ ok: false, status: 401 }));
      }, 8000);
    })();
    """

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.cacheFile),
           let cached = try? JSONDecoder().decode([AccountArtifact].self, from: data) {
            items = cached
        }
    }

    func refreshIfStale() {
        if fetching { return }
        if let t = lastFetch, Date().timeIntervalSince(t) < 300 { return }
        refresh()
    }

    func refresh() {
        guard !fetching else { return }
        fetching = true
        lastError = nil
        let cfg = makeWebConfig()
        cfg.userContentController.add(self, name: "awArtifacts")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.sniffJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Off-screen window so the page runs normally (a window-less web view can be throttled).
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let wv = WKWebView(frame: w.contentLayoutRect, configuration: cfg)
        if wv.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            wv.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        wv.navigationDelegate = self
        w.contentView = wv
        w.orderBack(nil)
        window = w
        webView = wv
        wv.load(URLRequest(url: Self.galleryURL))
        perform(#selector(timedOut), with: nil, afterDelay: 45)
    }

    @objc private func timedOut() { finish(error: "timed out") }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error: "network: \(error.localizedDescription)")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard fetching, let s = message.body as? String, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let status = obj["status"] as? Int ?? 0
        guard obj["ok"] as? Bool == true else {
            finish(error: status == 401 || status == 403 ? "not signed in" : "HTTP \(status)")
            return
        }
        let raw = (obj["artifacts"] as? [[String: Any]]) ?? []
        items = raw.map {
            AccountArtifact(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "",
                            rel: $0["rel"] as? String ?? "", kind: $0["kind"] as? String ?? "",
                            lastViewed: $0["lastViewed"] as? String ?? "")
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.cacheFile, options: .atomic) }
        log("account artifacts: \(items.count) (\(items.filter { $0.rel == "mine" }.count) mine)")
        finish(error: nil)
    }

    private func finish(error: String?) {
        guard fetching else { return }
        fetching = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timedOut), object: nil)
        if let error {
            lastError = error
            log("account artifacts failed: \(error)")
        } else {
            lastFetch = Date()
        }
        // Tear down the hidden gallery page.
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "awArtifacts")
        webView?.navigationDelegate = nil
        webView = nil
        window?.close()
        window = nil
    }
}

/// Last path component of an artifact link, used to match links that differ only in query string or form.
func artifactKey(_ url: String) -> String {
    URL(string: url)?.lastPathComponent ?? url
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config = Store.load()
    var controllers: [WidgetController] = []
    var statusItem: NSStatusItem!
    var login: LoginController?
    let account = AccountArtifacts()
    private var promptedSignIn = false
    private var dragMonitor: Any?

    /// Picklist of the account's artifacts (mine, then shared with me), most recently viewed first.
    func accountMenuItems(current: String? = nil, _ pick: @escaping (AccountArtifact) -> Void) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let mine = account.items.filter { $0.rel == "mine" }
        let shared = account.items.filter { $0.rel != "mine" }
        if account.items.isEmpty {
            if account.fetching { out.append(disabledItem("Loading your artifacts…")) }
            else if let e = account.lastError {
                out.append(disabledItem("Couldn't load (\(e))"))
                if e == "not signed in" { out.append(ActionItem("Sign in to claude.ai…") { [weak self] in self?.openLogin() }) }
            }
            else { out.append(disabledItem("No artifacts found")) }
        }
        for (header, group) in [("My artifacts", mine), ("Shared with me", shared)] where !group.isEmpty {
            out.append(NSMenuItem.sectionHeader(title: header))
            for a in group.prefix(80) {
                let isCurrent = current.map { artifactKey($0) == artifactKey(a.url) } ?? false
                out.append(ActionItem(a.title.isEmpty ? a.url : a.title, on: isCurrent) { pick(a) })
            }
        }
        out.append(.separator())
        out.append(ActionItem(account.fetching ? "Refreshing…" : "Refresh List") { [weak self] in self?.account.refresh() })
        if let t = account.lastFetch {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            out.append(disabledItem("\(account.items.count) artifacts · updated \(f.string(from: t))"))
        }
        return out
    }

    /// "New Widget" picklist: account artifacts, the saved list, or any link.
    func newWidgetMenuItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = [
            submenu("From Your Account", accountMenuItems { [weak self] a in self?.add(url: a.url, title: a.title, refresh: 15) }),
            .separator(),
            NSMenuItem.sectionHeader(title: "Saved list"),
        ]
        out += config.library.map { item in
            ActionItem(item.title.isEmpty ? item.url : item.title) { [weak self] in self?.add(url: item.url, title: item.title, refresh: 15) }
        }
        out.append(.separator())
        out.append(ActionItem("Other Link…") { [weak self] in self?.addDialog() })
        return out
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Artifact Widgets")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        config.widgets.forEach { controllers.append(WidgetController(config: $0, app: self)) }
        persist()

        // ⌘-drag anywhere on a widget moves it.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.modifierFlags.contains(.command), let w = event.window as? WidgetWindow {
                w.performDrag(with: event)
                return nil
            }
            return event
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let claude = cookies.filter { $0.domain.hasSuffix("claude.ai") }
            let hasSession = claude.contains { $0.name == "sessionKey" }
            log("launch: \(self.controllers.count) widgets, \(claude.count) claude.ai cookies, session=\(hasSession)")
            DispatchQueue.main.async {
                if !hasSession {
                    self.promptedSignIn = true
                    self.openLogin()
                } else {
                    self.account.refresh()
                    if self.controllers.isEmpty { self.showWelcome() }
                }
            }
        }
    }

    /// Shown when signed in with no widgets yet: points at the menu bar icon and opens its menu.
    func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Artifact Widgets is ready"
        a.informativeText = """
        Add your first widget from the grid icon in the menu bar: New Widget → From Your Account.

        Hover a widget to show its controls: drag the arrows to move it, click ≡ to switch artifacts or change settings. Drag an edge to resize.
        """
        a.addButton(withTitle: "Show Me")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.statusItem.button?.performClick(nil) }
        }
    }

    func persist() {
        config.widgets = controllers.map { $0.config }
        Store.save(config)
    }

    func addToLibrary(_ item: LibraryItem) {
        if let i = config.library.firstIndex(where: { $0.url == item.url }) {
            if !item.title.isEmpty { config.library[i].title = item.title }
        } else {
            config.library.append(item)
        }
        persist()
    }

    func add(url: String, title: String, refresh: Int) {
        var w = WidgetConfig(url: url, title: title)
        w.refreshMinutes = refresh
        if let vf = NSScreen.main?.visibleFrame {
            let off = Double((controllers.count % 6) * 32)
            w.x = vf.midX - w.w / 2 + off
            w.y = vf.midY - w.h / 2 - off
        }
        controllers.append(WidgetController(config: w, app: self))
        persist()
    }

    func remove(_ c: WidgetController) {
        c.close()
        controllers.removeAll { $0 === c }
        persist()
    }

    func reloadAll() { controllers.forEach { $0.load() } }

    @objc func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.reloadAll() }
    }

    /// Called when a widget lands on claude.ai's sign-in gate. Opens the sign-in window once per launch.
    func signInNeeded() {
        guard !promptedSignIn, login == nil else { return }
        promptedSignIn = true
        openLogin()
    }

    func openLogin() {
        if login == nil {
            login = LoginController { [weak self] in
                guard let self else { return }
                self.login = nil
                self.reloadAll()
                self.account.refresh()
                if self.controllers.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showWelcome() }
                }
            }
        }
        login?.show()
    }

    func rebuildFromDisk() {
        controllers.forEach { $0.close() }
        controllers.removeAll()
        config = Store.load()
        config.widgets.forEach { controllers.append(WidgetController(config: $0, app: self)) }
    }

    // MARK: menus

    private func setupMainMenu() {
        // Needed so Cmd+C/V/X/A and Cmd+R work inside widgets and dialogs (accessory apps have no visible menu).
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Widget", action: #selector(WidgetController.reloadWidget(_:)), keyEquivalent: "r")
        viewItem.submenu = view
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        account.refreshIfStale()
        menu.addItem(submenu("New Widget", newWidgetMenuItems()))
        menu.addItem(.separator())

        if controllers.isEmpty { menu.addItem(disabledItem("No widgets yet")) }
        for c in controllers {
            menu.addItem(submenu(c.displayName, [
                ActionItem("Bring to Front") {
                    NSApp.activate(ignoringOtherApps: true)
                    c.window.orderFrontRegardless()
                    c.window.makeKey()
                },
                ActionItem("Reload") { c.load() },
                ActionItem("Open in Browser") { if let u = URL(string: c.config.url) { NSWorkspace.shared.open(u) } },
                .separator(),
                ActionItem("Remove") { [weak self] in self?.remove(c) },
            ]))
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Reload All", key: "r") { [weak self] in self?.reloadAll() })
        menu.addItem(ActionItem("Keep Widgets Above Windows", on: config.onTop) { [weak self] in
            guard let self else { return }
            self.config.onTop.toggle()
            self.controllers.forEach { $0.applyLevel() }
            self.persist()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Sign in to claude.ai…") { [weak self] in self?.openLogin() })
        menu.addItem(ActionItem("Launch at Login", on: SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                NSAlert(error: error).runModal()
            }
        })
        menu.addItem(ActionItem("Edit Config File (artifact list)") { NSWorkspace.shared.open(Store.file) })
        menu.addItem(ActionItem("Reload Config File") { [weak self] in self?.rebuildFromDisk() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Artifact Widgets", key: "q") { NSApp.terminate(nil) })
    }

    func addDialog() {
        guard let r = urlDialog(title: "New Widget", info: "Paste a claude.ai artifact link (or any web page URL).",
                                button: "Add", withRefresh: true) else { return }
        if r.url.contains("claude.ai/") { addToLibrary(LibraryItem(title: r.title, url: r.url)) }
        add(url: r.url, title: r.title, refresh: r.refresh)
    }
}

// MARK: - Entry

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
