#if os(macOS)
import Foundation
import Testing
@testable import FerryServer

@Suite struct TailscaleCommandTests {
    /// A stand-in for `tailscale` that answers like a CLI whose version differs from the daemon's: JSON on stdout, a
    /// warning on stderr
    func fake(exit: Int32 = 0) throws -> String {
        let script = tempFolder().appending(path: "tailscale")
        try """
        #!/bin/sh
        echo 'Warning: client version "1.90.0" != tailscaled server version "1.102.2"' >&2
        if [ "$1" = "serve" ] && [ "$2" != "status" ]; then echo "Serve is not enabled on your tailnet." >&2; exit \(exit); fi
        echo '{"BackendState":"Running","Self":{"DNSName":"macbook.tail1234.ts.net."}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test func jsonCallsReadStdoutOnly() async throws {   // Final review: a version warning broke the JSON
        let cli = TailscaleCommand(path: try fake())
        let status = try await cli.status()
        #expect(TailnetView(statusJSON: status).running)
        #expect(!String(decoding: status, as: UTF8.self).contains("Warning"))
        #expect(!String(decoding: try await cli.serveStatus(), as: UTF8.self).contains("Warning"))
    }

    @Test func serveKeepsTheMessages() async throws {
        let r = await TailscaleCommand(path: try fake(exit: 1)).serve(on: true, port: 47270)
        #expect(!r.ok)
        #expect(r.output.contains("Serve is not enabled on your tailnet."))
    }

    @Test func missingCommand() async {
        await #expect(throws: TailscaleNotFound.self) { try await TailscaleCommand(path: nil).status() }
    }

    /// Phase 4's clean Mac: Ferry opened first said "Install Tailscale" after Tailscale was installed, until it was
    /// opened again
    @Test func commandInstalledAfterwardsIsFound() async throws {
        let place = tempFolder().appending(path: "bin/tailscale").path
        let cli = TailscaleCommand(places: [place])
        await #expect(throws: TailscaleNotFound.self) { try await cli.status() }
        try FileManager.default.createDirectory(atPath: (place as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try fake(), toPath: place)
        #expect(TailnetView(statusJSON: try await cli.status()).running)
    }
}
#endif
