import Foundation

// Regenerate native icon sizes from the approved masters, rather than drawing
// the previous wind glyph over the new identity.
let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["python3", root.appendingPathComponent("Design/AppIcons/scripts/package.py").path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
