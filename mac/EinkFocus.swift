import Cocoa
import Carbon.HIToolbox
import Speech
import AVFoundation

/// One computer the keyboard can follow the Kindle onto.
struct Remote {
    var id: String
    var label: String
    var user: String
    var host: String
    var port: Int
    var tmux: String

    /// MagicDNS name without the tailnet suffix. Tailscale status prints this form.
    var hostname: String {
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return host.hasSuffix(".ts.net") ? first : host
    }
}

/// Settings live in a JSON file so names and addresses stay out of the source.
/// docs/configuration.md describes every key.
struct Config {
    var path: URL
    var modified: Date?
    var warning: String?
    var tmux: String
    var tailscale: String
    var kindleHostname: String
    var kindleHostnames: [String]
    /// Tailscale hostname → the name shown on the card. A Kindle without one shows its hostname.
    var kindleLabels: [String: String]
    var identity: String
    /// The Kindle's host list, the same file connect.sh reads. Sets the order of computers.
    var hosts: String
    /// The id of this Mac's row in the host list.
    var thisComputer: String
    /// The checkout, when the app was built from one. Holds the terminfo source.
    var root: URL?
    var remotes: [Remote]

    /// The checkout the app was built from. mac/build.sh writes it into Info.plist.
    static var buildRoot: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "EinkFocusRoot") as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// First match wins: `defaults write dev.eterm.einkfocus ConfigPath <file>`, then
    /// config/eink-focus.json in the checkout the app was built from, then Application Support.
    static func candidates() -> [URL] {
        var list: [URL] = []
        if let path = UserDefaults.standard.string(forKey: "ConfigPath"), !path.isEmpty {
            list.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        if let root = buildRoot {
            list.append(root.appendingPathComponent("config/eink-focus.json"))
        }
        list.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Eink Focus/config.json")
        )
        return list
    }

    /// Relative paths in the file start at the checkout when the file is in its config/
    /// folder, and at the file's own folder otherwise.
    static func resolve(_ path: String, base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
    }

    static func load() -> Config {
        let list = candidates()
        let url = list.first { FileManager.default.fileExists(atPath: $0.path) } ?? list[0]
        let folder = url.deletingLastPathComponent()
        let base = folder.lastPathComponent == "config" ? folder.deletingLastPathComponent() : folder
        let root = buildRoot ?? (folder.lastPathComponent == "config" ? base : nil)
        var config = Config(
            path: url,
            modified: nil,
            warning: nil,
            tmux: "/opt/homebrew/bin/tmux",
            tailscale: "/usr/local/bin/tailscale",
            kindleHostname: "kindle",
            kindleHostnames: ["kindle"],
            kindleLabels: [:],
            identity: "",
            hosts: resolve("kindle/eterm/hosts", base: root ?? base),
            thisComputer: "personal",
            root: root,
            remotes: []
        )
        config.modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let data = try? Data(contentsOf: url) else {
            config.warning = "No config at \(url.path)"
            return config
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            config.warning = "Config is not valid JSON"
            return config
        }
        if let tmux = json["tmux"] as? String, !tmux.isEmpty { config.tmux = tmux }
        if let tailscale = json["tailscale"] as? String, !tailscale.isEmpty { config.tailscale = tailscale }
        if let name = json["kindleHostname"] as? String, !name.isEmpty { config.kindleHostname = name }
        if let names = json["kindleHostnames"] as? [String] {
            let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !cleaned.isEmpty { config.kindleHostnames = cleaned }
        }
        if !config.kindleHostnames.contains(config.kindleHostname) {
            config.kindleHostnames.insert(config.kindleHostname, at: 0)
        }
        if let labels = json["kindleLabels"] as? [String: String] {
            config.kindleLabels = labels.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        }
        if let identity = json["identity"] as? String, !identity.isEmpty {
            config.identity = resolve(identity, base: base)
        }
        if let hosts = json["hosts"] as? String, !hosts.isEmpty {
            config.hosts = resolve(hosts, base: base)
        }
        if let id = json["thisComputer"] as? String, !id.isEmpty {
            config.thisComputer = id
        }
        if let rows = json["remotes"] as? [[String: Any]] {
            config.remotes = rows.compactMap { row in
                guard let id = row["id"] as? String,
                      let label = row["label"] as? String,
                      let user = row["user"] as? String,
                      let host = row["host"] as? String,
                      !id.isEmpty, !host.isEmpty, !user.isEmpty else { return nil }
                let port = row["port"] as? Int ?? 22
                let remoteTmux = (row["tmux"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? config.tmux
                return Remote(id: id, label: label, user: user, host: host, port: port, tmux: remoteTmux)
            }
        }
        App.kindleLabels = config.kindleLabels
        return config
    }
}

/// One row from the Kindle host list, in the same order connect.sh walks it.
private struct ComputerStop {
    var id: String
    var label: String
    var ready: Bool
    /// Position among ready rows, starting at zero. Nil when the host is REPLACE.
    var readyIndex: Int?
}

/// One parsed `tailscale status`, shared so the card never waits on it.
private struct TailSnapshot {
    var ipNames: [String: String] = [:]
    var peers: [String: Bool] = [:]
    var selfIP: String?
    var ready = false
}

private struct CommandResult {
    var text: String
    var status: Int32
}

private enum SwitchAttempt {
    case sent
    case oldLogin
    case failed
}

private struct Probe {
    var sightings: [App.Sighting]
    var known: Bool
}

/// Sends the Mac keyboard into the tmux session attached on the Kindle,
/// then gives focus back to whatever app was in front.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: KeyPanel?
    private var card: DeskCard?
    private var composer = LineComposer()
    private var ghost = ""
    private var ghostUntil = Date.distantPast
    private var attachedLabels: [String] = []
    private var cardNotice: String?
    private var statusLine: String?
    private var noticeToken = 0
    private var blinkTimer: Timer?
    private var lastMeter = CFAbsoluteTime(0)
    private var previousApp: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var dictateHotKey: EventHotKeyRef?
    private var swapHotKey: EventHotKeyRef?
    private var hostHotKey: EventHotKeyRef?
    private var deviceHotKey: EventHotKeyRef?
    private var backHotKey: EventHotKeyRef?
    private var forwardHotKey: EventHotKeyRef?
    private var dimHotKey: EventHotKeyRef?
    private var brightHotKey: EventHotKeyRef?
    private var pinHotKey: EventHotKeyRef?
    /// Last real tmux client, kept while the card shows a move in progress.
    private var anchorDestination: Destination?
    /// Computer the rail shows before the Kindle has finished reconnecting.
    private var pendingComputerID: String?
    private var pendingClearToken = 0
    private var switchInFlight = false
    private var cardOpacity = DeskCard.savedOpacity()
    /// Stays on screen after the keyboard goes back to another app. Escape still closes it.
    private var pinned = DeskCard.savedPinned()
    /// Dictate was asked for before a Kindle was attached. Starts on the next adopt.
    private var dictateWhenReady = false
    private var dictationStarting = false
    /// On-device recognition failed once. The next request is allowed to use the network.
    private var recognitionUsesNetwork = false
    private var recognitionFailures = 0
    /// Ignores the key-window change caused by our own activate or close.
    private var adjustingFocus = false
    private var closing = false
    /// Which Kindle receives keys when more than one is logged in. Nil follows the only one.
    private var targetDevice: String?
    private var currentLabel = "Kindle"
    private var followTimer: Timer?
    private var lastRemoteLook = Date.distantPast
    private var followGeneration = 0
    private var followPending = false
    /// True while the card is up and the Kindle's tmux client is not adopted yet.
    private var seeking = false
    private var loaderArmed = false
    private var loaderVisible = false
    private var loaderToken = 0
    private var moveToken = 0
    private var sessionToken = 0
    private var menuToken = 0
    private var menuLocal: [Sighting] = []
    private var lastFound: [Sighting] = []
    /// Keeps the key pipe from being torn down on every follow tick.
    private var pipeKey: String?
    private let cacheLock = NSLock()
    private var tailCache = TailSnapshot()
    private var tailFetched = Date.distantPast
    private var handler: EventHandlerRef?
    private(set) var isCapturing = false
    private var destination: Destination?
    private var listening = false
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var dictationCommitted = ""
    private var dictationLatest = ""
    private var settleTimer: Timer?
    private let recognizer = SFSpeechRecognizer()
    private let sendQueue = DispatchQueue(label: "eink-focus.send", qos: .userInteractive)
    private let ioQueue = DispatchQueue(label: "eink-focus.io", qos: .userInitiated, attributes: .concurrent)
    private var config = Config.load()
    private let remoteKeys = RemoteKeys()
    private let localKeys = LocalKeys()
    private static var stopMemo: (exists: Bool, stamp: Date?, stops: [ComputerStop])?
    private var tmux: String { config.tmux }
    private var kindleStatusItem: NSMenuItem?
    private var macStatusItem: NSMenuItem?
    private var kindleNodeItem: NSMenuItem?
    private var remoteStatusItems: [String: NSMenuItem] = [:]

    private let hotKeyCode: UInt32 = UInt32(kVK_ANSI_K)
    private let hotKeyMods: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        registerHotKey()
        let tmux = config.tmux
        ioQueue.async { [weak self] in
            Self.teachKindleTerminal(tmux: tmux)
            guard let self else { return }
            let tail = self.names(maxAge: 0)
            let local = Self.localSightings(tmux: self.config.tmux, names: tail.ipNames)
            DispatchQueue.main.async {
                self.menuLocal = local
                self.paintConnection(local: local, tail: tail)
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        let kindle = NSMenuItem(title: "Kindle", action: nil, keyEquivalent: "")
        kindle.isEnabled = false
        menu.addItem(kindle)
        kindleStatusItem = kindle
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Send keys to Kindle", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let dictate = NSMenuItem(title: "Dictate to Kindle    ⌃⌥⌘D", action: #selector(dictateFromMenu), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        let swap = NSMenuItem(title: "Next tmux session", action: #selector(swapFromMenu), keyEquivalent: "")
        swap.target = self
        menu.addItem(swap)
        let previous = NSMenuItem(title: "Previous computer    ⌃⌥⌘[", action: #selector(previousComputerFromMenu), keyEquivalent: "")
        previous.target = self
        menu.addItem(previous)
        let host = NSMenuItem(title: "Next computer    ⌃⌥⌘]", action: #selector(hostFromMenu), keyEquivalent: "")
        host.target = self
        menu.addItem(host)
        let device = NSMenuItem(title: "Next Kindle    ⌃⌥⌘J", action: #selector(deviceFromMenu), keyEquivalent: "")
        device.target = self
        menu.addItem(device)
        let dimmer = NSMenuItem(title: "Decrease opacity    ⌃⌥⌘−", action: #selector(dimmerFromMenu), keyEquivalent: "")
        dimmer.target = self
        menu.addItem(dimmer)
        let brighter = NSMenuItem(title: "Increase opacity    ⌃⌥⌘=", action: #selector(brighterFromMenu), keyEquivalent: "")
        brighter.target = self
        menu.addItem(brighter)
        let pin = NSMenuItem(title: "Pin card    ⌃⌥⌘P", action: #selector(pinFromMenu), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        let reset = NSMenuItem(title: "Reset card position", action: #selector(resetCardPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let mac = NSMenuItem(title: "This Mac", action: nil, keyEquivalent: "")
        mac.isEnabled = false
        menu.addItem(mac)
        macStatusItem = mac
        let node = NSMenuItem(title: "Kindle Tailscale", action: nil, keyEquivalent: "")
        node.isEnabled = false
        menu.addItem(node)
        kindleNodeItem = node
        statusItem.menu = menu
        rebuildRemoteMenuItems()
        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Open config", action: #selector(revealConfig), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let quit = NSMenuItem(title: "Quit Eink Focus", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        setMenuIcon(on: false)
        paintConnection(local: [], tail: TailSnapshot())
    }

    func menuWillOpen(_ menu: NSMenu) {
        let modified = try? config.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if modified != config.modified {
            config = Config.load()
            rebuildRemoteMenuItems()
        }
        paintConnection(local: menuLocal, tail: cachedNames())
        menuToken += 1
        let token = menuToken
        let config = self.config
        ioQueue.async { [weak self] in
            guard let self else { return }
            let tail = self.names(maxAge: 4)
            let local = Self.localSightings(tmux: config.tmux, names: tail.ipNames)
            DispatchQueue.main.async {
                guard self.menuToken == token else { return }
                self.menuLocal = local
                self.paintConnection(local: local, tail: tail)
            }
        }
    }

    private func rebuildRemoteMenuItems() {
        guard let menu = statusItem.menu, let anchor = kindleNodeItem else { return }
        for item in remoteStatusItems.values {
            menu.removeItem(item)
        }
        remoteStatusItems.removeAll()
        var index = menu.index(of: anchor) + 1
        if config.remotes.isEmpty {
            let item = NSMenuItem(title: "No remotes in config", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: index)
            remoteStatusItems["__none"] = item
            return
        }
        for remote in config.remotes {
            let item = NSMenuItem(title: remote.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: index)
            remoteStatusItems[remote.id] = item
            index += 1
        }
    }

    private func paintConnection(local: [Sighting], tail: TailSnapshot) {
        if let warning = config.warning {
            kindleStatusItem?.title = warning
        }
        if isCapturing, let destination {
            kindleStatusItem?.title = "Typing · \(currentLabel) · \(destination.session)"
        } else if local.isEmpty {
            kindleStatusItem?.title = "No Kindle is on this Mac"
        } else {
            kindleStatusItem?.title = local.map { "\($0.label) · \($0.destination.session)" }.joined(separator: ", ")
        }
        if local.isEmpty {
            macStatusItem?.title = "This Mac · no Kindle client"
        } else {
            macStatusItem?.title = local.map { "\($0.label) · \($0.destination.session)" }.joined(separator: ", ")
        }
        let kindleLine = config.kindleHostnames.map { name in
            "\(name) \(Self.presence(tail.ready ? tail.peers[name] : nil))"
        }.joined(separator: ", ")
        kindleNodeItem?.title = "Tailscale · \(kindleLine)"
        for remote in config.remotes {
            var title = "\(remote.label) · \(Self.presence(tail.ready ? tail.peers[remote.hostname] : nil))"
            if isCapturing, case .remote(let current, let session, _) = destination, current.id == remote.id {
                title = "\(remote.label) · \(session)"
            }
            remoteStatusItems[remote.id]?.title = title
        }
    }

    /// Cached Tailscale map. A stale cache is refreshed here, so call it off the main thread.
    private func names(maxAge: TimeInterval) -> TailSnapshot {
        cacheLock.lock()
        let fresh = tailCache.ready && Date().timeIntervalSince(tailFetched) < maxAge
        let cached = tailCache
        cacheLock.unlock()
        if fresh { return cached }
        let snap = Self.readTail(bin: config.tailscale, hostnames: config.kindleHostnames)
        cacheLock.lock()
        if snap.ready {
            tailCache = snap
            tailFetched = Date()
        }
        let result = snap.ready ? snap : tailCache
        cacheLock.unlock()
        return result
    }

    private func cachedNames() -> TailSnapshot {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return tailCache
    }

    private static func presence(_ online: Bool?) -> String {
        switch online {
        case true: return "online"
        case false: return "offline"
        case nil: return "no status"
        }
    }

    /// One `tailscale status` plus this machine's address. Offline nodes stay in the map so labels still resolve.
    fileprivate static func readTail(bin: String, hostnames: [String]) -> TailSnapshot {
        var snap = TailSnapshot()
        let wanted = Set(hostnames)
        let text = output([bin, "status"], timeout: 2.5)
        guard !text.isEmpty else { return snap }
        snap.ready = true
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let ip = String(parts[0])
            guard ip.split(separator: ".").count == 4 else { continue }
            let name = String(parts[1])
            snap.peers[name] = !line.contains("offline")
            if wanted.contains(name) { snap.ipNames[ip] = name }
        }
        let selfIP = output([bin, "ip", "-4"], timeout: 1.5).trimmingCharacters(in: .whitespacesAndNewlines)
        if selfIP.contains(".") { snap.selfIP = selfIP }
        return snap
    }

    @objc private func revealConfig() {
        if FileManager.default.fileExists(atPath: config.path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([config.path])
        } else {
            let example = config.path.deletingLastPathComponent().appendingPathComponent("eink-focus.example.json")
            NSWorkspace.shared.activateFileViewerSelecting([example])
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleFromMenu() { toggle() }
    @objc private func dictateFromMenu() { toggleDictation() }
    @objc private func swapFromMenu() { cycleSession() }
    @objc private func hostFromMenu() { stepComputer(1) }
    @objc private func previousComputerFromMenu() { stepComputer(-1) }
    @objc private func deviceFromMenu() { cycleDevice() }
    @objc private func dimmerFromMenu() { nudgeOpacity(-1) }
    @objc private func brighterFromMenu() { nudgeOpacity(1) }
    @objc private func pinFromMenu() { togglePin() }

    func toggle() {
        ensureCard()
        if panel?.isVisible != true {
            capture()
            return
        }
        if !isCapturing {
            resumeCapture()
            return
        }
        if pinned {
            focusCard()
            return
        }
        release()
    }

    func togglePin() {
        pinned.toggle()
        UserDefaults.standard.set(pinned, forKey: DeskCard.pinKey)
        panel?.hidesOnDeactivate = !pinned
        if !pinned, panel?.isVisible == true, panel?.isKeyWindow != true {
            release(restorePrevious: false)
            return
        }
        refreshComposer(present: panel?.isVisible == true)
    }

    private func capture() {
        previousApp = NSWorkspace.shared.frontmostApplication
        isCapturing = true
        destination = nil
        pendingComputerID = nil
        pendingClearToken += 1
        switchInFlight = false
        moveToken += 1
        seeking = true
        cardNotice = nil
        statusLine = nil
        noticeToken += 1
        resetComposer()
        armLoader("Finding the Kindle.", delay: 0.12)
        refreshComposer(present: true)
        setMenuIcon(on: true)
        focusCard()
        startFollow()
    }

    /// Pinned card, keyboard already given back. Pick up the keys again without a new search.
    private func resumeCapture() {
        guard panel?.isVisible == true else {
            capture()
            return
        }
        if previousApp == nil {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        isCapturing = true
        setMenuIcon(on: true)
        if followTimer == nil { startFollow() }
        refreshComposer(present: true)
        focusCard()
        if dictateWhenReady, destination != nil { beginDictationAfterAuth() }
    }

    private func focusCard() {
        adjustingFocus = true
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        if let card, let panel {
            panel.makeFirstResponder(card)
        }
        adjustingFocus = false
    }

    private func release(restorePrevious: Bool = true) {
        guard !closing else { return }
        closing = true
        isCapturing = false
        dictateWhenReady = false
        dictationStarting = false
        if listening { stopDictation(flush: true) }
        followGeneration += 1
        followTimer?.invalidate()
        followTimer = nil
        followPending = false
        destination = nil
        anchorDestination = nil
        pendingComputerID = nil
        pendingClearToken += 1
        switchInFlight = false
        moveToken += 1
        seeking = false
        clearLoader()
        pipeKey = nil
        remoteKeys.stop()
        localKeys.stop()
        resetComposer()
        cardNotice = nil
        statusLine = nil
        noticeToken += 1
        card?.setBusy(false)
        hideCard()
        setMenuIcon(on: false)
        let previous = previousApp
        previousApp = nil
        closing = false
        if restorePrevious {
            previous?.activate(options: [.activateAllWindows])
        }
    }

    /// Pin keeps the card up. The keyboard goes back to the app the user clicked.
    private func pauseCapture() {
        guard isCapturing else { return }
        isCapturing = false
        if listening { stopDictation(flush: true) }
        setMenuIcon(on: false)
        refreshComposer(present: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !adjustingFocus, !closing else { return }
        guard notification.object as? NSWindow === panel else { return }
        if pinned, panel?.isVisible == true {
            pauseCapture()
        } else if isCapturing {
            release(restorePrevious: false)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !adjustingFocus, !closing else { return }
        guard notification.object as? NSWindow === panel else { return }
        guard panel?.isVisible == true, !isCapturing else { return }
        isCapturing = true
        setMenuIcon(on: true)
        if let card, let panel {
            panel.makeFirstResponder(card)
        }
        if followTimer == nil { startFollow() }
        refreshComposer(present: true)
        if dictateWhenReady, destination != nil { beginDictationAfterAuth() }
    }

    private func setMenuIcon(on: Bool) {
        let image = Self.menuBarImage(active: on, listening: listening)
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    /// A tiny e-ink slab. Idle is an outline, typing fills the cursor, dictation adds a dot.
    private static func menuBarImage(active: Bool, listening: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.set()
        let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 1.25, width: 10, height: 15.5), xRadius: 1.8, yRadius: 1.8)
        body.lineWidth = active || listening ? 1.7 : 1.2
        body.stroke()
        NSBezierPath(rect: NSRect(x: 6.5, y: 5, width: active ? 2.3 : 1.4, height: 6.4)).fill()
        if listening {
            NSBezierPath(ovalIn: NSRect(x: 11, y: 12.4, width: 3.6, height: 3.6)).fill()
        }
        image.unlockFocus()
        return image
    }

    private func resetComposer() {
        composer = LineComposer()
        ghost = ""
        ghostUntil = .distantPast
    }

    private func ensureCard() {
        if panel != nil, card != nil { return }
        let window = KeyPanel(
            contentRect: NSRect(origin: .zero, size: DeskCard.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = !pinned
        window.becomesKeyOnlyIfNeeded = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.alphaValue = cardOpacity
        let view = DeskCard(frame: NSRect(origin: .zero, size: DeskCard.windowSize))
        view.opacity = cardOpacity
        view.onStep = { [weak self] delta in self?.stepComputer(delta) }
        view.onSelect = { [weak self] id in self?.selectComputer(id) }
        view.onOpacity = { [weak self] delta in self?.nudgeOpacity(delta) }
        view.onDragEnd = { [weak self] in self?.saveCardOrigin() }
        view.onResizeEnd = { [weak self] in self?.saveCardSize() }
        view.onPin = { [weak self] in self?.togglePin() }
        view.onInsert = { [weak self] text in
            guard let self, self.isCapturing, !self.listening, self.destination != nil else { return }
            self.composer.insert(text)
            self.refreshComposer()
            self.send(Data(text.utf8))
        }
        window.delegate = self
        window.contentView = view
        panel = window
        card = view
    }

    /// Saved position when it still lands on a connected display, otherwise under the menu bar.
    private func cardOrigin() -> NSPoint? {
        guard let panel else { return nil }
        let size = panel.frame.size
        if let saved = savedCardOrigin(), DeskCard.originOnScreen(saved, size: size) {
            return DeskCard.clampedOrigin(saved, size: size)
        }
        guard let fallback = defaultCardOrigin(size: size) else { return nil }
        return DeskCard.clampedOrigin(fallback, size: size)
    }

    private func defaultCardOrigin(size: NSSize) -> NSPoint? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let shellTop = visible.maxY - 14
        let windowTop = shellTop + DeskCard.pad
        return NSPoint(x: visible.midX - size.width / 2, y: windowTop - size.height)
    }

    private func savedCardOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DeskCard.originXKey) != nil,
              defaults.object(forKey: DeskCard.originYKey) != nil else { return nil }
        return NSPoint(x: defaults.double(forKey: DeskCard.originXKey), y: defaults.double(forKey: DeskCard.originYKey))
    }

    private func saveCardOrigin() {
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: DeskCard.originXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: DeskCard.originYKey)
    }

    private func saveCardSize() {
        guard let panel else { return }
        let shell = DeskCard.clampedShell(NSSize(
            width: panel.frame.width - DeskCard.pad * 2,
            height: panel.frame.height - DeskCard.pad * 2
        ))
        UserDefaults.standard.set(Double(shell.width), forKey: DeskCard.widthKey)
        UserDefaults.standard.set(Double(shell.height), forKey: DeskCard.heightKey)
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: DeskCard.originXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: DeskCard.originYKey)
    }

    @objc private func resetCardPosition() {
        UserDefaults.standard.removeObject(forKey: DeskCard.originXKey)
        UserDefaults.standard.removeObject(forKey: DeskCard.originYKey)
        ensureCard()
        guard let panel, let dest = defaultCardOrigin(size: panel.frame.size) else { return }
        let clamped = DeskCard.clampedOrigin(dest, size: panel.frame.size)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                panel.animator().setFrameOrigin(clamped)
            }
        } else {
            panel.setFrameOrigin(clamped)
            showNotice("Card position reset")
        }
    }

    /// direction +1 is more opaque, -1 is more transparent.
    func nudgeOpacity(_ direction: Int) {
        let steps = DeskCard.opacitySteps
        let index = steps.enumerated().min(by: { abs($0.element - cardOpacity) < abs($1.element - cardOpacity) })?.offset ?? 0
        let next = min(steps.count - 1, max(0, index - direction))
        applyOpacity(steps[next], announce: !isCapturing)
    }

    private func applyOpacity(_ value: CGFloat, announce: Bool) {
        guard abs(value - cardOpacity) > 0.001 else { return }
        cardOpacity = value
        UserDefaults.standard.set(Double(value), forKey: DeskCard.opacityKey)
        card?.opacity = value
        if panel?.isVisible == true {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel?.animator().alphaValue = value
            }
        } else {
            panel?.alphaValue = value
        }
        card?.needsDisplay = true
        if announce {
            let percent = Int((value * 100).rounded())
            showNotice("Opacity \(percent)%")
        }
    }

    private func showCard() {
        ensureCard()
        guard let panel, let dest = cardOrigin() else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: dest.x, y: dest.y + 10))
            panel.orderFrontRegardless()
            let opacity = cardOpacity
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().setFrameOrigin(dest)
                panel.animator().alphaValue = opacity
            }
        }
        startBlink()
    }

    private func hideCard() {
        panel?.orderOut(nil)
        stopBlink()
    }

    private func startBlink() {
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let card = self?.card else { return }
            card.cursorOn.toggle()
            card.needsDisplay = true
        }
        blinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    private var speechPending: String {
        guard listening else { return "" }
        let latest = dictationLatest.replacingOccurrences(of: "\n", with: " ")
        if latest.isEmpty { return "" }
        if dictationCommitted.isEmpty { return latest }
        if latest.hasPrefix(dictationCommitted) {
            return String(latest.dropFirst(dictationCommitted.count))
        }
        return ""
    }

    /// Shows the brass sweep only if the work is still going after a short pause, so a fast lookup does not flicker.
    private func armLoader(_ message: String, delay: TimeInterval) {
        loaderToken += 1
        let token = loaderToken
        loaderArmed = true
        let apply = { [weak self] in
            guard let self, self.loaderToken == token, self.loaderArmed else { return }
            self.loaderVisible = true
            self.statusLine = message
            self.refreshComposer(present: true)
        }
        if delay <= 0 {
            loaderVisible = true
            statusLine = message
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
    }

    private func clearLoader() {
        loaderToken += 1
        loaderArmed = false
        loaderVisible = false
    }

    private func hintItems() -> [DeskCard.Hint] {
        if pinned && !isCapturing {
            return [
                DeskCard.Hint(chord: "click", verb: "focus"),
                DeskCard.Hint(chord: "⌃⌥⌘k", verb: "type"),
            ]
        }
        var items = [
            DeskCard.Hint(chord: "esc", verb: "close"),
            DeskCard.Hint(chord: "⇧tab", verb: "computer"),
        ]
        if attachedLabels.count > 1 {
            items.append(DeskCard.Hint(chord: "⌃⇧tab", verb: "kindle"))
        }
        items.append(DeskCard.Hint(chord: "⌃⌥⌘d", verb: listening ? "done" : "dictate"))
        items.append(DeskCard.Hint(chord: "⌃⌥⌘s", verb: "session"))
        return items
    }

    private func refreshComposer(present: Bool = false) {
        ensureCard()
        guard let card else { return }
        let current = (currentLabel.isEmpty ? "Kindle" : currentLabel).uppercased()
        let showDevice = !(destination == nil && attachedLabels.isEmpty && !seeking && !switchInFlight && !loaderVisible)
        card.device = showDevice ? current : "NO KINDLE"
        card.others = attachedLabels.map { $0.uppercased() }.filter { $0 != card.device }
        card.place = destination?.place.uppercased() ?? ""
        card.session = destination?.session ?? ""
        card.linked = destination != nil
        card.listening = listening
        card.line = composer.text
        card.cursor = composer.cursor
        card.pending = speechPending
        card.ghost = ghost
        card.ghostUntil = ghostUntil
        card.notice = cardNotice
        let loading = cardNotice == nil && (switchInFlight || loaderVisible)
        card.setBusy(loading)
        if cardNotice != nil {
            card.waiting = nil
        } else if destination == nil {
            if switchInFlight || loaderVisible {
                card.waiting = statusLine ?? "Finding the Kindle."
            } else if seeking {
                card.waiting = ""
            } else {
                card.waiting = statusLine ?? "Open Terminal on the Kindle\nand pick a computer."
            }
        } else if loaderVisible, let statusLine {
            card.waiting = statusLine
        } else {
            card.waiting = nil
        }
        card.pinned = pinned
        card.live = isCapturing
        card.dictateArmed = dictateWhenReady && !listening
        card.hints = hintItems()
        card.opacity = cardOpacity
        let stops = Self.computerStops(config: config)
        let selected = pendingComputerID ?? Self.computerID(for: destination, in: stops, thisComputer: config.thisComputer)
        card.setPlaces(stops.map {
            DeskCard.Place(id: $0.id, label: $0.label, ready: $0.ready, selected: $0.id == selected)
        })
        card.needsDisplay = true
        if present || panel?.isVisible == true {
            showCard()
        }
    }

    private func showNotice(_ text: String) {
        noticeToken += 1
        let token = noticeToken
        cardNotice = text
        refreshComposer(present: true)
        let stay = isCapturing
        DispatchQueue.main.asyncAfter(deadline: .now() + (stay ? 1.7 : 2.6)) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.cardNotice = nil
            if self.isCapturing {
                self.refreshComposer(present: true)
            } else {
                self.hideCard()
            }
        }
    }

    /// Keeps the on-screen line aligned with the keys just sent to tmux.
    private func noteNamed(_ key: String) {
        switch key {
        case "BSpace", "C-h":
            composer.backspace()
        case "DC", "C-d":
            composer.deleteForward()
        case "C-w":
            composer.deleteWordBackward()
        case "M-d", "M-D":
            composer.deleteWordForward()
        case "C-u":
            composer.killToStart()
        case "C-k":
            composer.killToEnd()
        case "C-a", "Home":
            composer.moveToStart()
        case "C-e", "End":
            composer.moveToEnd()
        case "Left", "C-b":
            composer.move(-1)
        case "Right", "C-f":
            composer.move(1)
        case "M-b", "M-B":
            composer.wordBackward()
        case "M-f", "M-F":
            composer.wordForward()
        case "Enter", "C-j", "M-Enter":
            let sent = composer.text.trimmingCharacters(in: .whitespaces)
            composer.submit()
            if !sent.isEmpty {
                ghost = sent
                ghostUntil = Date().addingTimeInterval(4)
            }
        case "C-c":
            composer.submit()
            ghost = ""
            ghostUntil = .distantPast
        default:
            return
        }
        refreshComposer()
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let channels = buffer.floatChannelData {
            let samples = channels[0]
            var sum: Float = 0
            for i in 0..<frames {
                let s = samples[i]
                sum += s * s
            }
            return CGFloat(sqrt(sum / Float(frames)))
        }
        if let channels = buffer.int16ChannelData {
            let samples = channels[0]
            var sum: Float = 0
            let scale: Float = 1 / 32768
            for i in 0..<frames {
                let s = Float(samples[i]) * scale
                sum += s * s
            }
            return CGFloat(sqrt(sum / Float(frames)))
        }
        return 0
    }

    private func noteLevel(_ buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMeter < 0.05 { return }
        lastMeter = now
        let raw = Self.rms(buffer)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.listening, let card = self.card else { return }
            let target = min(1, raw * 18)
            card.micLevel = card.micLevel * 0.4 + target * 0.6
            card.needsDisplay = true
        }
    }

    /// Returns true when the key was sent to the Kindle. False lets macOS keep it
    /// (volume, brightness, and anything we do not understand).
    func handleKey(_ event: NSEvent) -> Bool {
        guard isCapturing else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = event.keyCode
        let mods = flags.intersection([.command, .shift, .option, .control])

        if code == UInt16(kVK_Escape), mods.isEmpty {
            if listening {
                stopDictation(flush: true)
            } else {
                release()
            }
            return true
        }
        if code == UInt16(kVK_Tab), mods == .shift {
            if listening { flushDictation(addTrailingSpace: true) }
            stepComputer(1)
            return true
        }
        // Command-Shift-Tab is the system app switcher and usually never arrives.
        // Control-Shift-Tab is the chord that does, and both switch Kindles.
        if code == UInt16(kVK_Tab), mods == [.shift, .control] || mods == [.shift, .command] {
            if listening { flushDictation(addTrailingSpace: true) }
            cycleDevice()
            return true
        }
        if flags.contains(.control) && flags.contains(.option) && flags.contains(.command) {
            return true
        }
        if destination == nil {
            if navigationKey(code, flags: flags) != nil { return true }
            if flags.contains(.command) { return true }
            if let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                return true
            }
            return false
        }
        if listening {
            settleTimer?.invalidate()
            flushDictation(addTrailingSpace: false)
        }
        if flags.contains(.command) {
            return handleCommand(event)
        }
        if let name = navigationKey(code, flags: flags) {
            sendNamed(name)
            return true
        }
        if flags.contains(.control) || flags.contains(.option), let name = modifiedCharacter(event, flags: flags) {
            sendNamed(name)
            return true
        }
        if let text = event.characters, !text.isEmpty {
            composer.insert(text)
            refreshComposer()
            send(Data(text.utf8))
            return true
        }
        return false
    }

    /// Mac editing chords, translated into the bindings zsh, tmux, Claude, and Grok already use.
    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case UInt16(kVK_LeftArrow):
            sendNamed("C-a")
        case UInt16(kVK_RightArrow):
            sendNamed("C-e")
        case UInt16(kVK_UpArrow):
            sendNamed("PPage")
        case UInt16(kVK_DownArrow):
            sendNamed("NPage")
        case UInt16(kVK_Delete):
            sendNamed("C-u")
        case UInt16(kVK_ForwardDelete):
            sendNamed("C-k")
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            sendNamed("Enter")
        default:
            switch key {
            case "v":
                paste()
            case "c":
                copyPane()
            case "a":
                sendNamed("C-a")
            case "e":
                sendNamed("C-e")
            case "k":
                sendNamed("C-l")
            case "z":
                sendNamed("C-_")
            case "w", "q", "t", "n":
                break
            default:
                if flags.contains(.option) || flags.contains(.control) {
                    return false
                }
                return true
            }
        }
        return true
    }

    /// Arrows, editing, and function keys, including Control and Option.
    /// Option-Left/Right/Delete are the word motions Terminal.app sends.
    private func navigationKey(_ code: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        switch code {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if flags.contains(.shift) || control { return "C-j" }
            if option { return "M-Enter" }
            return "Enter"
        case UInt16(kVK_Tab):
            return flags.contains(.shift) ? "BTab" : "Tab"
        case UInt16(kVK_Delete):
            if option || control { return "C-w" }
            return "BSpace"
        case UInt16(kVK_ForwardDelete):
            if option || control { return "M-d" }
            return "DC"
        case UInt16(kVK_Escape):
            return "Escape"
        case UInt16(kVK_LeftArrow):
            if option { return "M-b" }
            return prefixed("Left", flags: flags)
        case UInt16(kVK_RightArrow):
            if option { return "M-f" }
            return prefixed("Right", flags: flags)
        case UInt16(kVK_UpArrow):
            return prefixed("Up", flags: flags)
        case UInt16(kVK_DownArrow):
            return prefixed("Down", flags: flags)
        case UInt16(kVK_Home):
            return "Home"
        case UInt16(kVK_End):
            return "End"
        case UInt16(kVK_PageUp):
            return "PPage"
        case UInt16(kVK_PageDown):
            return "NPage"
        case UInt16(kVK_F1): return "F1"
        case UInt16(kVK_F2): return "F2"
        case UInt16(kVK_F3): return "F3"
        case UInt16(kVK_F4): return "F4"
        case UInt16(kVK_F5): return "F5"
        case UInt16(kVK_F6): return "F6"
        case UInt16(kVK_F7): return "F7"
        case UInt16(kVK_F8): return "F8"
        case UInt16(kVK_F9): return "F9"
        case UInt16(kVK_F10): return "F10"
        case UInt16(kVK_F11): return "F11"
        case UInt16(kVK_F12): return "F12"
        default:
            return nil
        }
    }

    private func prefixed(_ key: String, flags: NSEvent.ModifierFlags) -> String {
        var name = ""
        if flags.contains(.control) { name += "C-" }
        if flags.contains(.option) { name += "M-" }
        if flags.contains(.shift) { name += "S-" }
        return name + key
    }

    /// Option is Meta, so Option-x is the terminal chord instead of a special character.
    private func modifiedCharacter(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        guard var raw = event.charactersIgnoringModifiers, raw.count == 1 else { return nil }
        if raw == " " { raw = "Space" }
        if raw == "Space" {
            if flags.contains(.control) && flags.contains(.option) { return "C-M-Space" }
            if flags.contains(.control) { return "C-Space" }
            return "M-Space"
        }
        let letter = flags.contains(.shift) ? raw.uppercased() : raw.lowercased()
        if flags.contains(.control) && flags.contains(.option) { return "C-M-\(letter)" }
        if flags.contains(.control) { return "C-\(letter)" }
        if flags.contains(.option) { return "M-\(letter)" }
        return nil
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        composer.insert(text)
        refreshComposer()
        var data = Data()
        if text.contains("\n") {
            data.append(Data("\u{1b}[200~".utf8))
            data.append(Data(text.utf8))
            data.append(Data("\u{1b}[201~".utf8))
        } else {
            data.append(Data(text.utf8))
        }
        send(data)
    }

    private func copyPane() {
        guard let destination else { return }
        let tmux = self.tmux
        let remoteKeys = self.remoteKeys
        prepareRemote(destination)
        ioQueue.async {
            let text: String
            switch destination {
            case .here(let session, _):
                text = Self.captureLocal(tmux: tmux, session: session)
            case .remote(_, let session, _):
                text = remoteKeys.capture(session: session)
            }
            let trimmed = text.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
            DispatchQueue.main.async {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(trimmed, forType: .string)
            }
        }
    }

    private static func captureLocal(tmux: String, session: String) -> String {
        let mode = output([tmux, "display-message", "-p", "-t", session, "#{pane_in_mode}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "1" {
            _ = output([tmux, "send-keys", "-t", session, "-X", "copy-selection-and-cancel"])
            return output([tmux, "show-buffer"])
        }
        return output([tmux, "capture-pane", "-t", session, "-p", "-J"])
    }

    private func sendNamed(_ key: String) {
        guard let destination else { return }
        noteNamed(key)
        let tmux = self.tmux
        let remoteKeys = self.remoteKeys
        let localKeys = self.localKeys
        prepareRemote(destination)
        sendQueue.async {
            switch destination {
            case .here(let session, _):
                localKeys.send(session: session, tmux: tmux, line: "K \(key)")
            case .remote(_, let session, _):
                remoteKeys.send(session: session, line: "K \(key)")
            }
        }
    }

    private func send(_ data: Data) {
        guard !data.isEmpty, let destination else { return }
        let tmux = self.tmux
        let remoteKeys = self.remoteKeys
        let localKeys = self.localKeys
        prepareRemote(destination)
        sendQueue.async {
            var start = 0
            let bytes = [UInt8](data)
            while start < bytes.count {
                let end = min(start + 48, bytes.count)
                let hex = bytes[start..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
                switch destination {
                case .here(let session, _):
                    localKeys.send(session: session, tmux: tmux, line: "H \(hex)")
                case .remote(_, let session, _):
                    remoteKeys.send(session: session, line: "H \(hex)")
                }
                start = end
            }
        }
    }

    /// The tmux client whose tty belongs to an SSH login, which is the Kindle.
    struct Attached {
        let session: String
        let client: String
    }

    struct Sighting {
        var destination: Destination
        var device: String
        var label: String
    }

    /// Labels from the config's kindleLabels. Set each time the config is read.
    static var kindleLabels: [String: String] = [:]

    static func deviceLabel(_ name: String) -> String {
        kindleLabels[name] ?? name
    }

    /// Tailscale address → hostname, limited to the Kindles named in config.
    static func kindleIPNames(bin: String, hostnames: [String]) -> [String: String] {
        var map: [String: String] = [:]
        let wanted = Set(hostnames)
        let text = output([bin, "status"])
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let ip = String(parts[0])
            let name = String(parts[1])
            guard ip.split(separator: ".").count == 4, wanted.contains(name) else { continue }
            map[ip] = name
        }
        return map
    }

    static func sightings(config: Config) -> [Sighting] {
        let tail = readTail(bin: config.tailscale, hostnames: config.kindleHostnames)
        return sightings(config: config, names: tail.ipNames, selfIP: tail.selfIP)
    }

    static func sightings(config: Config, names: [String: String], selfIP: String?) -> [Sighting] {
        let local = localSightings(tmux: config.tmux, names: names)
        let remote = remoteProbe(config: config, names: names, selfIP: selfIP).sightings
        return uniqueDevices(local + remote)
    }

    /// nil sightings from a remote means that SSH did not answer. Empty means it did, and no Kindle was there.
    fileprivate static func remoteProbe(config: Config, names: [String: String], selfIP: String?) -> Probe {
        if config.remotes.isEmpty { return Probe(sightings: [], known: true) }
        let ips = Set(names.keys)
        var found: [Sighting] = []
        var failed = false
        for remote in config.remotes {
            switch remoteSightings(remote, identity: config.identity, names: names, knownIPs: ips, selfIP: selfIP) {
            case let hits?:
                found.append(contentsOf: hits)
            case nil:
                failed = true
            }
        }
        return Probe(sightings: found, known: !failed)
    }

    static func pick(_ found: [Sighting], prefer: String?) -> Sighting? {
        if let prefer, let hit = found.first(where: { $0.device == prefer }) { return hit }
        return found.first
    }

    static func deviceOrder(_ found: [Sighting]) -> [String] {
        found.map(\.device).reduce(into: [String]()) { list, device in
            if !list.contains(device) { list.append(device) }
        }
    }

    static func uniqueDevices(_ all: [Sighting]) -> [Sighting] {
        var seen = Set<String>()
        return all.filter { seen.insert($0.device).inserted }
    }

    static func localSatisfies(_ local: [Sighting], target: String?) -> Bool {
        if let target, local.contains(where: { $0.device == target }) { return true }
        return target == nil && !local.isEmpty
    }

    /// Two Kindles on one tmux session see the same keystrokes. Give the chosen one its own session.
    static func separateIfShared(_ chosen: Sighting?, among found: [Sighting], config: Config) -> Sighting? {
        guard let chosen else { return nil }
        let shared = found.contains { other in
            other.device != chosen.device
                && other.destination.session == chosen.destination.session
                && sameMachine(other.destination, chosen.destination)
        }
        guard shared else { return chosen }
        // The Kindle's own session, named after its label: "Paperwhite" gets "paperwhite".
        let named = deviceLabel(chosen.device).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = named.isEmpty ? "kindle" : named
        switch chosen.destination {
        case .here(_, let client):
            _ = output([config.tmux, "new-session", "-A", "-d", "-s", name])
            _ = output([config.tmux, "switch-client", "-c", client, "-t", name])
            return Sighting(destination: .here(session: name, client: client), device: chosen.device, label: chosen.label)
        case .remote(let remote, _, let client):
            let script = "\(remote.tmux) new-session -A -d -s '\(name)'; \(remote.tmux) switch-client -c '\(client)' -t '\(name)'"
            _ = output(sshArguments(remote, identity: config.identity) + [script])
            return Sighting(destination: .remote(remote, session: name, client: client), device: chosen.device, label: chosen.label)
        }
    }

    static func sameMachine(_ a: Destination, _ b: Destination) -> Bool {
        switch (a, b) {
        case (.here, .here):
            return true
        case (.remote(let left, _, _), .remote(let right, _, _)):
            return left.id == right.id
        default:
            return false
        }
    }

    static func localSightings(tmux: String, names: [String: String]) -> [Sighting] {
        let who = output(["/usr/bin/who"])
        var ttyIP: [String: String] = [:]
        for line in who.split(separator: "\n") {
            guard !line.contains("console"),
                  let open = line.lastIndex(of: "("),
                  let close = line.lastIndex(of: ")"),
                  open < close else { continue }
            let raw = String(line[line.index(after: open)..<close])
            let ip = raw.split(separator: "%").first.map(String.init) ?? raw
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let tty = String(parts[1])
            ttyIP[tty] = ip
            ttyIP["/dev/" + tty] = ip
        }
        guard !ttyIP.isEmpty else { return [] }
        return sightingsFromClients(
            output([tmux, "list-clients", "-F", "#{client_tty}\t#{client_name}\t#{session_name}"]),
            ttyIP: ttyIP,
            names: names
        ) { session, client in
            .here(session: session, client: client)
        }
    }

    static func remoteSightings(
        _ remote: Remote,
        identity: String,
        names: [String: String],
        knownIPs: Set<String>,
        selfIP: String?
    ) -> [Sighting]? {
        let command = "who; echo ---; \(remote.tmux) list-clients -F '#{client_tty}\t#{client_name}\t#{session_name}'"
        let result = run(sshArguments(remote, identity: identity, connectTimeout: 2) + [command], timeout: 3.2)
        if result.status != 0 && !result.text.contains("\n---\n") { return nil }
        let report = result.text
        let chunks = report.components(separatedBy: "\n---\n")
        guard chunks.count == 2 else { return nil }
        var ttyIP: [String: String] = [:]
        for line in chunks[0].split(separator: "\n") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let raw = String(line[line.index(after: open)..<close])
            let ip = raw.split(separator: "%").first.map(String.init) ?? raw
            let known = knownIPs.contains(ip) || (knownIPs.isEmpty && ip.hasPrefix("100.") && ip != selfIP)
            guard known else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let tty = String(parts[1])
            ttyIP[tty] = ip
            ttyIP["/dev/" + tty] = ip
        }
        guard !ttyIP.isEmpty else { return [] }
        return sightingsFromClients(chunks[1], ttyIP: ttyIP, names: names) { session, client in
            .remote(remote, session: session, client: client)
        }
    }

    static func sightingsFromClients(
        _ clients: String,
        ttyIP: [String: String],
        names: [String: String],
        make: (String, String) -> Destination
    ) -> [Sighting] {
        var result: [Sighting] = []
        for line in clients.split(separator: "\n") {
            let bits = line.split(separator: "\t")
            guard bits.count == 3 else { continue }
            let tty = String(bits[0])
            guard let ip = ttyIP[tty] ?? ttyIP[tty.replacingOccurrences(of: "/dev/", with: "")] else { continue }
            let device = names[ip] ?? ip
            result.append(Sighting(
                destination: make(String(bits[2]), String(bits[1])),
                device: device,
                label: deviceLabel(names[ip] ?? device)
            ))
        }
        return result
    }

    static func kindleSession(tmux: String) -> Attached? {
        let who = output(["/usr/bin/who"])
        var remote = Set<String>()
        for line in who.split(separator: "\n") {
            guard line.contains("("), !line.contains("console") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let tty = String(parts[1])
            remote.insert(tty)
            remote.insert("/dev/" + tty)
        }
        guard !remote.isEmpty else { return nil }
        let clients = output([tmux, "list-clients", "-F", "#{client_tty}\t#{client_name}\t#{session_name}"])
        for line in clients.split(separator: "\n") {
            let bits = line.split(separator: "\t")
            guard bits.count == 3 else { continue }
            let tty = String(bits[0])
            if remote.contains(tty) || remote.contains(tty.replacingOccurrences(of: "/dev/", with: "")) {
                return Attached(session: String(bits[2]), client: String(bits[1]))
            }
        }
        return nil
    }

    private func prepareRemote(_ destination: Destination) {
        let key: String
        switch destination {
        case .here(let session, _):
            key = "here:\(session)"
        case .remote(let remote, let session, _):
            key = "\(remote.id):\(session)"
        }
        if pipeKey == key { return }
        pipeKey = key
        switch destination {
        case .remote(let remote, let session, _):
            localKeys.stop()
            remoteKeys.use(remote, identity: config.identity)
            let keys = remoteKeys
            sendQueue.async { keys.warm(session: session) }
        case .here(let session, _):
            remoteKeys.stop()
            let tmux = self.tmux
            let keys = localKeys
            sendQueue.async { keys.warm(session: session, tmux: tmux) }
        }
    }

    /// Prefer a Kindle logged into this Mac. Otherwise follow it onto a configured remote.
    static func resolveDestination(config: Config, prefer: String? = nil) -> Destination? {
        pick(sightings(config: config), prefer: prefer)?.destination
    }

    /// Move the Kindle's tmux client to the next session on the same computer.
    func cycleSession() {
        let current = destination ?? anchorDestination
        guard let current else {
            flash("The Kindle is not attached to tmux.\nOn that shell:  exec /opt/homebrew/bin/tmux new -As eink")
            return
        }
        sessionToken += 1
        let job = sessionToken
        if isCapturing { armLoader("Next session.", delay: 0.14) }
        let tmux = self.tmux
        let identity = config.identity
        let capturing = isCapturing
        ioQueue.async { [weak self] in
            let names = Self.sessionNames(for: current, tmux: tmux, identity: identity)
            let next = names.count > 1 ? Self.after(current.session, in: names) : nil
            let moved = next.flatMap { Self.switchClient(current, to: $0, tmux: tmux, identity: identity) }
            DispatchQueue.main.async {
                guard let self, self.sessionToken == job else { return }
                self.clearLoader()
                guard let moved else {
                    if names.count <= 1 {
                        self.flash("Only one session (\(current.session)) on \(current.place).\nNew one:  tmux new -s name")
                    } else {
                        self.flash("Could not switch to \(next ?? "the next session").")
                    }
                    return
                }
                if capturing && self.isCapturing {
                    self.destination = moved
                    self.anchorDestination = moved
                    self.pipeKey = nil
                    self.prepareRemote(moved)
                    self.resetComposer()
                    self.cardNotice = nil
                    self.noticeToken += 1
                    self.refreshComposer(present: true)
                }
                self.flash("\(moved.place) · \(moved.session)")
            }
        }
    }

    /// Move along the Kindle's host list. Positive is forward. ⌃⌥⌘H stays as forward.
    func stepComputer(_ delta: Int) {
        let stops = Self.computerStops(config: config)
        let ready = stops.filter(\.ready)
        guard ready.count > 1 else {
            flash(ready.isEmpty ? "No computer is ready." : "Only one computer is ready.")
            return
        }
        let currentID = pendingComputerID ?? Self.computerID(for: destination ?? anchorDestination, in: stops, thisComputer: config.thisComputer)
        guard let index = ready.firstIndex(where: { $0.id == currentID }) else {
            beginMove(to: ready[0], token: "0")
            return
        }
        let step = delta < 0 ? ready.count - 1 : 1
        let target = ready[(index + step) % ready.count]
        beginMove(to: target, token: delta < 0 ? "prev" : "next")
    }

    func selectComputer(_ id: String) {
        let stops = Self.computerStops(config: config)
        guard let target = stops.first(where: { $0.id == id }) else { return }
        guard target.ready, let readyIndex = target.readyIndex else {
            flash("\(target.label) has no address yet.")
            return
        }
        let ready = stops.filter(\.ready)
        let currentID = pendingComputerID ?? Self.computerID(for: destination ?? anchorDestination, in: stops, thisComputer: config.thisComputer)
        if currentID == target.id { return }
        let token: String
        if let index = ready.firstIndex(where: { $0.id == currentID }), ready.count > 1 {
            let forward = ready[(index + 1) % ready.count].id
            let backward = ready[(index + ready.count - 1) % ready.count].id
            if target.id == forward {
                token = "next"
            } else if target.id == backward {
                token = "prev"
            } else {
                token = String(readyIndex)
            }
        } else {
            token = String(readyIndex)
        }
        beginMove(to: target, token: token)
    }

    private func beginMove(to target: ComputerStop, token: String) {
        if switchInFlight && destination == nil { return }
        if let current = destination ?? anchorDestination ?? Self.pick(lastFound, prefer: targetDevice)?.destination {
            startMove(to: target, from: current, token: token)
            return
        }
        seeking = true
        armLoader("Finding the Kindle.", delay: 0.12)
        refreshComposer(present: true)
        moveToken += 1
        let job = moveToken
        let config = self.config
        let prefer = targetDevice
        ioQueue.async { [weak self] in
            guard let self else { return }
            let tail = self.names(maxAge: 6)
            let found = Self.sightings(config: config, names: tail.ipNames, selfIP: tail.selfIP)
            DispatchQueue.main.async {
                guard self.moveToken == job else { return }
                guard let hit = Self.pick(found, prefer: prefer) else {
                    self.seeking = false
                    self.clearLoader()
                    self.flash("The Kindle is not in a session yet.\nOpen Terminal and pick a computer.")
                    return
                }
                self.lastFound = found
                self.startMove(to: target, from: hit.destination, token: token)
            }
        }
    }

    private func startMove(to target: ComputerStop, from current: Destination, token: String) {
        if !isCapturing {
            flash("Moving to \(target.label).")
            let tmux = self.tmux
            let identity = config.identity
            ioQueue.async { [weak self] in
                let result = Self.requestHostSwitch(current, tmux: tmux, identity: identity, token: token)
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .sent:
                        break
                    case .oldLogin:
                        self.flash("This login can't switch yet.\nLeave it and pick a computer once.\nAfter that, ⌃⌥⌘[ and ⌃⌥⌘] move the Kindle.")
                    case .failed:
                        self.flash("Could not ask the Kindle to switch.")
                    }
                }
            }
            return
        }
        moveToken += 1
        let job = moveToken
        anchorDestination = current
        pendingComputerID = target.id
        switchInFlight = true
        seeking = true
        pendingClearToken += 1
        let clear = pendingClearToken
        destination = nil
        pipeKey = nil
        remoteKeys.stop()
        localKeys.stop()
        resetComposer()
        cardNotice = nil
        noticeToken += 1
        armLoader("Moving to \(target.label).", delay: 0)
        refreshComposer(present: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.pendingClearToken == clear else { return }
            self.moveToken += 1
            self.pendingComputerID = nil
            self.switchInFlight = false
            self.seeking = false
            self.clearLoader()
            if self.destination == nil && self.isCapturing {
                self.statusLine = "Looking for the Kindle."
            } else {
                self.statusLine = nil
            }
            if self.isCapturing { self.refreshComposer(present: true) }
        }
        let tmux = self.tmux
        let identity = config.identity
        ioQueue.async { [weak self] in
            let result = Self.requestHostSwitch(current, tmux: tmux, identity: identity, token: token)
            DispatchQueue.main.async {
                guard let self, self.moveToken == job else { return }
                switch result {
                case .sent:
                    break
                case .oldLogin:
                    self.cancelMove("This login can't switch yet.\nLeave it and pick a computer once.\nAfter that, ⌃⌥⌘[ and ⌃⌥⌘] move the Kindle.")
                case .failed:
                    self.cancelMove("Could not ask the Kindle to switch.")
                }
            }
        }
    }

    private func cancelMove(_ message: String) {
        moveToken += 1
        pendingComputerID = nil
        pendingClearToken += 1
        switchInFlight = false
        seeking = false
        clearLoader()
        statusLine = nil
        if let anchor = anchorDestination {
            destination = anchor
            prepareRemote(anchor)
        }
        flash(message)
    }

    /// Choose which Kindle receives keys when more than one is logged in.
    func cycleDevice() {
        let devices = Self.deviceOrder(lastFound)
        if devices.count > 1 {
            switchDevice(among: lastFound, devices: devices)
            return
        }
        sessionToken += 1
        let job = sessionToken
        if isCapturing { armLoader("Next Kindle.", delay: 0.12) }
        let config = self.config
        ioQueue.async { [weak self] in
            guard let self else { return }
            let tail = self.names(maxAge: 6)
            let found = Self.sightings(config: config, names: tail.ipNames, selfIP: tail.selfIP)
            DispatchQueue.main.async {
                guard self.sessionToken == job else { return }
                self.clearLoader()
                self.lastFound = found
                let devices = Self.deviceOrder(found)
                guard !devices.isEmpty else {
                    self.flash("No Kindle terminal is attached.")
                    return
                }
                guard devices.count > 1 else {
                    self.flash("Only the \(found[0].label) is connected.")
                    return
                }
                self.switchDevice(among: found, devices: devices)
            }
        }
    }

    private func switchDevice(among found: [Sighting], devices: [String]) {
        let current = targetDevice ?? found[0].device
        let next = Self.after(current, in: devices) ?? devices[0]
        guard let raw = found.first(where: { $0.device == next }) else { return }
        targetDevice = next
        sessionToken += 1
        let job = sessionToken
        if isCapturing { armLoader("Next Kindle.", delay: 0.12) }
        let config = self.config
        ioQueue.async { [weak self] in
            let hit = Self.separateIfShared(raw, among: found, config: config) ?? raw
            DispatchQueue.main.async {
                guard let self, self.sessionToken == job else { return }
                self.clearLoader()
                self.currentLabel = hit.label
                self.attachedLabels = found.map(\.label)
                self.lastFound = found
                if self.isCapturing {
                    self.destination = hit.destination
                    self.anchorDestination = hit.destination
                    self.pipeKey = nil
                    self.prepareRemote(hit.destination)
                    self.resetComposer()
                    self.cardNotice = nil
                    self.noticeToken += 1
                    self.refreshComposer(present: true)
                } else {
                    self.flash(hit.label)
                }
            }
        }
    }

    /// While the keyboard is grabbed, stay with the Kindle if it logs into another computer.
    private func startFollow() {
        followTimer?.invalidate()
        followGeneration += 1
        followPending = false
        scheduleFollow(generation: followGeneration, delay: 0.01)
    }

    private func scheduleFollow(generation: Int, delay: TimeInterval) {
        followTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
            self?.runFollow(generation: generation)
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runFollow(generation: Int) {
        guard isCapturing, followGeneration == generation else { return }
        if followPending {
            scheduleFollow(generation: generation, delay: 0.1)
            return
        }
        followPending = true
        let config = self.config
        let target = targetDevice
        let destination = self.destination
        let moving = switchInFlight || pendingComputerID != nil || destination == nil
        let stableRemote: Bool = {
            if moving { return false }
            if case .remote = destination { return target != nil }
            return false
        }()
        let sinceRemote = Date().timeIntervalSince(lastRemoteLook)
        let idleMiss = destination == nil && !seeking && !switchInFlight && pendingComputerID == nil
        let allowRemote: Bool
        if movingTowardThisMac() {
            allowRemote = false
        } else if stableRemote {
            allowRemote = sinceRemote >= 5
        } else if seeking || switchInFlight || pendingComputerID != nil {
            allowRemote = true
        } else if idleMiss {
            allowRemote = sinceRemote >= 4
        } else {
            allowRemote = sinceRemote >= 3
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let tail = self.names(maxAge: moving ? 6 : 12)
            let local = Self.localSightings(tmux: config.tmux, names: tail.ipNames)
            let satisfied = Self.localSatisfies(local, target: target)
            var remote: [Sighting] = []
            var remoteKnown = false
            if !satisfied && allowRemote {
                let probe = Self.remoteProbe(config: config, names: tail.ipNames, selfIP: tail.selfIP)
                remote = probe.sightings
                remoteKnown = probe.known
            }
            DispatchQueue.main.async {
                guard self.followGeneration == generation else { return }
                self.followPending = false
                let cardUp = self.pinned && self.panel?.isVisible == true
                guard self.isCapturing || cardUp else { return }
                if !satisfied && allowRemote { self.lastRemoteLook = Date() }
                self.applyFollow(local: local, remote: remote, remoteKnown: remoteKnown)
                let hurry = self.switchInFlight || self.pendingComputerID != nil || (self.destination == nil && self.seeking)
                self.scheduleFollow(generation: generation, delay: hurry ? 0.28 : 1.05)
            }
        }
    }

    /// The lookup finished without a Kindle. Drop the sweep and the stale device name.
    private func settleSearch() {
        seeking = false
        clearLoader()
        statusLine = nil
        attachedLabels = []
        currentLabel = "Kindle"
        lastFound = []
        if dictateWhenReady {
            dictateWhenReady = false
            dictationStarting = false
            showNotice("Dictate starts once a Kindle is connected.")
            return
        }
        refreshComposer(present: panel?.isVisible == true)
    }

    private func movingTowardThisMac() -> Bool {
        guard let id = pendingComputerID else { return false }
        let here = Destination.here(session: "", client: "").place
        guard let stop = Self.computerStops(config: config).first(where: { $0.id == id }) else {
            return id == config.thisComputer
        }
        return stop.id == config.thisComputer || stop.label.caseInsensitiveCompare(here) == .orderedSame
    }

    private func applyFollow(local: [Sighting], remote: [Sighting], remoteKnown: Bool) {
        if let targetDevice, let hit = local.first(where: { $0.device == targetDevice }) {
            if !local.isEmpty { lastFound = local }
            adopt(hit, labels: local.map(\.label))
            return
        }
        if targetDevice == nil {
            if local.count == 1 {
                lastFound = local
                adopt(local[0], labels: local.map(\.label))
                return
            }
            if local.count > 1 {
                if let destination,
                   local.contains(where: { $0.destination.client == destination.client && $0.destination.session == destination.session }) {
                    lastFound = local
                    remember(local.map(\.label))
                    return
                }
                let hit = local[0]
                targetDevice = hit.device
                lastFound = local
                adopt(hit, labels: local.map(\.label))
                return
            }
        }
        let combined = Self.uniqueDevices(local + remote)
        if !combined.isEmpty { lastFound = combined }
        guard remoteKnown else {
            if destination == nil && seeking && !switchInFlight && pendingComputerID == nil {
                settleSearch()
            }
            return
        }
        guard let hit = Self.pick(combined, prefer: targetDevice) else {
            remember(combined.map(\.label))
            if switchInFlight || pendingComputerID != nil { return }
            if destination == nil && seeking {
                settleSearch()
            }
            return
        }
        if combined.count > 1, targetDevice == nil { targetDevice = hit.device }
        adopt(hit, labels: combined.map(\.label))
    }

    private func remember(_ labels: [String]) {
        guard !labels.isEmpty, labels != attachedLabels else { return }
        attachedLabels = labels
        if isCapturing { refreshComposer(present: panel?.isVisible == true) }
    }

    private func adopt(_ hit: Sighting, labels: [String]) {
        let stops = Self.computerStops(config: config)
        let arrived = Self.computerID(for: hit.destination, in: stops, thisComputer: config.thisComputer)
        if let pending = pendingComputerID, arrived != pending {
            let labelsChanged = !labels.isEmpty && labels != attachedLabels
            if !labels.isEmpty { attachedLabels = labels }
            if labelsChanged { refreshComposer(present: true) }
            return
        }
        let arrivedPending = pendingComputerID != nil
        if arrivedPending {
            pendingComputerID = nil
            pendingClearToken += 1
            switchInFlight = false
            statusLine = nil
        }
        let sameTarget = destination?.client == hit.destination.client
            && destination?.session == hit.destination.session
        let labelsChanged = !labels.isEmpty && labels != attachedLabels
        destination = hit.destination
        anchorDestination = hit.destination
        currentLabel = hit.label
        if !labels.isEmpty { attachedLabels = labels }
        prepareRemote(hit.destination)
        if dictateWhenReady && !listening {
            beginDictationAfterAuth()
        }
        if sameTarget && !labelsChanged && !arrivedPending { return }
        statusLine = nil
        seeking = false
        clearLoader()
        if !sameTarget {
            resetComposer()
            cardNotice = nil
            noticeToken += 1
        }
        refreshComposer(present: true)
    }

    private func flash(_ text: String) {
        showNotice(text)
    }

    /// tmux on a remote whose client tty belongs to the Kindle's Tailscale address.
    static func remoteKindleSession(
        _ remote: Remote,
        identity: String,
        kindleIPs: Set<String>,
        selfIP: String?
    ) -> Attached? {
        let command = "who; echo ---; \(remote.tmux) list-clients -F '#{client_tty}\t#{client_name}\t#{session_name}'"
        let report = output(sshArguments(remote, identity: identity) + [command])
        let chunks = report.components(separatedBy: "\n---\n")
        guard chunks.count == 2 else { return nil }
        var ttys = Set<String>()
        for line in chunks[0].split(separator: "\n") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let host = String(line[line.index(after: open)..<close])
            let ip = host.split(separator: "%").first.map(String.init) ?? host
            let matchesKindle = !kindleIPs.isEmpty ? kindleIPs.contains(ip) : (ip.hasPrefix("100.") && ip != selfIP)
            guard matchesKindle else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let tty = String(parts[1])
            ttys.insert(tty)
            ttys.insert("/dev/" + tty)
        }
        guard !ttys.isEmpty else { return nil }
        for line in chunks[1].split(separator: "\n") {
            let bits = line.split(separator: "\t")
            guard bits.count == 3 else { continue }
            let tty = String(bits[0])
            if ttys.contains(tty) || ttys.contains(tty.replacingOccurrences(of: "/dev/", with: "")) {
                return Attached(session: String(bits[2]), client: String(bits[1]))
            }
        }
        return nil
    }

    static func sessionNames(for destination: Destination, tmux: String, identity: String) -> [String] {
        let raw: String
        switch destination {
        case .here:
            raw = output([tmux, "list-sessions", "-F", "#{session_name}"])
        case .remote(let remote, _, _):
            raw = output(sshArguments(remote, identity: identity) + ["\(remote.tmux) list-sessions -F '#{session_name}'"])
        }
        return raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    static func after(_ current: String, in names: [String]) -> String? {
        guard let index = names.firstIndex(of: current) else { return names.first }
        return names[(index + 1) % names.count]
    }

    static func switchClient(_ current: Destination, to session: String, tmux: String, identity: String) -> Destination? {
        let client = current.client
        switch current {
        case .here:
            _ = output([tmux, "switch-client", "-c", client, "-t", session])
            return .here(session: session, client: client)
        case .remote(let remote, _, _):
            let script = "\(remote.tmux) switch-client -c '\(client)' -t '\(session)'"
            _ = output(sshArguments(remote, identity: identity) + [script])
            return .remote(remote, session: session, client: client)
        }
    }

    /// GSSAPI and IPv6 each add a multi-second stall before Tailscale's IPv4 address is tried.
    static func sshArguments(_ remote: Remote, identity: String, connectTimeout: Int = 3) -> [String] {
        [
            "/usr/bin/ssh",
            "-i", identity,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "GSSAPIAuthentication=no",
            "-o", "AddressFamily=inet",
            "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-p", String(remote.port),
            "\(remote.user)@\(remote.host)",
        ]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func keyLoopScript(tmux: String, session: String) -> String {
        let tmuxQ = shellQuote(tmux)
        let sessionQ = shellQuote(session)
        return """
        S=\(sessionQ)
        TMUX=\(tmuxQ)
        "$TMUX" has-session -t "$S" </dev/null || exit 3
        while IFS= read -r line; do
          kind=${line%% *}
          rest=${line#* }
          case "$kind" in
            K) "$TMUX" send-keys -t "$S" "$rest" </dev/null ;;
            H) "$TMUX" send-keys -t "$S" -H $rest </dev/null ;;
          esac
        done
        """
    }

    static func kindleTailscaleIPs(bin: String, hostnames: [String]) -> Set<String> {
        var ips = Set<String>()
        for name in hostnames {
            if let ip = tailscaleIP(bin: bin, hostname: name) {
                ips.insert(ip)
            }
        }
        return ips
    }

    static func tailscaleIP(bin: String, hostname: String) -> String? {
        let status = output([bin, "status"])
        for line in status.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let ip = String(parts[0])
            guard ip.contains(".") else { continue }
            if String(parts[1]) == hostname { return ip }
        }
        return nil
    }

    static func selfTailscaleIP(bin: String) -> String? {
        let ip = output([bin, "ip", "-4"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.contains(".") ? ip : nil
    }

    private static func output(_ args: [String], timeout: TimeInterval = 4) -> String {
        run(args, timeout: timeout).text
    }

    /// Environment for every child process. tmux 3.7 prints the tabs in a -F format as "_"
    /// unless its locale is UTF-8, and an app started from Finder or launchd has no LANG.
    /// Without this, list-clients cannot be split and no Kindle is ever found. ssh passes
    /// LC_* on (macOS SendEnv/AcceptEnv), so tmux on a remote gets the same locale.
    static let childEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        func isUTF8(_ key: String) -> Bool? {
            guard let value = env[key], !value.isEmpty else { return nil }
            let upper = value.uppercased()
            return upper.contains("UTF-8") || upper.contains("UTF8")
        }
        // LC_ALL beats LC_CTYPE, which beats LANG.
        if isUTF8("LC_ALL") ?? isUTF8("LC_CTYPE") ?? isUTF8("LANG") ?? false { return env }
        if isUTF8("LC_ALL") == false {
            env["LC_ALL"] = "en_US.UTF-8"
        } else {
            env["LC_CTYPE"] = "en_US.UTF-8"
        }
        return env
    }()

    /// Runs a short command off to the side. A hung tmux or SSH is killed instead of stalling the card.
    fileprivate static func run(_ args: [String], timeout: TimeInterval) -> CommandResult {
        guard let first = args.first, !first.isEmpty else { return CommandResult(text: "", status: -1) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: first)
        proc.arguments = Array(args.dropFirst())
        proc.environment = childEnvironment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return CommandResult(text: "", status: -1)
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        if !finished {
            proc.terminate()
            if done.wait(timeout: .now() + 0.4) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.4)
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let status: Int32 = finished ? proc.terminationStatus : -1
        return CommandResult(text: text, status: status)
    }

    func toggleDictation() {
        if listening || dictateWhenReady {
            stopDictation(flush: listening)
            return
        }
        dictateWhenReady = true
        recognitionUsesNetwork = false
        recognitionFailures = 0
        if panel?.isVisible == true && !isCapturing {
            resumeCapture()
        } else if !isCapturing {
            capture()
        }
        if destination != nil {
            beginDictationAfterAuth()
        } else {
            refreshComposer(present: true)
        }
    }

    /// Speech permission, then the microphone. Safe to call again while a request is already in flight.
    private func beginDictationAfterAuth() {
        guard dictateWhenReady, !listening, !dictationStarting, destination != nil else { return }
        dictationStarting = true
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophone()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.dictationStarting = false
                    guard self.dictateWhenReady else { return }
                    guard status == .authorized else {
                        self.dictateWhenReady = false
                        self.showNotice("Speech Recognition is off.\nSystem Settings → Privacy & Security → Speech Recognition")
                        self.refreshComposer(present: true)
                        return
                    }
                    self.beginDictationAfterAuth()
                }
            }
        default:
            dictationStarting = false
            dictateWhenReady = false
            showNotice("Speech Recognition is off.\nSystem Settings → Privacy & Security → Speech Recognition")
            refreshComposer(present: true)
        }
    }

    private func requestMicrophone() {
        let start = { (ok: Bool) in
            DispatchQueue.main.async {
                self.dictationStarting = false
                guard self.dictateWhenReady else { return }
                guard ok else {
                    self.dictateWhenReady = false
                    self.showNotice("Microphone access is off.\nSystem Settings → Privacy & Security → Microphone")
                    self.refreshComposer(present: true)
                    return
                }
                self.beginListening()
            }
        }
        if #available(macOS 14, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: start)
        } else {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: start)
        }
    }

    private func beginListening() {
        guard let recognizer, recognizer.isAvailable else {
            dictateWhenReady = false
            dictationStarting = false
            showNotice("Speech recognition isn't available right now.")
            refreshComposer(present: true)
            return
        }
        listening = true
        dictationCommitted = ""
        dictationLatest = ""
        setMenuIcon(on: true)
        cardNotice = nil
        noticeToken += 1
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            listening = false
            dictateWhenReady = false
            dictationStarting = false
            setMenuIcon(on: isCapturing)
            showNotice("No microphone is available.")
            return
        }
        do {
            try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.noteLevel(buffer)
            }
            audioEngine = engine
            installRecognition()
            engine.prepare()
            try engine.start()
            refreshComposer(present: true)
        } catch {
            stopDictation(flush: false)
            showNotice("The microphone didn't start.\n\(error.localizedDescription)")
        }
    }

    private func installRecognition() {
        guard listening, let recognizer else { return }
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition && !recognitionUsesNetwork {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request
        dictationCommitted = ""
        dictationLatest = ""
        if listening { refreshComposer() }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.listening else { return }
                if let result {
                    self.recognitionFailures = 0
                    self.noteTranscript(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                guard error != nil || result?.isFinal == true else { return }
                if error != nil {
                    self.recognitionFailures += 1
                    if !self.recognitionUsesNetwork && self.recognizer?.supportsOnDeviceRecognition == true {
                        self.recognitionUsesNetwork = true
                        self.recognitionFailures = 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            guard self.listening else { return }
                            self.installRecognition()
                        }
                        return
                    }
                    if self.recognitionFailures > 2 {
                        self.stopDictation(flush: true)
                        self.showNotice("Speech recognition stopped.\nSystem Settings → Privacy & Security → Speech Recognition")
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard self.listening else { return }
                    self.installRecognition()
                }
            }
        }
    }

    private func noteTranscript(_ text: String, isFinal: Bool) {
        dictationLatest = text
        refreshComposer()
        settleTimer?.invalidate()
        if isFinal {
            flushDictation(addTrailingSpace: false)
            return
        }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.flushDictation(addTrailingSpace: false)
        }
    }

    /// Speech inserts characters only. Return is left to the keyboard, so a phrase cannot run a command by itself.
    private func flushDictation(addTrailingSpace: Bool) {
        guard destination != nil else { return }
        let latest = dictationLatest.replacingOccurrences(of: "\n", with: " ")
        guard dictationCommitted.isEmpty || latest.hasPrefix(dictationCommitted) else { return }
        var out = dictationCommitted.isEmpty ? latest : String(latest.dropFirst(dictationCommitted.count))
        if addTrailingSpace, !out.isEmpty, out.last?.isWhitespace != true {
            out.append(" ")
        }
        guard !out.isEmpty else { return }
        composer.insert(out)
        send(Data(out.utf8))
        dictationCommitted = latest
        refreshComposer()
    }

    private func stopDictation(flush: Bool) {
        let wasListening = listening
        dictateWhenReady = false
        dictationStarting = false
        listening = false
        settleTimer?.invalidate()
        settleTimer = nil
        if flush && wasListening { flushDictation(addTrailingSpace: true) }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        dictationCommitted = ""
        dictationLatest = ""
        card?.micLevel = 0
        setMenuIcon(on: isCapturing)
        if isCapturing {
            cardNotice = nil
            refreshComposer(present: true)
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                if id == 2 { Focus.shared?.toggleDictation() }
                else if id == 3 { Focus.shared?.cycleSession() }
                else if id == 4 || id == 7 { Focus.shared?.stepComputer(1) }
                else if id == 5 { Focus.shared?.cycleDevice() }
                else if id == 6 { Focus.shared?.stepComputer(-1) }
                else if id == 8 { Focus.shared?.nudgeOpacity(-1) }
                else if id == 9 { Focus.shared?.nudgeOpacity(1) }
                else if id == 10 { Focus.shared?.togglePin() }
                else { Focus.shared?.toggle() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x45494E4B), id: 1)
        RegisterEventHotKey(hotKeyCode, hotKeyMods, id, GetApplicationEventTarget(), 0, &hotKey)
        let dictateID = EventHotKeyID(signature: OSType(0x45494E4B), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), hotKeyMods, dictateID, GetApplicationEventTarget(), 0, &dictateHotKey)
        let swapID = EventHotKeyID(signature: OSType(0x45494E4B), id: 3)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), hotKeyMods, swapID, GetApplicationEventTarget(), 0, &swapHotKey)
        let hostID = EventHotKeyID(signature: OSType(0x45494E4B), id: 4)
        RegisterEventHotKey(UInt32(kVK_ANSI_H), hotKeyMods, hostID, GetApplicationEventTarget(), 0, &hostHotKey)
        let deviceID = EventHotKeyID(signature: OSType(0x45494E4B), id: 5)
        RegisterEventHotKey(UInt32(kVK_ANSI_J), hotKeyMods, deviceID, GetApplicationEventTarget(), 0, &deviceHotKey)
        let backID = EventHotKeyID(signature: OSType(0x45494E4B), id: 6)
        RegisterEventHotKey(UInt32(kVK_ANSI_LeftBracket), hotKeyMods, backID, GetApplicationEventTarget(), 0, &backHotKey)
        let forwardID = EventHotKeyID(signature: OSType(0x45494E4B), id: 7)
        RegisterEventHotKey(UInt32(kVK_ANSI_RightBracket), hotKeyMods, forwardID, GetApplicationEventTarget(), 0, &forwardHotKey)
        let dimID = EventHotKeyID(signature: OSType(0x45494E4B), id: 8)
        RegisterEventHotKey(UInt32(kVK_ANSI_Minus), hotKeyMods, dimID, GetApplicationEventTarget(), 0, &dimHotKey)
        let brightID = EventHotKeyID(signature: OSType(0x45494E4B), id: 9)
        RegisterEventHotKey(UInt32(kVK_ANSI_Equal), hotKeyMods, brightID, GetApplicationEventTarget(), 0, &brightHotKey)
        let pinID = EventHotKeyID(signature: OSType(0x45494E4B), id: 10)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), hotKeyMods, pinID, GetApplicationEventTarget(), 0, &pinHotKey)
    }

    /// kterm's xterm-256color entry advertises cursor style and xterm extensions its VTE does not draw.
    /// A client named kterm* gets 256 colors only, so those sequences stay inside tmux.
    private static func teachKindleTerminal(tmux: String) {
        ensureKindleTerminfo()
        guard !tmux.isEmpty else { return }
        let current = output([tmux, "show", "-s", "terminal-features"], timeout: 2)
        if current.contains("kterm*") { return }
        _ = output([tmux, "set", "-sa", "terminal-features", "kterm*:256"], timeout: 2)
    }

    /// tmux reads the Kindle's TERM on this Mac. Install the stripped description once.
    private static func ensureKindleTerminfo() {
        let probe = run(["/usr/bin/infocmp", "-x", "-1", "kterm-256color"], timeout: 2)
        if probe.status == 0,
           probe.text.contains("Kindle kterm"),
           !probe.text.contains("\n\tXT,"),
           !probe.text.contains("\n\tSs=") {
            return
        }
        guard let source = kindleTerminfoSource() else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kterm-256color.src")
        do {
            try source.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = run(["/usr/bin/tic", "-x", "-o", home + "/.terminfo", tmp.path], timeout: 4)
    }

    private static func kindleTerminfoSource() -> String? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "kterm-256color", withExtension: "src") {
            candidates.append(bundled)
        }
        if let root = Config.buildRoot {
            candidates.append(root.appendingPathComponent("kindle/kterm/terminfo/kterm-256color.src"))
        }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("kterm-256color|") {
                return text
            }
        }
        return nil
    }

    /// The login command includes this marker once the Kindle is running the switchable session.
    static func clientUsesHostSwitch(_ destination: Destination, tmux: String, identity: String) -> Bool {
        commandLine(for: destination, tmux: tmux, identity: identity).contains("eterm-switch")
    }

    fileprivate static func requestHostSwitch(_ destination: Destination, tmux: String, identity: String, token: String) -> SwitchAttempt {
        let clean = token.lowercased().filter { $0.isLetter || $0.isNumber }
        let safe = clean.isEmpty ? "next" : String(clean.prefix(8))
        let script = switchScript(tmux: tmux, client: destination.client, token: safe)
        let result: CommandResult
        switch destination {
        case .here:
            result = run(["/bin/sh", "-c", script], timeout: 3)
        case .remote(let remote, _, _):
            result = run(sshArguments(remote, identity: identity, connectTimeout: 4) + [script], timeout: 5.5)
        }
        if result.text.contains("sent") { return .sent }
        if result.text.contains("old") { return .oldLogin }
        return .failed
    }

    /// One shell: confirm the login can switch, write the token, then detach. An old login exits 40 for any file, so back would hop forward.
    private static func switchScript(tmux: String, client: String, token: String) -> String {
        let tmuxQ = shellQuote(tmux)
        let clientQ = shellQuote(client)
        let tokenQ = shellQuote(token)
        return """
        tty=$(\(tmuxQ) display-message -p -c \(clientQ) '#{client_tty}' 2>/dev/null || true)
        short=${tty#/dev/}
        cmd=$(ps -t "$short" -o command= 2>/dev/null || true)
        case "$cmd" in
          *eterm-switch*)
            printf '%s\\n' \(tokenQ) > "$HOME/.eterm-switch"
            if \(tmuxQ) detach-client -t \(clientQ); then
              echo sent
            else
              rm -f "$HOME/.eterm-switch"
              echo fail
            fi
            ;;
          *)
            echo old
            ;;
        esac
        """
    }

    /// Hosts file order, matching connect.sh. Falls back to this Mac plus configured remotes.
    fileprivate static func computerStops(config: Config) -> [ComputerStop] {
        let url = URL(fileURLWithPath: config.hosts)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let stamp = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let memo = stopMemo, memo.exists == exists, memo.stamp == stamp {
            return memo.stops
        }
        let stops = makeStops(config: config)
        stopMemo = (exists, stamp, stops)
        return stops
    }

    private static func makeStops(config: Config) -> [ComputerStop] {
        if let rows = hostRows(path: config.hosts), !rows.isEmpty {
            var readyCount = 0
            return rows.map { row in
                let index: Int? = row.ready ? readyCount : nil
                if row.ready { readyCount += 1 }
                return ComputerStop(id: row.id, label: row.label, ready: row.ready, readyIndex: index)
            }
        }
        var stops = [ComputerStop(id: config.thisComputer, label: Destination.here(session: "", client: "").place, ready: true, readyIndex: 0)]
        for (offset, remote) in config.remotes.enumerated() {
            stops.append(ComputerStop(id: remote.id, label: remote.label, ready: true, readyIndex: offset + 1))
        }
        return stops
    }

    fileprivate static func computerID(for destination: Destination?, in stops: [ComputerStop], thisComputer: String) -> String? {
        guard let destination else { return nil }
        switch destination {
        case .remote(let remote, _, _):
            if let hit = stops.first(where: { $0.id == remote.id }) { return hit.id }
            return stops.first { $0.label.caseInsensitiveCompare(remote.label) == .orderedSame }?.id
        case .here:
            let place = destination.place
            if let hit = stops.first(where: { $0.label.caseInsensitiveCompare(place) == .orderedSame }) { return hit.id }
            return stops.first { $0.id == thisComputer }?.id
        }
    }

    private static func hostRows(path: String) -> [(id: String, label: String, ready: Bool)]? {
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rows: [(id: String, label: String, ready: Bool)] = []
        for line in text.components(separatedBy: .newlines) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 5 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            let host = parts[2].trimmingCharacters(in: .whitespaces)
            let label = parts[4].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !label.isEmpty else { continue }
            let ready = !host.isEmpty && host != "REPLACE" && host != "REPLACE_ME"
            rows.append((id, label, ready))
        }
        return rows
    }

    static func commandLine(for destination: Destination, tmux: String, identity: String) -> String {
        switch destination {
        case .here(_, let client):
            let tty = output([tmux, "display-message", "-p", "-c", client, "#{client_tty}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let short = tty.replacingOccurrences(of: "/dev/", with: "")
            guard !short.isEmpty else { return "" }
            return output(["/bin/ps", "-t", short, "-o", "command="])
        case .remote(let remote, _, let client):
            let script = "tty=$(\(remote.tmux) display-message -p -c '\(client)' '#{client_tty}'); ps -t \"${tty#/dev/}\" -o command="
            return output(sshArguments(remote, identity: identity) + [script])
        }
    }
}

enum Destination {
    case here(session: String, client: String)
    case remote(Remote, session: String, client: String)

    var session: String {
        switch self {
        case .here(let session, _), .remote(_, let session, _): return session
        }
    }

    var client: String {
        switch self {
        case .here(_, let client), .remote(_, _, let client): return client
        }
    }

    var place: String {
        switch self {
        case .here:
            let name = Host.current().localizedName ?? "This Mac"
            let lower = name.lowercased()
            if lower.contains("mac mini") { return "Mac mini" }
            if lower.contains("macbook pro") { return "MacBook Pro" }
            if lower.contains("macbook air") { return "MacBook Air" }
            if lower.contains("macbook") { return "MacBook" }
            return name
        case .remote(let remote, _, _): return remote.label
        }
    }
}

/// One local tmux process that reads keys from a pipe, so typing does not spawn a process per character.
final class LocalKeys {
    private var proc: Process?
    private var stdin: FileHandle?
    private var session: String?
    private var tmux = ""
    private let lock = NSLock()

    func warm(session: String, tmux: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.session != session || self.tmux != tmux || proc?.isRunning != true else { return }
        stopLocked()
        _ = startLocked(session: session, tmux: tmux)
    }

    func send(session: String, tmux: String, line: String) {
        lock.lock()
        defer { lock.unlock() }
        if self.session != session || self.tmux != tmux || proc?.isRunning != true {
            stopLocked()
            guard startLocked(session: session, tmux: tmux) else { return }
        }
        guard let stdin else { return }
        try? stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        lock.lock()
        stopLocked()
        lock.unlock()
    }

    private func startLocked(session: String, tmux: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", App.keyLoopScript(tmux: tmux, session: session)]
        proc.environment = App.childEnvironment
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        self.proc = proc
        self.stdin = input.fileHandleForWriting
        self.session = session
        self.tmux = tmux
        return true
    }

    private func stopLocked() {
        try? stdin?.close()
        stdin = nil
        proc?.terminate()
        proc = nil
        session = nil
        tmux = ""
    }
}

/// Holds one SSH channel to the remote the Kindle is logged into.
final class RemoteKeys {
    private var remote: Remote?
    private var identity = ""
    private var proc: Process?
    private var stdin: FileHandle?
    private var session: String?
    private let lock = NSLock()

    func use(_ remote: Remote, identity: String) {
        lock.lock()
        defer { lock.unlock() }
        if self.remote?.id != remote.id || self.identity != identity {
            stopPipe()
            self.remote = remote
            self.identity = identity
        }
    }

    func send(session: String, line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard remote != nil, !identity.isEmpty else { return }
        if self.session != session || proc?.isRunning != true {
            stopPipe()
            guard startLocked(session: session) else { return }
        }
        guard let stdin else { return }
        try? stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    func warm(session: String) {
        lock.lock()
        defer { lock.unlock() }
        guard remote != nil, !identity.isEmpty else { return }
        if self.session == session && proc?.isRunning == true { return }
        stopPipe()
        _ = startLocked(session: session)
    }

    func capture(session: String) -> String {
        lock.lock()
        let remote = self.remote
        let identity = self.identity
        lock.unlock()
        guard let remote, !identity.isEmpty else { return "" }
        let tmux = App.shellQuote(remote.tmux)
        let target = App.shellQuote(session)
        let script = """
        TMUX=\(tmux)
        mode=$("$TMUX" display-message -p -t \(target) '#{pane_in_mode}')
        if [ "$mode" = 1 ]; then
          "$TMUX" send-keys -t \(target) -X copy-selection-and-cancel </dev/null
          "$TMUX" show-buffer
        else
          "$TMUX" capture-pane -t \(target) -p -J
        fi
        """
        return App.run(App.sshArguments(remote, identity: identity, connectTimeout: 4) + [script], timeout: 5).text
    }

    func stop() {
        lock.lock()
        stopPipe()
        remote = nil
        identity = ""
        lock.unlock()
    }

    private func startLocked(session: String) -> Bool {
        guard let remote, !identity.isEmpty else { return false }
        // The remote login shell may be zsh, which does not split the unquoted hex bytes
        // the loop hands to send-keys -H. Run the loop under sh so typed text arrives.
        let script = "exec /bin/sh -c " + App.shellQuote(App.keyLoopScript(tmux: remote.tmux, session: session))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = Array(App.sshArguments(remote, identity: identity, connectTimeout: 8).dropFirst()) + [script]
        proc.environment = App.childEnvironment
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        self.proc = proc
        self.stdin = input.fileHandleForWriting
        self.session = session
        return true
    }

    private func stopPipe() {
        try? stdin?.close()
        stdin = nil
        proc?.terminate()
        proc = nil
        session = nil
    }
}

/// The line shown on the desk card. It tracks the keys sent to the Kindle's tmux session.
struct LineComposer {
    var text = ""
    var cursor = 0

    private func index(at offset: Int) -> String.Index {
        let n = min(max(offset, 0), text.count)
        return text.index(text.startIndex, offsetBy: n)
    }

    private mutating func clamp() {
        if cursor < 0 { cursor = 0 }
        if cursor > text.count { cursor = text.count }
    }

    private func char(_ offset: Int) -> Character {
        text[text.index(text.startIndex, offsetBy: offset)]
    }

    mutating func insert(_ raw: String) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var clean = ""
        for ch in normalized {
            if ch == "\n" || ch == "\t" {
                if let last = clean.last, !last.isWhitespace { clean.append(" ") }
                continue
            }
            if ch.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { continue }
            clean.append(ch)
        }
        guard !clean.isEmpty else { return }
        text.insert(contentsOf: clean, at: index(at: cursor))
        cursor += clean.count
        if text.count > 800 {
            let overflow = text.count - 700
            text = String(text.dropFirst(overflow))
            cursor = max(0, cursor - overflow)
        }
        clamp()
    }

    mutating func backspace() {
        guard cursor > 0 else { return }
        let end = index(at: cursor)
        text.removeSubrange(text.index(before: end)..<end)
        cursor -= 1
    }

    mutating func deleteForward() {
        guard cursor < text.count else { return }
        let start = index(at: cursor)
        text.removeSubrange(start..<text.index(after: start))
    }

    mutating func deleteWordBackward() {
        guard cursor > 0 else { return }
        var i = cursor
        while i > 0 && char(i - 1).isWhitespace { i -= 1 }
        while i > 0 && !char(i - 1).isWhitespace { i -= 1 }
        text.removeSubrange(index(at: i)..<index(at: cursor))
        cursor = i
    }

    mutating func deleteWordForward() {
        guard cursor < text.count else { return }
        var i = cursor
        while i < text.count && char(i).isWhitespace { i += 1 }
        while i < text.count && !char(i).isWhitespace { i += 1 }
        text.removeSubrange(index(at: cursor)..<index(at: i))
    }

    mutating func killToStart() {
        guard cursor > 0 else { return }
        text.removeSubrange(text.startIndex..<index(at: cursor))
        cursor = 0
    }

    mutating func killToEnd() {
        guard cursor < text.count else { return }
        text.removeSubrange(index(at: cursor)..<text.endIndex)
    }

    mutating func move(_ delta: Int) {
        cursor += delta
        clamp()
    }

    mutating func moveToStart() { cursor = 0 }
    mutating func moveToEnd() { cursor = text.count }

    mutating func wordBackward() {
        guard cursor > 0 else { return }
        var i = cursor
        while i > 0 && char(i - 1).isWhitespace { i -= 1 }
        while i > 0 && !char(i - 1).isWhitespace { i -= 1 }
        cursor = i
    }

    mutating func wordForward() {
        guard cursor < text.count else { return }
        var i = cursor
        while i < text.count && char(i).isWhitespace { i += 1 }
        while i < text.count && !char(i).isWhitespace { i += 1 }
        cursor = i
    }

    mutating func submit() {
        text = ""
        cursor = 0
    }
}

/// Desk-console card. Ink shell, paper slip, the same line the Kindle is receiving.
final class DeskCard: NSView {
    static let defaultShell = NSSize(width: 704, height: 276)
    static let minShell = NSSize(width: 620, height: 248)
    static let maxShell = NSSize(width: 1080, height: 640)
    static let pad: CGFloat = 28
    static let originXKey = "cardOriginX"
    static let originYKey = "cardOriginY"
    static let widthKey = "cardWidth"
    static let heightKey = "cardHeight"
    static let pinKey = "cardPinned"
    static let opacityKey = "cardOpacity"
    static let opacitySteps: [CGFloat] = [1, 0.92, 0.84, 0.76, 0.68, 0.60]

    static func savedShellSize() -> NSSize {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil, defaults.object(forKey: heightKey) != nil else {
            return defaultShell
        }
        return clampedShell(NSSize(width: defaults.double(forKey: widthKey), height: defaults.double(forKey: heightKey)))
    }

    static func clampedShell(_ size: NSSize) -> NSSize {
        NSSize(
            width: min(max(size.width, minShell.width), maxShell.width),
            height: min(max(size.height, minShell.height), maxShell.height)
        )
    }

    static func windowSize(for shell: NSSize) -> NSSize {
        NSSize(width: shell.width + pad * 2, height: shell.height + pad * 2)
    }

    static var windowSize: NSSize { windowSize(for: savedShellSize()) }

    static func savedPinned() -> Bool {
        UserDefaults.standard.bool(forKey: pinKey)
    }

    struct Place {
        var id: String
        var label: String
        var ready: Bool
        var selected: Bool
    }

    struct Hint {
        var chord: String
        var verb: String
    }

    var device = "KINDLE"
    var others: [String] = []
    var place = ""
    var session = ""
    var linked = false
    var listening = false
    var micLevel: CGFloat = 0
    var line = ""
    var cursor = 0
    var pending = ""
    var ghost = ""
    var ghostUntil = Date.distantPast
    var notice: String?
    var waiting: String?
    var hints: [Hint] = []
    var places: [Place] = []
    /// Brass sweep across the paper while a lookup or a computer change is still in flight.
    var busy = false
    var sweep: CGFloat = 0
    /// Slot offset while the rail slides. +1 means the new computer enters from the right.
    var railShift: CGFloat = 0
    var opacity: CGFloat = 1
    var cursorOn = true
    var pinned = false
    /// False while a pinned card is visible but the keyboard belongs to another app.
    var live = true
    var dictateArmed = false
    var onStep: ((Int) -> Void)?
    var onSelect: ((String) -> Void)?
    var onOpacity: ((Int) -> Void)?
    var onDragEnd: (() -> Void)?
    var onResizeEnd: (() -> Void)?
    var onPin: (() -> Void)?
    /// System dictation and the input menu land here. The key monitor still owns the keyboard.
    var onInsert: ((String) -> Void)?

    private struct Hit {
        enum Kind: Equatable {
            case back, forward, computer(String), dimmer, brighter, pin, resize
        }
        var kind: Kind
        var rect: NSRect
        var enabled: Bool
    }

    private var hits: [Hit] = []
    private var armed: Hit.Kind?
    private var tracking: NSTrackingArea?
    private var pressScreen: NSPoint?
    private var originAtPress: NSPoint?
    private var pressedHit: Hit?
    private var dragging = false
    private var resizing = false
    private var sizeAtPress = NSSize.zero
    private var railTimer: Timer?
    private var railFrom: CGFloat = 0
    private var railStarted = Date()
    private var sweepTimer: Timer?

    deinit {
        sweepTimer?.invalidate()
        railTimer?.invalidate()
    }

    func setBusy(_ on: Bool) {
        guard busy != on else { return }
        busy = on
        sweepTimer?.invalidate()
        sweepTimer = nil
        if on {
            sweep = 0
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.sweep = (self.sweep + (1.0 / 30.0) / 0.85).truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
            sweepTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func insertFromInput(_ insertString: Any) {
        let raw: String
        if let string = insertString as? String {
            raw = string
        } else if let styled = insertString as? NSAttributedString {
            raw = styled.string
        } else {
            return
        }
        let text = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard !text.isEmpty else { return }
        onInsert?(text)
    }

    override func insertText(_ insertString: Any) {
        insertFromInput(insertString)
    }

    static func savedOpacity() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: opacityKey) != nil else { return 1 }
        let raw = CGFloat(defaults.double(forKey: opacityKey))
        return opacitySteps.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1
    }

    static func originOnScreen(_ origin: NSPoint, size: NSSize) -> Bool {
        let shellW = max(1, size.width - pad * 2)
        let shellH = max(1, size.height - pad * 2)
        let center = NSPoint(x: origin.x + pad + shellW / 2, y: origin.y + pad + shellH / 2)
        let inset = CGFloat(8)
        return NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: inset, dy: inset).contains(center) }
    }

    static func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let shellW = max(1, size.width - pad * 2)
        let shellH = max(1, size.height - pad * 2)
        let shell = NSRect(x: origin.x + pad, y: origin.y + pad, width: shellW, height: shellH)
        let center = NSPoint(x: shell.midX, y: shell.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        guard let screen else { return origin }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let maxX = max(visible.minX, visible.maxX - shellW)
        let maxY = max(visible.minY, visible.maxY - shellH)
        let x = min(max(shell.minX, visible.minX), maxX)
        let y = min(max(shell.minY, visible.minY), maxY)
        return NSPoint(x: x - pad, y: y - pad)
    }

    private func gripRect(in shell: NSRect) -> NSRect {
        NSRect(x: shell.maxX - 26, y: shell.minY, width: 26, height: 26)
    }

    func setPlaces(_ next: [Place]) {
        let same = next.count == places.count && zip(next, places).allSatisfy {
            $0.id == $1.id && $0.label == $1.label && $0.ready == $1.ready && $0.selected == $1.selected
        }
        if same { return }
        let oldID = places.first(where: \.selected)?.id
        let newID = next.first(where: \.selected)?.id
        let oldIndex = places.firstIndex(where: { $0.id == oldID })
        let newIndex = next.firstIndex(where: { $0.id == newID })
        places = next
        if let oldID, let newID, oldID != newID, let oldIndex, let newIndex, next.count > 1 {
            let count = next.count
            let forward = (newIndex - oldIndex + count) % count
            let backward = (oldIndex - newIndex + count) % count
            animateRail(from: forward <= backward ? 1 : -1)
        } else {
            needsDisplay = true
        }
    }

    private func animateRail(from start: CGFloat) {
        railFrom = start
        railShift = start
        railStarted = Date()
        railTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = min(1, Date().timeIntervalSince(self.railStarted) / 0.18)
            let eased = 1 - pow(1 - t, 3)
            self.railShift = self.railFrom * (1 - eased)
            self.needsDisplay = true
            if t >= 1 {
                self.railShift = 0
                timer.invalidate()
                self.railTimer = nil
            }
        }
        railTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let shell = bounds.insetBy(dx: Self.pad, dy: Self.pad)
        if hits.contains(where: { $0.enabled && $0.kind != .resize && $0.rect.contains(local) }) {
            NSCursor.pointingHand.set()
        } else if gripRect(in: shell).contains(local) {
            NSCursor.crosshair.set()
        } else if shell.contains(local) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let shell = bounds.insetBy(dx: Self.pad, dy: Self.pad)
        guard shell.contains(local) else { return }
        let localHits = hits.filter { $0.rect.contains(local) }
        pressedHit = localHits.first { $0.kind != .resize } ?? localHits.first
        armed = pressedHit?.enabled == true ? pressedHit?.kind : nil
        resizing = pressedHit?.kind == .resize
        pressScreen = NSEvent.mouseLocation
        originAtPress = window?.frame.origin
        sizeAtPress = window?.frame.size ?? .zero
        dragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = pressScreen, let origin = originAtPress, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - anchor.x
        let dy = now.y - anchor.y
        if resizing {
            if hypot(dx, dy) < 1 { return }
            dragging = true
            armed = nil
            var shell = Self.clampedShell(NSSize(
                width: sizeAtPress.width - Self.pad * 2 + dx,
                height: sizeAtPress.height - Self.pad * 2 - dy
            ))
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                let maxW = visible.maxX - origin.x - Self.pad * 2
                let maxH = origin.y + sizeAtPress.height - visible.minY - Self.pad * 2
                if maxW > 0 { shell.width = min(shell.width, max(Self.minShell.width, maxW)) }
                if maxH > 0 { shell.height = min(shell.height, max(Self.minShell.height, maxH)) }
                shell = Self.clampedShell(shell)
            }
            let next = Self.windowSize(for: shell)
            window.setFrame(NSRect(
                x: origin.x,
                y: origin.y + sizeAtPress.height - next.height,
                width: next.width,
                height: next.height
            ), display: true)
            NSCursor.crosshair.set()
            return
        }
        guard pressedHit == nil else { return }
        if !dragging && hypot(dx, dy) < 3 { return }
        dragging = true
        armed = nil
        window.setFrameOrigin(Self.clampedOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy), size: window.frame.size))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        let hit = pressedHit
        let moved = dragging
        let wasResize = resizing
        pressedHit = nil
        pressScreen = nil
        originAtPress = nil
        dragging = false
        resizing = false
        armed = nil
        needsDisplay = true
        if wasResize {
            if moved { onResizeEnd?() }
            return
        }
        if moved {
            NSCursor.openHand.set()
            onDragEnd?()
            return
        }
        guard let hit, hit.enabled else { return }
        switch hit.kind {
        case .back: onStep?(-1)
        case .forward: onStep?(1)
        case .computer(let id): onSelect?(id)
        case .dimmer: onOpacity?(-1)
        case .brighter: onOpacity?(1)
        case .pin: onPin?()
        case .resize: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        hits.removeAll(keepingCapacity: true)
        let shell = bounds.insetBy(dx: Self.pad, dy: Self.pad)
        let shellPath = NSBezierPath(roundedRect: shell, xRadius: 18, yRadius: 18)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 22
        shadow.set()
        Ink.shell.setFill()
        shellPath.fill()
        NSShadow().set()

        Ink.shellLine.setStroke()
        shellPath.lineWidth = 1
        shellPath.stroke()
        brackets(in: shell)
        drawGrip(in: gripRect(in: shell))

        let header = NSRect(x: shell.minX + 26, y: shell.maxY - 44, width: shell.width - 52, height: 26)
        let rail = NSRect(x: shell.minX + 16, y: shell.maxY - 94, width: shell.width - 32, height: 44)
        let paper = NSRect(
            x: shell.minX + 16,
            y: shell.minY + 36,
            width: shell.width - 32,
            height: max(88, shell.height - 138)
        )
        let footer = NSRect(x: shell.minX + 28, y: shell.minY + 8, width: shell.width - 56, height: 22)

        drawHeader(in: header)
        drawRail(in: rail)
        let paperPath = NSBezierPath(roundedRect: paper, xRadius: 12, yRadius: 12)
        Ink.paper.setFill()
        paperPath.fill()
        Ink.ink.withAlphaComponent(0.08).setStroke()
        paperPath.lineWidth = 1
        paperPath.stroke()

        if let notice {
            drawMessage(notice, in: paper, color: Ink.ink)
        } else if let waiting {
            let tone = busy ? Ink.ink : Ink.ink.withAlphaComponent(0.72)
            drawMessage(waiting, in: paper, color: tone)
        } else {
            drawComposer(in: paper)
        }
        drawHints(in: footer)
    }

    private func brackets(in shell: NSRect) {
        Ink.paper.withAlphaComponent(0.42).setStroke()
        let inset: CGFloat = 11
        let len: CGFloat = 13
        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x + dx * len, y: y))
            path.line(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x, y: y + dy * len))
            path.lineWidth = 1.25
            path.lineCapStyle = .square
            path.stroke()
        }
        corner(shell.minX + inset, shell.maxY - inset, 1, -1)
        corner(shell.maxX - inset, shell.maxY - inset, -1, -1)
        corner(shell.minX + inset, shell.minY + inset, 1, 1)
    }

    /// The bottom-right bracket is the resize handle. It stays clear of the opacity keys.
    private func drawGrip(in rect: NSRect) {
        hits.append(Hit(kind: .resize, rect: rect, enabled: true))
        Ink.paper.withAlphaComponent(0.78).setStroke()
        let inset: CGFloat = 11
        let len: CGFloat = 13
        let x = rect.maxX - inset
        let y = rect.minY + inset
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x - len, y: y))
        path.line(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x, y: y + len))
        path.lineWidth = 1.5
        path.lineCapStyle = .square
        path.stroke()
    }

    private func pinLabel(on: Bool, armed: Bool) -> NSAttributedString {
        let color = on ? Ink.brass : Ink.paper.withAlphaComponent(armed ? 0.92 : 0.42)
        return tracked("PIN", size: 10, weight: .medium, kern: 1.4, color: color)
    }

    /// Returns the width of the mark. A word, because a 16pt pin glyph reads as a search icon.
    private func drawPin(at x: CGFloat, midY: CGFloat, on: Bool, armed: Bool) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let word = pinLabel(on: on, armed: armed)
        let width = word.size().width
        let base = drawnBase(font, midY: midY)
        word.draw(at: NSPoint(x: x, y: base))
        if on {
            let lift = ceil(-font.descender)
            Ink.brass.setFill()
            NSBezierPath(rect: NSRect(x: x, y: base + lift - 3.4, width: width, height: 1.15)).fill()
        }
        hits.append(Hit(
            kind: .pin,
            rect: NSRect(x: x - 8, y: midY - 12, width: width + 16, height: 24),
            enabled: true
        ))
        return width
    }

    private func drawHeader(in header: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let base = header.midY - (font.ascender + font.descender) / 2
        var x = header.minX

        let lamp = NSRect(x: x, y: header.midY - 4, width: 8, height: 8)
        if busy {
            let pulse = 0.28 + 0.72 * sin(sweep * .pi)
            Ink.brass.withAlphaComponent(pulse).setFill()
            NSBezierPath(rect: lamp).fill()
        } else if linked && live {
            let color = listening ? Ink.brass.withAlphaComponent(cursorOn ? 1 : 0.28) : Ink.paper
            color.setFill()
            NSBezierPath(rect: lamp).fill()
        } else {
            Ink.paper.withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath(rect: lamp.insetBy(dx: 0.6, dy: 0.6))
            path.lineWidth = 1.1
            path.stroke()
        }
        x = lamp.maxX + 10

        let nameColor = listening ? Ink.brass : Ink.paper
        let name = tracked(device, size: 11, weight: .medium, kern: 1.7, color: nameColor)
        let nameW = name.size().width
        let plate = NSRect(x: x, y: header.midY - 11, width: nameW + 18, height: 22)
        (listening ? Ink.brass.withAlphaComponent(0.9) : Ink.paper.withAlphaComponent(0.62)).setStroke()
        let platePath = NSBezierPath(roundedRect: plate, xRadius: 4, yRadius: 4)
        platePath.lineWidth = 1
        platePath.stroke()
        // draw(at:) anchors the line box, ceil(-descender) below the baseline.
        // These names are uppercase, so that lift is what centers the caps in the plate.
        name.draw(at: NSPoint(
            x: plate.minX + 9,
            y: plate.midY - font.capHeight / 2 - ceil(-font.descender)
        ))
        x = plate.maxX + 12

        let right = rightCluster(font: font)
        let rightW = right.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, right.count - 1)) * 8
        let rightX = header.maxX - rightW
        let pinWidth = pinLabel(on: pinned, armed: false).size().width
        let pinX = rightX - 16 - pinWidth
        _ = drawPin(at: pinX, midY: header.midY, on: pinned, armed: armed == .pin)
        let budget = pinX - 12

        if !others.isEmpty && x < budget {
            for other in others {
                let attr = tracked(other, size: 11, weight: .medium, kern: 1.4, color: Ink.paper.withAlphaComponent(0.32))
                let w = attr.size().width
                if x + w > budget { break }
                attr.draw(at: NSPoint(x: x, y: base))
                x += w + 14
            }
        }

        if dictateArmed && !listening && x + 52 < budget {
            let word = tracked("MIC", size: 10, weight: .medium, kern: 1.5, color: Ink.brass.withAlphaComponent(0.7))
            let wordBase = header.midY - (NSFont.monospacedSystemFont(ofSize: 10, weight: .medium).ascender + NSFont.monospacedSystemFont(ofSize: 10, weight: .medium).descender) / 2
            word.draw(at: NSPoint(x: x, y: wordBase))
            x += word.size().width + 12
        }

        if listening && x + 108 < budget {
            x += drawMeter(at: x, midY: header.midY) + 8
            let word = tracked("LISTENING", size: 10, weight: .medium, kern: 1.5, color: Ink.brass)
            if x + word.size().width < budget {
                let wordBase = header.midY - (NSFont.monospacedSystemFont(ofSize: 10, weight: .medium).ascender + NSFont.monospacedSystemFont(ofSize: 10, weight: .medium).descender) / 2
                word.draw(at: NSPoint(x: x, y: wordBase))
            }
        }

        var rx = rightX
        for (index, part) in right.enumerated() {
            part.text.draw(at: NSPoint(x: rx, y: base))
            rx += part.width
            if index < right.count - 1 { rx += 8 }
        }
    }

    private struct ClusterPart {
        var text: NSAttributedString
        var width: CGFloat
    }

    private func rightCluster(font: NSFont) -> [ClusterPart] {
        guard !session.isEmpty else { return [] }
        let attr = NSAttributedString(string: session, attributes: [
            .font: font,
            .foregroundColor: Ink.paper.withAlphaComponent(0.92),
        ])
        return [ClusterPart(text: attr, width: attr.size().width)]
    }

    private func drawRail(in rail: NSRect) {
        let chevronW: CGFloat = 132
        let backRect = NSRect(x: rail.minX, y: rail.minY, width: chevronW, height: rail.height)
        let forwardRect = NSRect(x: rail.maxX - chevronW, y: rail.minY, width: chevronW, height: rail.height)
        let readyCount = places.filter(\.ready).count
        let canMove = readyCount > 1
        hits.append(Hit(kind: .back, rect: backRect, enabled: canMove))
        hits.append(Hit(kind: .forward, rect: forwardRect, enabled: canMove))
        drawChevron(in: backRect, symbol: "‹", chord: "⌃⌥⌘[", symbolFirst: true, enabled: canMove, kind: .back)
        drawChevron(in: forwardRect, symbol: "›", chord: "⇧tab", symbolFirst: false, enabled: canMove, kind: .forward)

        let band = NSRect(
            x: backRect.maxX + 2,
            y: rail.minY,
            width: max(0, forwardRect.minX - backRect.maxX - 4),
            height: rail.height
        )
        guard !places.isEmpty else { return }
        let font = NSFont(name: "Avenir Next", size: 15) ?? NSFont.systemFont(ofSize: 15, weight: .medium)
        let base = rail.midY - (font.ascender + font.descender) / 2
        let gap: CGFloat = 28
        let widths = places.map { measure($0.label, font: font, maxWidth: 168) }
        let content = widths.reduce(0, +) + gap * CGFloat(max(0, places.count - 1))
        let selected = places.firstIndex(where: \.selected)
        let travel: CGFloat
        if let selected {
            travel = widths[selected] + gap
        } else {
            travel = 0
        }
        let shift = railShift * travel
        var distances: [CGFloat] = []
        if let selected {
            distances = places.indices.map { abs(CGFloat($0 - selected) + railShift) }
        }
        let focus = distances.min()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: band).setClip()
        var x = band.midX - content / 2 + shift
        for (index, place) in places.enumerated() {
            let width = widths[index]
            let center = x + width / 2
            let distance = selected == nil ? nil : distances[index]
            let focused = focus != nil && distance != nil && abs(distance! - focus!) < 0.02 && distance! < 0.8
            drawPlace(place, center: center, baseline: base, font: font, maxWidth: 168, distance: distance, focused: focused)
            let rect = NSRect(x: x - gap / 2, y: rail.minY, width: width + gap, height: rail.height)
            if band.intersects(rect) {
                hits.append(Hit(kind: .computer(place.id), rect: rect.intersection(band), enabled: true))
            }
            x += width + gap
        }
        let left = band.midX - content / 2 + shift
        let right = left + content
        if left < band.minX + 1 || right > band.maxX - 1 {
            fadeRailEdges(band)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func measure(_ text: String, font: NSFont, maxWidth: CGFloat) -> CGFloat {
        min(maxWidth, NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    private func fadeRailEdges(_ band: NSRect) {
        guard let gradient = NSGradient(colors: [Ink.shell, Ink.shell.withAlphaComponent(0)]) else { return }
        let fade: CGFloat = 18
        gradient.draw(
            from: NSPoint(x: band.minX, y: band.midY),
            to: NSPoint(x: band.minX + fade, y: band.midY),
            options: [.drawsBeforeStartingLocation]
        )
        gradient.draw(
            from: NSPoint(x: band.maxX, y: band.midY),
            to: NSPoint(x: band.maxX - fade, y: band.midY),
            options: [.drawsBeforeStartingLocation]
        )
    }

    private func drawChevron(
        in rect: NSRect,
        symbol: String,
        chord: String,
        symbolFirst: Bool,
        enabled: Bool,
        kind: Hit.Kind
    ) {
        if armed == kind {
            Ink.paper.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 6), xRadius: 8, yRadius: 8).fill()
        }
        let chordFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let symbolFont = NSFont.systemFont(ofSize: 20, weight: .medium)
        let chordBase = rect.midY - (chordFont.ascender + chordFont.descender) / 2
        let symbolBase = rect.midY - (symbolFont.ascender + symbolFont.descender) / 2
        let chordAlpha: CGFloat = enabled ? 0.72 : 0.28
        let symbolAlpha: CGFloat = enabled ? 0.92 : 0.28
        let chordText = NSAttributedString(string: chord, attributes: [
            .font: chordFont,
            .foregroundColor: Ink.paper.withAlphaComponent(chordAlpha),
        ])
        let symbolText = NSAttributedString(string: symbol, attributes: [
            .font: symbolFont,
            .foregroundColor: Ink.paper.withAlphaComponent(symbolAlpha),
        ])
        let gap: CGFloat = 5
        let total = symbolText.size().width + gap + chordText.size().width
        var x = rect.midX - total / 2
        if symbolFirst {
            symbolText.draw(at: NSPoint(x: x, y: symbolBase))
            x += symbolText.size().width + gap
            chordText.draw(at: NSPoint(x: x, y: chordBase))
        } else {
            chordText.draw(at: NSPoint(x: x, y: chordBase))
            x += chordText.size().width + gap
            symbolText.draw(at: NSPoint(x: x, y: symbolBase))
        }
    }

    private func drawPlace(
        _ place: Place,
        center: CGFloat,
        baseline: CGFloat,
        font: NSFont,
        maxWidth: CGFloat,
        distance: CGFloat?,
        focused: Bool
    ) {
        let alpha: CGFloat
        if let distance {
            if place.ready {
                alpha = 0.5 + 0.46 * max(0, 1 - min(distance, 1))
            } else {
                alpha = 0.3
            }
        } else {
            alpha = place.ready ? 0.62 : 0.28
        }
        let shown = fit(place.label, font: font, color: Ink.paper.withAlphaComponent(alpha), maxWidth: maxWidth)
        let width = shown.size().width
        shown.draw(at: NSPoint(x: center - width / 2, y: baseline))
        if focused, let distance {
            let strength = max(0, 1 - distance / 0.8)
            Ink.paper.withAlphaComponent(0.9 * strength).setFill()
            NSBezierPath(rect: NSRect(x: center - width / 2, y: baseline - 4, width: width, height: 1.35)).fill()
        }
    }

    /// Four level marks. Returns the width used.
    private func drawMeter(at x: CGFloat, midY: CGFloat) -> CGFloat {
        let widths: CGFloat = 4 * 3 + 3 * 3
        for i in 0..<4 {
            let threshold = CGFloat(i) * 0.18
            let amount = max(0, min(1, (micLevel - threshold) / 0.28))
            let h = 3 + 10 * amount
            let rect = NSRect(x: x + CGFloat(i) * 6, y: midY - h / 2, width: 3, height: h)
            Ink.brass.withAlphaComponent(amount > 0.05 ? 0.95 : 0.35).setFill()
            NSBezierPath(rect: rect).fill()
        }
        return widths
    }

    private func drawComposer(in paper: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        let hasGhost = !ghost.isEmpty && Date() < ghostUntil
        let promptColor = listening ? Ink.brass : Ink.ink
        let prompt = NSAttributedString(string: ">", attributes: [
            .font: font,
            .foregroundColor: promptColor,
        ])
        let padX: CGFloat = 22
        let promptW = prompt.size().width
        let textLeft = paper.minX + padX + promptW + 14
        let textWidth = paper.maxX - padX - textLeft
        let lineH = font.ascender - font.descender
        var lineBaseline = paper.midY - (font.ascender + font.descender) / 2
        if hasGhost {
            lineBaseline = paper.midY - 14
        }
        prompt.draw(at: NSPoint(x: paper.minX + padX, y: lineBaseline))
        if hasGhost {
            let ghostFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            let ghostBase = lineBaseline + lineH + 6
            let shown = fit(ghost, font: ghostFont, color: Ink.ink.withAlphaComponent(0.40), maxWidth: textWidth)
            shown.draw(at: NSPoint(x: textLeft, y: ghostBase))
        }

        let cursorIndex = min(max(cursor, 0), line.count)
        let before = String(line.prefix(cursorIndex))
        let after = String(line.dropFirst(cursorIndex))
        let beforeAttr = NSAttributedString(string: before, attributes: [.font: font, .foregroundColor: Ink.ink])
        let pendingAttr = NSAttributedString(string: pending, attributes: [.font: font, .foregroundColor: Ink.brass])
        let afterAttr = NSAttributedString(string: after, attributes: [.font: font, .foregroundColor: Ink.ink])
        let beforeW = before.isEmpty ? 0 : beforeAttr.size().width
        let pendingW = pending.isEmpty ? 0 : pendingAttr.size().width
        let afterW = after.isEmpty ? 0 : afterAttr.size().width
        let cell = max(12, NSAttributedString(string: "M", attributes: [.font: font]).size().width)
        let lead = beforeW + pendingW
        let reserve: CGFloat = 28
        let follow = after.isEmpty ? cell + 8 : min(textWidth * 0.4, afterW + cell + 8)
        var shift: CGFloat = 0
        if lead + reserve > textWidth - follow {
            shift = max(0, lead - (textWidth - follow - reserve))
        }
        let scrolled = shift > 1
        let inset = scrolled ? reserve : 0

        NSGraphicsContext.saveGraphicsState()
        let clipX = textLeft + inset
        NSBezierPath(rect: NSRect(
            x: clipX,
            y: paper.minY + 10,
            width: max(0, textWidth - inset) + 4,
            height: paper.height - 20
        )).setClip()
        var x = clipX - shift
        if !before.isEmpty {
            beforeAttr.draw(at: NSPoint(x: x, y: lineBaseline))
            x += beforeW
        }
        if !pending.isEmpty {
            pendingAttr.draw(at: NSPoint(x: x, y: lineBaseline))
            Ink.brass.setFill()
            NSBezierPath(rect: NSRect(x: x, y: lineBaseline - 3, width: pendingW, height: 1.25)).fill()
            x += pendingW
        }
        if cursorOn && live {
            Ink.ink.setFill()
            NSBezierPath(rect: NSRect(
                x: x + 1,
                y: lineBaseline + font.descender + 1,
                width: max(8, cell - 3),
                height: lineH - 2
            )).fill()
        }
        x += cell
        if !after.isEmpty {
            afterAttr.draw(at: NSPoint(x: x, y: lineBaseline))
        }
        NSGraphicsContext.restoreGraphicsState()
        if scrolled {
            let ellipsis = NSAttributedString(string: "…", attributes: [
                .font: font,
                .foregroundColor: Ink.ink.withAlphaComponent(0.38),
            ])
            ellipsis.draw(at: NSPoint(x: textLeft, y: lineBaseline))
        }
    }

    private func drawMessage(_ text: String, in paper: NSRect, color: NSColor) {
        let font = NSFont(name: "Avenir Next", size: 18) ?? NSFont.systemFont(ofSize: 18, weight: .medium)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visible = lines.filter { !$0.isEmpty }
        if visible.isEmpty {
            if busy { drawSweep(centerX: paper.midX, y: paper.midY - 1) }
            return
        }
        let lineH = ceil(font.ascender - font.descender + 5)
        let total = lineH * CGFloat(visible.count)
        var baseline = paper.midY + (total - lineH) / 2 - (font.ascender + font.descender) / 2
        if busy { baseline += 8 }
        let top = baseline
        let maxW = paper.width - 56
        for line in visible {
            let shown = fit(line, font: font, color: color, maxWidth: maxW)
            shown.draw(at: NSPoint(x: paper.midX - shown.size().width / 2, y: baseline))
            baseline -= lineH
        }
        if busy {
            let last = top - lineH * CGFloat(visible.count - 1)
            drawSweep(centerX: paper.midX, y: last + font.descender - 16)
        }
    }

    private func drawSweep(centerX: CGFloat, y: CGFloat) {
        let trackW: CGFloat = 156
        let track = NSRect(x: centerX - trackW / 2, y: y, width: trackW, height: 2)
        Ink.ink.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        let bead: CGFloat = 52
        let travel = trackW - bead
        let beadRect = NSRect(x: track.minX + travel * sweep, y: y, width: bead, height: 2)
        let fade = Ink.brass.withAlphaComponent(0)
        if let gradient = NSGradient(colors: [fade, Ink.brass, Ink.brass, fade]) {
            gradient.draw(in: beadRect, angle: 0)
        } else {
            Ink.brass.setFill()
            NSBezierPath(roundedRect: beadRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    /// draw(at:) anchors the line box, so the baseline sits ceil(-descender) above y.
    private func drawnBase(_ font: NSFont, midY: CGFloat) -> CGFloat {
        midY - (font.ascender + font.descender) / 2 - ceil(-font.descender)
    }

    private func drawHints(in rect: NSRect) {
        let cluster = drawOpacityCluster(in: rect)
        let room = NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - cluster - 18), height: rect.height)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let verbFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let keyBase = drawnBase(keyFont, midY: room.midY)
        let verbBase = drawnBase(verbFont, midY: room.midY)
        struct Piece {
            var key: NSAttributedString
            var verb: NSAttributedString
            var keyWidth: CGFloat
            var width: CGFloat
        }
        var pieces: [Piece] = []
        for hint in hints {
            let key = NSAttributedString(string: hint.chord, attributes: [
                .font: keyFont,
                .foregroundColor: Ink.paper.withAlphaComponent(0.92),
            ])
            let verb = NSAttributedString(string: hint.verb, attributes: [
                .font: verbFont,
                .foregroundColor: Ink.paper.withAlphaComponent(0.46),
            ])
            let keyWidth = key.size().width + 16
            pieces.append(Piece(key: key, verb: verb, keyWidth: keyWidth, width: keyWidth + 7 + verb.size().width))
        }
        var visible: [Piece] = []
        var used: CGFloat = 0
        let minGap: CGFloat = 12
        for piece in pieces {
            let next = used + (visible.isEmpty ? 0 : minGap) + piece.width
            if !visible.isEmpty && next > room.width + 1 { break }
            visible.append(piece)
            used = next
        }
        let gaps = CGFloat(max(0, visible.count - 1))
        let widths = visible.reduce(CGFloat(0)) { $0 + $1.width }
        let gap = gaps > 0 ? min(20, max(minGap, (room.width - widths) / gaps)) : 0
        let total = widths + gap * gaps
        var x = room.midX - total / 2
        if x < room.minX { x = room.minX }
        for piece in visible {
            if x + piece.width > room.maxX + 2 { break }
            let cap = NSRect(x: x, y: room.midY - 10, width: piece.keyWidth, height: 20)
            Ink.paper.withAlphaComponent(0.075).setFill()
            let path = NSBezierPath(roundedRect: cap, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor(srgbRed: 0.86, green: 0.74, blue: 0.58, alpha: 0.42).setStroke()
            path.lineWidth = 1
            path.stroke()
            piece.key.draw(at: NSPoint(x: cap.minX + 8, y: keyBase))
            piece.verb.draw(at: NSPoint(x: cap.maxX + 7, y: verbBase))
            x += piece.width + gap
        }
    }

    /// Returns the width reserved on the right for the opacity control.
    private func drawOpacityCluster(in rect: NSRect) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let base = drawnBase(font, midY: rect.midY)
        let percent = "\(Int((opacity * 100).rounded()))%"
        let percentText = NSAttributedString(string: percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Ink.paper.withAlphaComponent(0.7),
        ])
        let chord = NSAttributedString(string: "⌃⌥⌘", attributes: [
            .font: font,
            .foregroundColor: Ink.paper.withAlphaComponent(0.45),
        ])
        let button: CGFloat = 22
        let gap: CGFloat = 6
        let total = chord.size().width + gap + button + gap + percentText.size().width + gap + button
        var x = rect.maxX - total
        chord.draw(at: NSPoint(x: x, y: base))
        x += chord.size().width + gap
        let dimmer = NSRect(x: x, y: rect.midY - 9, width: button, height: 18)
        x += button + gap
        percentText.draw(at: NSPoint(x: x, y: base + 0.4))
        x += percentText.size().width + gap
        let brighter = NSRect(x: x, y: rect.midY - 9, width: button, height: 18)
        let canDim = opacity > 0.61
        let canBright = opacity < 0.995
        drawOpacityButton(dimmer, symbol: "−", enabled: canDim, kind: .dimmer)
        drawOpacityButton(brighter, symbol: "=", enabled: canBright, kind: .brighter)
        hits.append(Hit(kind: .dimmer, rect: dimmer.insetBy(dx: -3, dy: -4), enabled: canDim))
        hits.append(Hit(kind: .brighter, rect: brighter.insetBy(dx: -3, dy: -4), enabled: canBright))
        return total
    }

    private func drawOpacityButton(_ rect: NSRect, symbol: String, enabled: Bool, kind: Hit.Kind) {
        let fill = armed == kind ? 0.16 : 0.07
        Ink.paper.withAlphaComponent(enabled ? fill : 0.04).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        Ink.paper.withAlphaComponent(enabled ? 0.28 : 0.12).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        path.lineWidth = 1
        path.stroke()
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let text = NSAttributedString(string: symbol, attributes: [
            .font: font,
            .foregroundColor: Ink.paper.withAlphaComponent(enabled ? 0.88 : 0.28),
        ])
        let size = text.size()
        text.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: drawnBase(font, midY: rect.midY)
        ))
    }

    private func tracked(_ text: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat, color: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
        ])
        if styled.length > 0 {
            styled.removeAttribute(.kern, range: NSRange(location: styled.length - 1, length: 1))
        }
        return styled
    }

    private func fit(_ text: String, font: NSFont, color: NSColor, maxWidth: CGFloat) -> NSAttributedString {
        func make(_ value: String) -> NSAttributedString {
            NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        }
        var shown = text
        var attr = make(shown)
        guard attr.size().width > maxWidth else { return attr }
        while shown.count > 1 {
            shown.removeLast()
            attr = make(shown + "…")
            if attr.size().width <= maxWidth { return attr }
        }
        return attr
    }
}

