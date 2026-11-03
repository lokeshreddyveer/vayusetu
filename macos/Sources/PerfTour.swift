import SwiftUI

extension View {
    /// Marks a control the debug screen tour may click (`tab.*` for tab buttons, `nav.*` for drill-down rows). Does nothing in a release build.
    @ViewBuilder func perfTarget(_ id: String) -> some View {
        #if DEBUG
        modifier(PerfTargetModifier(id: id))
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit
import QuartzCore
import Darwin

/// Debug-only walk through every page and every nested screen the accessibility tree offers (tabs, drill-down rows), recording for each step how
/// smoothly the window drew: frame intervals from the display link, dropped frames, hitches, and the process's CPU share. It presses nothing but
/// navigation: only elements tagged `tab.*` or `nav.*` are pressed, and the sidebar is driven by a notification, so it cannot change settings,
/// start protection, or delete anything.
///
///     VayuSetu --perf-tour /path/report.json      writes the report and quits
///     VayuSetu --perf-tour-dump /path/tree.txt    writes the accessibility tree of the first page and quits
extension Notification.Name { static let perfTourPage = Notification.Name("app.vayusetu.perfTour.page") }

/// Where each tagged control is on screen now. Controls register on appear, follow layout changes and leave on disappear.
@MainActor final class PerfTargets {
    private(set) var order: [String] = []
    private var frames: [String: CGRect] = [:]
    func set(_ id: String, _ frame: CGRect) { if frames[id] == nil { order.append(id) }; frames[id] = frame }
    func remove(_ id: String) { frames[id] = nil; order.removeAll { $0 == id } }
    func frame(_ id: String) -> CGRect? { frames[id] }
}
struct PerfTargetModifier: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { PerfTour.targets.set(id, g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { _, frame in PerfTour.targets.set(id, frame) }
                .onDisappear { PerfTour.targets.remove(id) }
        })
    }
}

/// Lets a thread other than the main one see whether the main thread is still answering, and what screen it was on.
final class PerfBeat: @unchecked Sendable {
    private let lock = NSLock(); private var last = Date(); private var current = "start"
    func beat() { lock.lock(); last = Date(); lock.unlock() }
    func at(_ path: String) { lock.lock(); current = path; last = Date(); lock.unlock() }
    func state() -> (silent: TimeInterval, path: String) { lock.lock(); defer { lock.unlock() }; return (Date().timeIntervalSince(last), current) }
}

