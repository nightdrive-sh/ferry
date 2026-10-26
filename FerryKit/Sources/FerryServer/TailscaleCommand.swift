#if os(macOS)
import Foundation

/// The `tailscale` command, wherever this Mac's Tailscale put it. An app opened at login has no shell PATH, so the
/// places are fixed: the standalone app's CLI and Homebrew's in /usr/local/bin or /opt/homebrew/bin, else the binary
/// inside Tailscale.app (the App Store version), which works as the CLI when run directly. They are looked in on every
/// run, not once: Ferry is often opened before Tailscale is installed.
public struct TailscaleCommand: TailscaleCLI {
    public static let places = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    let places: [String]

    /// places: where the command may be, first found first (tests give their own)
    public init(places: [String] = Self.places) {
        self.places = places
    }

    /// path: a stand-in command, or none
    public init(path: String?) {
        self.init(places: path.map { [$0] } ?? [])
    }

    var path: String? { places.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public func status() async throws -> Data {
        try await run(["status", "--json"], timeout: 5).stdout
    }

    public func serveStatus() async throws -> Data {
        try await run(["serve", "status", "--json"], timeout: 5).stdout
    }

    public func serve(on: Bool, port: UInt16) async -> (ok: Bool, output: String) {
        let args = on ? ["serve", "--bg", "--https=443", "--set-path=/ferry", "http://127.0.0.1:\(port)"]
            : ["serve", "--https=443", "--set-path=/ferry", "off"]
        guard let r = try? await run(args, timeout: 30) else { return (false, "Tailscale isn't installed") }
        return (r.status == 0, String(decoding: r.stdout + r.stderr, as: UTF8.self))
    }

    /// Runs the command and gives its exit status, stdout and stderr apart: the JSON calls read stdout only, since
    /// Tailscale warns on stderr (e.g. a CLI and daemon of different versions), and serve's messages to the user may be
    /// on either. One that takes longer than timeout is stopped.
    private func run(_ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        guard let path else { throw TailscaleNotFound() }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: path)
                p.arguments = args
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return cont.resume(throwing: error) }
                let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                // Both read to the end before waiting, each on its own: a status with many machines is bigger than a
                // pipe's buffer, and a full stderr would block the command as surely as a full stdout
                let errors = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                DispatchQueue.global().async(group: errors) { errData = (try? err.fileHandleForReading.readToEnd()) ?? Data() }
                let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                errors.wait()
                p.waitUntilExit()
                stop.cancel()
                cont.resume(returning: (p.terminationStatus, outData, errData))
            }
        }
    }
}
#endif
