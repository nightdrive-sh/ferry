import Foundation

/// The computer's settings, with the values bin/ferry uses, so a Mac and a Linux computer behave alike to the phone.
public struct ServerConfig: Sendable {
    /// Where the box and the server's state live: `~/Library/Application Support/Ferry/` in the app, a temp folder in tests
    public var state: URL
    /// The local server, 127.0.0.1 only: `tailscale serve` is the way in. 0 picks any free port (tests).
    public var port: UInt16 = 47270
    /// The path `tailscale serve` publishes the server at, which it strips before the request reaches us
    public var mount = "/ferry"
    public var httpsPort = 443
    public var keepDays = 7
    /// Bytes per file from a device
    public var maxFile: Int64 = 4 << 30
    /// Characters of a text, as bin/ferry cuts them
    public var maxText = 1 << 20
    /// Bytes of a notification's content: Ferry's push relay takes 2800 encrypted (APNs' 4 KB as base64)
    public var pushPayload = 2600
    /// Bytes left free on the disk: an upload that would go below this is refused
    public var minFree: Int64 = 2 << 30
    /// Seconds within which files from a device share one notification
    public var groupNotify: TimeInterval = 20
    /// Input within this many seconds counts as "in use" (idle 0), as the Linux desktop counts idle only after a minute
    public var idleInUse = 60
    /// Seconds between the server's looks for the owner's other computers
    public var machinesEvery: TimeInterval = 301
    /// A machine that answered as Ferry is asked again after this, one that didn't after `probeMissedAgain`
    public var probeAgain: TimeInterval = 60
    public var probeMissedAgain: TimeInterval = 10
    public var probeTimeout: TimeInterval = 4
    /// Seconds a push service keeps a notification for a phone that is off: the box's week
    public var pushTTL = 604_800
    /// The VAPID "sub": push services want a contact URL
    public var pushContact = "https://github.com/nightdrive-sh/ferry"

    public init(state: URL) {
        self.state = state
    }
}
