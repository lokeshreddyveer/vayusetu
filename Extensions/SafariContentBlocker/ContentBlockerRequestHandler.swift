import Foundation
import UniformTypeIdentifiers

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    // Matches no real URL. The earlier "^$" placeholder made Safari block every page.
    private static let placeholder = Data("[{\"trigger\":{\"url-filter\":\"^https?://vayusetu-no-rules\\\\.invalid[:/]\"},\"action\":{\"type\":\"block\"}}]".utf8)

    private func container() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VayuAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    /// One handler serves all six extensions; each names its own rules file in its Info.plist.
    private var fileName: String {
        (Bundle.main.object(forInfoDictionaryKey: "VayuRulesFile") as? String).flatMap { $0.hasPrefix("safari-rules") ? $0 : nil } ?? "safari-rules.json"
    }
    /// The last few times Safari asked this extension for rules, so the app can show whether the extension ran and what it returned.
    private func log(_ text: String) {
        guard let container = container() else { return }
        let url = container.appendingPathComponent(fileName.replacingOccurrences(of: ".json", with: ".log"))
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(ISO8601DateFormatter().string(from: Date()) + " " + text)
        try? lines.suffix(5).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func beginRequest(with context: NSExtensionContext) {
        do {
            guard let container = container() else {
                throw NSError(domain: "VayuSetu.Safari", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared rules container unavailable."])
            }
            let source = container.appendingPathComponent(fileName)
            // Never parse a large package here: a content-blocker extension has a small memory budget, and the app has
            // already validated the rules. Copy the file for an immutable per-request snapshot and hand it to Safari.
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            var size = 0
            if FileManager.default.fileExists(atPath: source.path) {
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                size = values.fileSize ?? 0
                guard values.isRegularFile == true, values.isSymbolicLink != true, size <= 25_000_000 else { throw NSError(domain: "VayuSetu.Safari", code: 2) }
                // An old app version wrote the bad "^$" placeholder (a few dozen bytes); never serve it.
                if size <= 2 || (size < 200 && (try? String(contentsOf: source, encoding: .utf8))?.contains("\"^$\"") == true) {
                    // Older versions published [], which WebKit cannot compile; use a valid, nonmatching rule.
                    try Self.placeholder.write(to: snapshot, options: .atomic)
                } else { try FileManager.default.copyItem(at: source, to: snapshot) }
            } else {
                try Self.placeholder.write(to: snapshot, options: .atomic)
            }
            guard let provider = NSItemProvider(contentsOf: snapshot) else { throw NSError(domain: "VayuSetu.Safari", code: 4) }
            let item = NSExtensionItem(); item.attachments = [provider]
            log("served \(size) bytes from \(fileName)")
            context.completeRequest(returningItems: [item])
        } catch {
            log("failed: \(error.localizedDescription)")
            context.cancelRequest(withError: NSError(domain: "VayuSetu.Safari", code: 5, userInfo: [NSLocalizedDescriptionKey: "Rules could not be loaded. Reload from VayuSetu."]))
        }
    }
}