@MainActor final class PerfTour: NSObject {
    static let targets = PerfTargets()
    static let beat = PerfBeat()
    /// A screen that keeps the main thread busy for this long is reported as a hang: the stack is sampled and saved, and the tour ends.
    static let hangAfter: TimeInterval = 8
    private func startWatchdog(report: String?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in PerfTour.beat.beat() }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let (silent, path) = PerfTour.beat.state()
                guard silent > PerfTour.hangAfter else { continue }
                let base = (report ?? NSTemporaryDirectory() + "perf-tour.json")
                let sampleFile = base + ".hang-sample.txt"
                let sample = Process(); sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample"); sample.arguments = ["\(pid)", "2", "-file", sampleFile]
                try? sample.run(); sample.waitUntilExit()
                try? "HANG on \(path): the main thread did not answer for \(Int(silent)) s\nsample: \(sampleFile)\n".write(toFile: base + ".hang.txt", atomically: true, encoding: .utf8)
                exit(3)
            }
        }
    }
    static let shared = PerfTour()
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    struct Step: Codable {
        var path: String, kind: String, seconds: Double, frames: Int, fps: Double
        var p50: Double, p95: Double, p99: Double, worst: Double      // milliseconds between frames
        var hitches: Int, dropped: Int, cpu: Double, memoryMB: Double
    }

    // MARK: frame meter

    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var tickHook: ((CFTimeInterval) -> Void)?
    @objc private func tick(_ l: CADisplayLink) { stamps.append(l.timestamp); PerfTour.beat.beat(); tickHook?(l.timestamp) }

    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private var steps: [Step] = []
    /// With `--perf-shots DIR` every screen is also saved as a PNG (named after its path) and waits are shortened, for looking at the design.
    private var shots: URL? = PerfTour.argument("--perf-shots").map { URL(fileURLWithPath: $0, isDirectory: true) }
    private var pace: Double { shots == nil ? 1 : 0.35 }
    private func shoot(_ path: String) {
        guard let shots, let view = biggestScroller()?.documentView ?? window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = path.replacingOccurrences(of: " › ", with: "--").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // A page's scroll content has no background of its own (the window paints it), so lay it on the page colour before saving.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor(VSDesign.background).setFill(); NSRect(origin: .zero, size: rep.size).fill() }
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
    }
    private weak var window: NSWindow?

    /// Draws for `seconds` while `during` runs once at the start, then records how the frames went.
    private func measure(_ path: String, kind: String, seconds: Double, perFrame: ((Double) -> Void)? = nil, during: (() -> Void)? = nil) async {
        guard let view = window?.contentView else { return }
        PerfTour.beat.at(path)
        stamps = []
        let began = CACurrentMediaTime(), cpuBefore = cpuSeconds()
        tickHook = perFrame.map { hook in { now in hook(min(1, (now - began) / seconds)) } }
        link = view.displayLink(target: self, selector: #selector(tick(_:))); link?.add(to: .main, forMode: .common)
        during?()
        try? await Task.sleep(for: .seconds(seconds * pace))
        link?.invalidate(); link = nil; tickHook = nil
        let wall = CACurrentMediaTime() - began, cpu = (cpuSeconds() - cpuBefore) / wall * 100
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        guard !gaps.isEmpty else { steps.append(Step(path: path, kind: kind, seconds: wall, frames: 0, fps: 0, p50: 0, p95: 0, p99: 0, worst: 0, hitches: 0, dropped: 0, cpu: cpu, memoryMB: footprintMB())); return }
        func pct(_ p: Double) -> Double { gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
        let nominal = pct(0.5)
        let hitches = gaps.filter { $0 > nominal * 1.5 }.count
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        steps.append(Step(path: path, kind: kind, seconds: wall, frames: stamps.count, fps: Double(gaps.count) / max(0.001, (stamps.last ?? 0) - (stamps.first ?? 0)),
                          p50: nominal, p95: pct(0.95), p99: pct(0.99), worst: gaps.last ?? 0, hitches: hitches, dropped: dropped, cpu: cpu, memoryMB: footprintMB()))
    }

    // MARK: accessibility tree of this app, which needs no permission

    private struct Node { let object: NSObject; let role: String; let id: String; let label: String; let depth: Int }
    private func tree() -> [Node] {
        var out: [Node] = []
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 40, let element = object as? NSObject, let ax = element as? NSAccessibilityProtocol else { return }
            out.append(Node(object: element, role: ax.accessibilityRole()?.rawValue ?? "", id: ax.accessibilityIdentifier() ?? "", label: ax.accessibilityLabel() ?? "", depth: depth))
            for child in ax.accessibilityChildren() ?? [] { walk(child, depth + 1) }
        }
        if let window { walk(window, 0) }
        return out
    }
    private func press(_ node: Node) -> Bool { (node.object as? NSAccessibilityProtocol)?.accessibilityPerformPress() ?? false }

    /// A real mouse click at the control's centre, sent to the window the way the system would, so hit-testing and the button's own press handling run.
    private func click(_ id: String) -> Bool {
        guard let window, let view = window.contentView, let frame = PerfTour.targets.frame(id), frame.width > 0 else { return false }
        let point = view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    /// Scrolls the page until the control sits in the upper middle of the window, where a person could click it.
    private func reveal(_ id: String) async {
        guard let window, let view = window.contentView else { return }
        for _ in 0..<3 {
            guard let frame = PerfTour.targets.frame(id) else { return }
            let delta = frame.midY - view.bounds.height * 0.45
            if abs(delta) < view.bounds.height * 0.3, frame.midY < view.bounds.height - 40 { return }
            guard let scroller = biggestScroller() else { return }
            let clip = scroller.contentView, maxY = (scroller.documentView?.frame.height ?? 0) - clip.bounds.height
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, clip.bounds.origin.y + delta), max(0, maxY)))); scroller.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: scrolling

    private func biggestScroller() -> NSScrollView? {
        var best: (NSScrollView, CGFloat)?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView, doc.frame.height > s.contentView.bounds.height + 40, s.frame.width > 300 {
                let area = s.frame.width * s.frame.height
                if best == nil || area > best!.1 { best = (s, area) }
            }
            v.subviews.forEach(walk)
        }
        if let root = window?.contentView { walk(root) }
        return best?.0
    }
    private func scrollTest(_ path: String) async {
        guard let scroller = biggestScroller(), let doc = scroller.documentView else { return }
        let travel = doc.frame.height - scroller.contentView.bounds.height
        let top = scroller.contentView.bounds.origin.y
        await measure(path, kind: "scroll", seconds: 2.0, perFrame: { progress in
            // down for the first half, back up for the second: a smooth triangle, as a trackpad flick would be
            let t = progress < 0.5 ? progress * 2 : (1 - progress) * 2
            scroller.contentView.scroll(to: NSPoint(x: 0, y: top + travel * t)); scroller.reflectScrolledClipView(scroller.contentView)
        })
        scroller.contentView.scroll(to: NSPoint(x: 0, y: top)); scroller.reflectScrolledClipView(scroller.contentView)
    }

    // MARK: the tour

    private func explore(_ path: String, depth: Int, inherited: Set<String> = []) async {
        await measure(path, kind: "idle", seconds: 2.5)
        shoot(path)
        await scrollTest(path)
        guard depth < 3 else { return }
        // A pushed screen sits on top of its parent, which stays loaded: only the controls that appeared with this screen belong to it.
        let mine = PerfTour.targets.order.filter { !inherited.contains($0) }
        let seen = inherited.union(PerfTour.targets.order)
        let tabs = mine.filter { $0.hasPrefix("tab.") }
        for id in tabs {
            let name = String(id.dropFirst(4))
            await reveal(id)
            await measure("\(path) › \(name)", kind: "tab", seconds: 1.6, during: { _ = self.click(id) })
            await measure("\(path) › \(name)", kind: "idle", seconds: 2.0)
            shoot("\(path) › \(name)")
            await scrollTest("\(path) › \(name)")
        }
        // Back to the first tab so drill-down rows are looked for on the same screen each time.
        if let first = tabs.first { _ = click(first); try? await Task.sleep(for: .milliseconds(500)) }
        let links = mine.filter { $0.hasPrefix("nav.") }
        for id in links {
            let name = String(id.dropFirst(4))
            await reveal(id)
            await measure("\(path) › \(name)", kind: "push", seconds: 1.6, during: { _ = self.click(id) })
            await explore("\(path) › \(name)", depth: depth + 1, inherited: seen)
            if let back = tree().first(where: { $0.role == "AXButton" && ($0.label == "Back" || $0.label == "Go Back") }) {
                await measure("\(path) › \(name)", kind: "pop", seconds: 1.2, during: { _ = self.press(back) })
            } else {
                // No back button to press: leave through the sidebar, which also resets the page.
                NotificationCenter.default.post(name: .perfTourPage, object: nil, userInfo: ["page": Page.logs.rawValue])
                try? await Task.sleep(for: .milliseconds(300))
                NotificationCenter.default.post(name: .perfTourPage, object: nil, userInfo: ["page": path.components(separatedBy: " › ")[0]])
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    /// The app's own alert ("notice") is a sheet with an OK button; it would sit over every page, so it is closed and its text kept in the report.
    private var notices: [String] = []
    private func dismissAlerts() {
        while let ok = tree().first(where: { $0.role == "AXButton" && $0.label == "OK" }) {
            let texts = tree().filter { $0.role == "AXStaticText" }.map { ($0.object as? NSAccessibilityProtocol)?.accessibilityValue() as? String ?? "" }.filter { !$0.isEmpty }
            notices.append(texts.joined(separator: " | "))
            if !press(ok) { break }
        }
    }

    private func waitForWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }) { return w }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func run(output: String?, dump: String?, pages: [String]) async {
        guard let window = await waitForWindow() else { try? "no window".write(toFile: output ?? dump ?? "/dev/null", atomically: true, encoding: .utf8); NSApp.terminate(nil); return }
        self.window = window
        startWatchdog(report: output ?? dump)
        window.setContentSize(NSSize(width: Double(PerfTour.argument("--perf-width") ?? "") ?? 1180, height: 780))
        // A sheet from first-run onboarding would hide every page; close any that are up.
        for sheet in NSApp.windows.compactMap({ $0.attachedSheet }) { sheet.sheetParent?.endSheet(sheet) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        dismissAlerts()
        if let dump {
            if let first = pages.first { NotificationCenter.default.post(name: .perfTourPage, object: nil, userInfo: ["page": first]); try? await Task.sleep(for: .seconds(2)); dismissAlerts() }
            let lines = tree().map { String(repeating: "  ", count: $0.depth) + "[\($0.role)] id=\($0.id) label=\($0.label) value=\((($0.object as? NSAccessibilityProtocol)?.accessibilityValue() as? String) ?? "")" }
            try? (lines + ["--- targets"] + PerfTour.targets.order.map { "\($0) \(PerfTour.targets.frame($0).map { "\($0)" } ?? "")" }).joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8); NSApp.terminate(nil); return
        }
        for page in pages {
            NotificationCenter.default.post(name: .perfTourPage, object: nil, userInfo: ["page": page])
            try? await Task.sleep(for: .milliseconds(300)); dismissAlerts()
            await measure(page, kind: "enter", seconds: 1.4)
            await explore(page, depth: 0)
        }
        struct Report: Codable { var notices: [String]; var date: String; var build: String; var refreshHz: Int; var steps: [Step] }
        let report = Report(notices: notices, date: ISO8601DateFormatter().string(from: Date()), build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                            refreshHz: window.screen?.maximumFramesPerSecond ?? 0, steps: steps)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let shots { try? (notices.joined(separator: "\n")).write(to: shots.appendingPathComponent("notices.txt"), atomically: true, encoding: .utf8) }
        if let output, let data = try? encoder.encode(report) { try? data.write(to: URL(fileURLWithPath: output)) }
        NSApp.terminate(nil)
    }
}
#endif
