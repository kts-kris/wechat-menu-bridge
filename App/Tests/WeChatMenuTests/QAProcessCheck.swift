import Foundation

// The script that owns the batch publishes atomic snapshots of its QA processes.
enum QAProcessCheck {
    enum Fault: Error { case launchGateClosed, scanFailed, scanTimedOut }

    static func liveApps(in stage: URL) throws -> String {
        let path = stage.appendingPathComponent("process-snapshot")
        let closed = stage.appendingPathComponent("no-more-launches")
        func snapshot() -> (Int, Substring, Substring)? {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard lines.count == 3, let seq = Int(lines[0]) else { return nil }
            return (seq, lines[1], lines[2])
        }
        // A scan may already be in progress. The second later sequence must
        // have been sampled after we started waiting, not just published later.
        let first = snapshot()?.0 ?? 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if FileManager.default.fileExists(atPath: closed.path) { throw Fault.launchGateClosed }
            if let (seq, status, processes) = snapshot() {
                guard status == "ok" else { throw Fault.scanFailed }
                if seq >= first + 2 { return String(processes) }
            }
            Thread.sleep(forTimeInterval: 0.04)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Fault.scanTimedOut
    }
}