private enum Ink {
    static let shell = NSColor(srgbRed: 0x12 / 255, green: 0x11 / 255, blue: 0x0e / 255, alpha: 0.98)
    static let shellLine = NSColor(srgbRed: 0xf4 / 255, green: 0xf1 / 255, blue: 0xea / 255, alpha: 0.16)
    static let paper = NSColor(srgbRed: 0xf4 / 255, green: 0xf1 / 255, blue: 0xea / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x16 / 255, green: 0x15 / 255, blue: 0x13 / 255, alpha: 1)
    static let brass = NSColor(srgbRed: 0x8a / 255, green: 0x4e / 255, blue: 0x22 / 255, alpha: 1)
}

extension DeskCard: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        insertFromInput(string)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}

    func unmarkText() {}

    func selectedRange() -> NSRange { NSRange(location: cursor, length: 0) }

    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func hasMarkedText() -> Bool { false }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { cursor }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum Focus {
    static weak var shared: App?
}

#if PREVIEW
let previewApp = NSApplication.shared
previewApp.setActivationPolicy(.accessory)

func renderCard(_ name: String, shell: NSSize? = nil, _ body: (DeskCard) -> Void) {
    let window = shell.map { DeskCard.windowSize(for: DeskCard.clampedShell($0)) } ?? DeskCard.windowSize
    let card = DeskCard(frame: NSRect(origin: .zero, size: window))
    body(card)
    let scale: CGFloat = 2
    let pixelsWide = Int(card.bounds.width * scale)
    let pixelsHigh = Int(card.bounds.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    rep.size = card.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(rect: card.bounds).fill()
    card.draw(card.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: "/tmp/eink-\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    FileHandle.standardOutput.write(Data((url.path + "\n").utf8))
}

func sampleHints(two: Bool, listening: Bool, pinnedIdle: Bool = false) -> [DeskCard.Hint] {
    if pinnedIdle {
        return [
            DeskCard.Hint(chord: "click", verb: "focus"),
            DeskCard.Hint(chord: "⌃⌥⌘k", verb: "type"),
        ]
    }
    var items = [
        DeskCard.Hint(chord: "esc", verb: "close"),
        DeskCard.Hint(chord: "⇧tab", verb: "computer"),
    ]
    if two {
        items.append(DeskCard.Hint(chord: "⌃⇧tab", verb: "kindle"))
    }
    items.append(DeskCard.Hint(chord: "⌃⌥⌘d", verb: listening ? "done" : "dictate"))
    items.append(DeskCard.Hint(chord: "⌃⌥⌘s", verb: "session"))
    return items
}

func samplePlaces(selected: String?) -> [DeskCard.Place] {
    [
        DeskCard.Place(id: "personal", label: "MacBook Pro", ready: true, selected: selected == "personal"),
        DeskCard.Place(id: "mini", label: "Mac mini", ready: true, selected: selected == "mini"),
        DeskCard.Place(id: "work", label: "Work laptop", ready: false, selected: selected == "work"),
    ]
}

var editor = LineComposer()
editor.insert("hello world")
editor.backspace()
editor.insert("d")
editor.deleteWordBackward()
if editor.text != "hello " || editor.cursor != 6 { fputs("composer word fail\n", stderr); exit(1) }
editor.moveToStart()
editor.deleteForward()
if editor.text != "ello " { fputs("composer delete fail\n", stderr); exit(1) }
editor.moveToEnd()
editor.insert("there")
editor.killToStart()
if editor.text != "" || editor.cursor != 0 { fputs("composer kill fail\n", stderr); exit(1) }
editor.insert("alpha beta")
editor.move(-4)
editor.killToEnd()
if editor.text != "alpha " { fputs("composer kill-end fail \(editor.text)\n", stderr); exit(1) }

renderCard("empty") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("typing") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.line = "ship the desk console"
    card.cursor = 9
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("dictation") { card in
    card.device = "SCRIBE"
    card.others = ["PAPERWHITE"]
    card.session = "scribe"
    card.linked = true
    card.listening = true
    card.micLevel = 0.72
    card.places = samplePlaces(selected: "mini")
    card.line = "remember to bring the "
    card.cursor = card.line.count
    card.pending = "power cable"
    card.hints = sampleHints(two: true, listening: true)
}
renderCard("ghost") { card in
    card.device = "PAPERWHITE"
    card.session = "paperwhite"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.ghost = "git status"
    card.ghostUntil = Date().addingTimeInterval(10)
    card.line = "git status"
    card.cursor = 4
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("long") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.line = "this line is long enough that the cursor has to stay in view while the beginning scrolls away from the paper"
    card.cursor = 78
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("waiting") { card in
    card.device = "NO KINDLE"
    card.waiting = "Open Terminal on the Kindle\nand pick a computer."
    card.places = samplePlaces(selected: nil)
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("notice") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "mini")
    card.notice = "Moving to Mac mini."
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("slide") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "mini")
    card.railShift = 0.62
    card.line = "ship the desk console"
    card.cursor = 21
    card.opacity = 0.84
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("dim") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.opacity = 0.60
    card.line = "still readable"
    card.cursor = 5
    card.hints = sampleHints(two: true, listening: false)
}
renderCard("moving") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = false
    card.busy = true
    card.sweep = 0.34
    card.waiting = "Moving to Mac mini."
    card.places = samplePlaces(selected: "mini")
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("finding") { card in
    card.device = "KINDLE"
    card.busy = true
    card.sweep = 0.72
    card.waiting = "Finding the Kindle."
    card.places = samplePlaces(selected: nil)
    card.hints = sampleHints(two: false, listening: false)
}
renderCard("pinned") { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.live = false
    card.pinned = true
    card.places = samplePlaces(selected: "personal")
    card.line = "ship the desk console"
    card.cursor = 21
    card.hints = sampleHints(two: false, listening: false, pinnedIdle: true)
}
renderCard("armed") { card in
    card.device = "SCRIBE"
    card.others = ["PAPERWHITE"]
    card.session = "scribe"
    card.linked = true
    card.dictateArmed = true
    card.places = samplePlaces(selected: "personal")
    card.line = "bring the cable"
    card.cursor = 15
    card.hints = sampleHints(two: true, listening: false)
}
renderCard("tall", shell: NSSize(width: 860, height: 420)) { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "personal")
    card.line = "ship the desk console"
    card.cursor = 9
    card.hints = sampleHints(two: true, listening: false)
}
renderCard("short", shell: DeskCard.minShell) { card in
    card.device = "PAPERWHITE"
    card.session = "eink"
    card.linked = true
    card.places = samplePlaces(selected: "mini")
    card.line = "still holds"
    card.cursor = 5
    card.hints = sampleHints(two: true, listening: false)
}
exit(0)
#else
let app = NSApplication.shared
let delegate = App()
Focus.shared = delegate
app.delegate = delegate
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    guard Focus.shared?.isCapturing == true else { return event }
    if Focus.shared?.handleKey(event) == true { return nil }
    return event
}
app.run()
#endif
