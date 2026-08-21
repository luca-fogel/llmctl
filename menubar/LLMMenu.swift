import AppKit
import Foundation

// Menu bar readout for local LLM memory. All state comes from `llmctl status
// --json`; this app only renders it and shells back to `llmctl free` to unload.
// Keeping every measurement in the CLI means there is exactly one definition of
// "used memory" to get right, and it is testable without a UI.

let GB = 1024.0 * 1024.0 * 1024.0

/// Where `llmctl` is. Checked in order, because a GUI app inherits almost no
/// PATH: an app launched from Finder does not see /opt/homebrew/bin at all.
func findLLMCTL() -> String? {
    if let env = ProcessInfo.processInfo.environment["LLMCTL"], FileManager.default.isExecutableFile(atPath: env) {
        return env
    }
    var candidates = [
        NSHomeDirectory() + "/bin/llmctl",
        "/usr/local/bin/llmctl",
        "/opt/homebrew/bin/llmctl",
    ]
    // Next to the .app bundle, which is where ./install.sh leaves it when it
    // installs without touching a directory on PATH.
    let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent().path
    candidates.append(bundleDir + "/llmctl")
    candidates.append(bundleDir + "/../Resources/llmctl")
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return nil
}

let llmctlPath = findLLMCTL()

func run(_ args: [String]) -> String {
    guard let tool = llmctlPath else { return "" }
    let p = Process()
    // Execute the script directly so its own shebang picks the interpreter.
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func gb(_ b: Double) -> String {
    b >= GB ? String(format: "%.1f GB", b / GB) : String(format: "%.0f MB", b / 1048576)
}

/// Headroom, in the terms you act on. Deliberately not a named model: what fits
/// depends on your models, and a wrong specific claim is worse than a number.
func headroom(availableGB: Double) -> (text: String, warn: Bool) {
    if availableGB < 4 { return (String(format: "%.1f GB free — unload something", availableGB), true) }
    return (String(format: "%.0f GB free for a new model", availableGB), false)
}

struct Model: Decodable { let name: String; let bytes: Double; let ctx: Int? }
struct Engine: Decodable {
    let engine: String, label: String
    let models: [Model]
    let rss: Double
    let running: Bool
}
struct Snapshot: Decodable {
    let total: Double, available: Double, wired: Double
    let engines: [Engine]
    let loaded: Int
}

// MARK: - Panel
// A status item can be squeezed out of the menu bar entirely by the front app's
// menus, with no warning and no fallback, so the same readout is also a window:
// launch "LLM Memory" from Spotlight to summon it.
final class PanelController: NSObject, NSWindowDelegate {
    let window: NSPanel
    let stack = NSStackView()
    var timer: Timer?
    var onFree: ((String) -> Void)?

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                         styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                         backing: .buffered, defer: false)
        super.init()
        window.title = "LLM Memory"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
        window.contentView = content
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.reload() }
        reload()
    }

    func windowWillClose(_ n: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        DispatchQueue.global(qos: .utility).async {
            let out = run(["status", "--json"])
            let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(out.utf8))
            DispatchQueue.main.async {
                if let s = snap { self.render(s) } else { self.renderMissingTool() }
            }
        }
    }

    private func label(_ text: String, size: CGFloat, mono: Bool = false,
                       color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                      : NSFont.systemFont(ofSize: size)
        f.textColor = color
        return f
    }

    /// Absence of the CLI is a state, not a blank window.
    func renderMissingTool() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label("llmctl not found", size: 16, color: .systemOrange))
        stack.addArrangedSubview(label(
            "Put the llmctl script on your PATH (or next to this app),\n"
            + "or set the LLMCTL environment variable to its full path.",
            size: 12, color: .secondaryLabelColor))
        window.setContentSize(NSSize(width: 440, height: stack.fittingSize.height))
    }

    func render(_ s: Snapshot) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let usedGB = (s.total - s.available) / GB
        stack.addArrangedSubview(label(String(format: "%.0f GB free of %.0f GB",
                                              s.available / GB, s.total / GB), size: 20))
        let bars = Int(((s.total - s.available) / s.total * 28).rounded())
        stack.addArrangedSubview(label(String(repeating: "\u{2588}", count: max(0, bars))
            + String(repeating: "\u{2591}", count: max(0, 28 - bars))
            + String(format: "  %.1f GB in use", usedGB), size: 11, mono: true,
            color: .secondaryLabelColor))

        for e in s.engines {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            let dot = e.models.isEmpty ? "\u{25CB}" : "\u{25CF}"
            let held = e.rss >= GB ? gb(e.rss) : "idle"
            row.addArrangedSubview(label("\(dot)  \(e.label)", size: 13))
            let sizeLabel = label(held, size: 13, mono: true,
                                  color: e.rss >= GB ? .systemOrange : .secondaryLabelColor)
            row.addArrangedSubview(sizeLabel)
            if !e.models.isEmpty || e.rss >= GB {
                let b = NSButton(title: "Unload", target: self, action: #selector(unload(_:)))
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.identifier = NSUserInterfaceItemIdentifier(e.engine)
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
            for m in e.models {
                stack.addArrangedSubview(label("        \(m.name)", size: 11,
                                               mono: true, color: .secondaryLabelColor))
            }
        }

        let h = headroom(availableGB: s.available / GB)
        stack.addArrangedSubview(label(h.text, size: 12,
                                       color: h.warn ? .systemOrange : .secondaryLabelColor))

        let freeAll = NSButton(title: "Free Everything", target: self, action: #selector(freeAll))
        freeAll.bezelStyle = .rounded
        stack.addArrangedSubview(freeAll)
        window.setContentSize(NSSize(width: 440, height: stack.fittingSize.height))
    }

    @objc func unload(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "..."
        onFree?(sender.identifier?.rawValue ?? "all")
    }

    @objc func freeAll() { onFree?("all") }
}

final class Controller: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var busy = false
    let panel = PanelController()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.menu?.delegate = self
        item.button?.title = "  LLM"
        item.button?.image = NSImage(systemSymbolName: "cpu",
                                     accessibilityDescription: "LLM memory")
        item.button?.imagePosition = NSControl.ImagePosition.imageLeading
        panel.onFree = { [weak self] target in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = run(["free", target])
                DispatchQueue.main.async { self?.panel.reload(); self?.refresh() }
            }
        }
        if llmctlPath == nil { panel.show() }   // say so on launch rather than showing a dot
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.show()
        return true
    }

    @objc func showPanel() { panel.show() }

    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let out = run(["status", "--json"])
            let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(out.utf8))
            DispatchQueue.main.async {
                self.busy = false
                if let s = snap { self.render(s) } else { self.renderMissingTool() }
            }
        }
    }

    func renderMissingTool() {
        item.button?.title = "  ?"
        let menu = item.menu!
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "llmctl not found", action: nil, keyEquivalent: ""))
        let p = NSMenuItem(title: "How to fix", action: #selector(showPanel), keyEquivalent: "")
        p.target = self
        menu.addItem(p)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    func render(_ s: Snapshot) {
        // Title shows only memory held by inference engines -- the number you
        // act on -- not total system usage.
        let held = s.engines.reduce(0) { $0 + $1.rss }
        let title = held >= GB ? String(format: "%.0fG", held / GB) : "·"
        let button = item.button
        button?.title = "  " + title
        button?.image = NSImage(systemSymbolName: s.loaded > 0 ? "cpu.fill" : "cpu",
                                accessibilityDescription: "LLM memory")
        button?.imagePosition = NSControl.ImagePosition.imageLeading

        let menu = item.menu!
        menu.removeAllItems()

        let usedPct = (s.total - s.available) / s.total
        let bars = Int((usedPct * 16).rounded())
        let bar = String(repeating: "|", count: max(0, bars))
            + String(repeating: ".", count: max(0, 16 - bars))
        let head = NSMenuItem(title: String(format: "%@  %.0f GB free of %.0f GB",
                                            bar, s.available / GB, s.total / GB),
                              action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(
            string: head.title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        menu.addItem(head)
        menu.addItem(NSMenuItem.separator())

        for e in s.engines {
            let dot = e.models.isEmpty ? (e.running ? "○" : "·") : "●"
            let line = "\(dot)  \(e.label)   \(e.rss >= GB ? gb(e.rss) : "idle")"
            let mi = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            mi.attributedTitle = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            menu.addItem(mi)
            for m in e.models {
                let sub = NSMenuItem(title: "      \(m.name)", action: nil, keyEquivalent: "")
                sub.attributedTitle = NSAttributedString(
                    string: sub.title,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(sub)
            }
            if !e.models.isEmpty || e.rss >= GB {
                let unload = NSMenuItem(title: "      Unload \(e.label)",
                                        action: #selector(freeEngine(_:)), keyEquivalent: "")
                unload.target = self
                unload.representedObject = e.engine
                menu.addItem(unload)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let h = headroom(availableGB: s.available / GB)
        let verdict = NSMenuItem(title: h.text, action: nil, keyEquivalent: "")
        verdict.attributedTitle = NSAttributedString(
            string: h.text,
            attributes: [.foregroundColor: h.warn ? NSColor.systemOrange
                                                  : NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 12)])
        menu.addItem(verdict)
        menu.addItem(NSMenuItem.separator())

        let all = NSMenuItem(title: "Free Everything", action: #selector(freeAll), keyEquivalent: "f")
        all.target = self
        menu.addItem(all)
        let win = NSMenuItem(title: "Open Panel", action: #selector(showPanel), keyEquivalent: "o")
        win.target = self
        menu.addItem(win)
        let act = NSMenuItem(title: "Activity Monitor", action: #selector(openActivity), keyEquivalent: "")
        act.target = self
        menu.addItem(act)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func freeEngine(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        item.button?.title = "  …"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = run(["free", name])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func freeAll() {
        item.button?.title = "  …"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = run(["free"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func openActivity() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

extension Controller: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

let app = NSApplication.shared
let delegate = Controller()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
