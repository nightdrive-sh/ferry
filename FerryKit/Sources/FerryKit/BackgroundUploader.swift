import Foundation

/// What a background upload was, carried in its task's `taskDescription`: whoever hears the end (the share extension
/// while its sheet is open, otherwise the app that iOS wakes for it) knows what to say and which copy to remove.
public struct UploadNote: Codable, Equatable, Sendable {
    public let name: String
    public let machineName: String
    public let copy: URL

    public init(name: String, machineName: String, copy: URL) {
        self.name = name
        self.machineName = machineName
        self.copy = copy
    }

    public func encoded() -> String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }

    public static func decode(_ taskDescription: String?) -> UploadNote? {
        guard let taskDescription else { return nil }
        return try? JSONDecoder().decode(UploadNote.self, from: Data(taskDescription.utf8))
    }
}

/// The copies a share's files are uploaded from, in the App Group's container: the share's own files may vanish when
/// the extension ends, while the upload goes on.
public enum UploadCopies {
    public static func folder(appGroup: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "Uploads")
    }

    /// Copies left behind (an upload whose end nobody heard): every upload has ended within its hour by then.
    public static func prune(_ folder: URL, olderThan age: TimeInterval, now: Date) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > age { try? fm.removeItem(at: dir) }
        }
    }

    /// The copy's own folder (ShareContent puts each in one).
    public static func remove(_ note: UploadNote) {
        try? FileManager.default.removeItem(at: note.copy.deletingLastPathComponent())
    }
}

/// The stall check, about once a second: nothing has moved for `limit` while the process was running. Time while the
/// extension was suspended (the screen locked, another app in front) doesn't count: the daemon went on uploading
/// unseen, and only its byte counts say so.
struct StallWatch {
    let limit: Duration
    private var lastMove: ContinuousClock.Instant
    private var lastTick: ContinuousClock.Instant
    private var bytes: Int64 = 0
    /// A tick this much later than the last one means the process was suspended in between
    static let suspended: Duration = .seconds(3)

    init(limit: Duration, now: ContinuousClock.Instant) {
        self.limit = limit
        lastMove = now
        lastTick = now
    }

    mutating func tick(at now: ContinuousClock.Instant, bytes: Int64) -> Bool {
        if bytes > self.bytes {
            self.bytes = bytes
            lastMove = now
        }
        if now - lastTick > Self.suspended { lastMove = now }
        lastTick = now
        return now - lastMove > limit
    }
}

/// FileSender through a background URLSession: iOS carries the upload on if the share extension is ended (the sheet
/// closed with Continue in Background, or iOS ending it). While the sheet waits, it reports progress and fails like the
/// app when the computer stops taking bytes. A failed file keeps its copy, so Try again can send it.
public final class BackgroundUploader: NSObject, FileSender, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = "fi.feature.ferry.share"

    public static func configuration(appGroup: String) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.sharedContainerIdentifier = appGroup
        c.timeoutIntervalForResource = 3600   // after that, the notification says it didn't arrive
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return c
    }

    private struct Batch {
        let machineName: String
        let progress: @Sendable (Double) -> Void
        let delivered: @Sendable (Upload) -> Void
        var uploads: [Int: Upload]
        var total: Int64
        var sent: [Int: Int64] = [:]
        var bodies: [Int: Data] = [:]
        var error: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let appGroup: String
    private let stall: Duration
    /// An end heard with no sheet waiting for it: a task from an earlier share, or after Continue in Background
    private let onOrphanFailure: @Sendable (UploadNote) -> Void
    private let lock = NSLock()
    private var batch: Batch?
    private var tasks: [URLSessionUploadTask] = []
    private var watchdog: Task<Void, Never>?
    /// One session per identifier in a process: made on the first send, kept for the process's life
    private lazy var session = URLSession(configuration: Self.configuration(appGroup: appGroup), delegate: self, delegateQueue: nil)

    public init(appGroup: String, stall: Duration = .seconds(8),
                onOrphanFailure: @escaping @Sendable (UploadNote) -> Void = { _ in }) {
        self.appGroup = appGroup
        self.stall = stall
        self.onOrphanFailure = onOrphanFailure
    }

    public func send(_ files: [Upload], to machine: URL, machineName: String,
                     progress: @escaping @Sendable (Double) -> Void, delivered: @escaping @Sendable (Upload) -> Void) async throws {
        var made: [Int: Upload] = [:], all: [URLSessionUploadTask] = []
        for f in files {
            let task = session.uploadTask(with: HTTPBackend.uploadRequest(machine, name: f.name, type: f.type, clip: false),
                                          fromFile: f.file)
            task.taskDescription = UploadNote(name: f.name, machineName: machineName, copy: f.file).encoded()
            made[task.taskIdentifier] = f
            all.append(task)
        }
        begin(made, machineName: machineName, progress: progress, delivered: delivered)
        lock.withLock { tasks = all }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                batch?.continuation = c
                watchdog = Task { [weak self] in await self?.watch() }
            }
            all.forEach { $0.resume() }
        }
    }

    /// The sheet is closing with uploads still running: they go on in the background, nothing waits for them here,
    /// and an end heard from now on is told as a notification.
    public func detach() {
        finish(CancellationError())
    }

    // MARK: Ends

    func begin(_ uploads: [Int: Upload], machineName: String, progress: @escaping @Sendable (Double) -> Void,
               delivered: @escaping @Sendable (Upload) -> Void) {
        let total = uploads.values.reduce(Int64(0)) { sum, f in
            sum + Int64((try? f.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        lock.withLock {
            batch = Batch(machineName: machineName, progress: progress, delivered: delivered, uploads: uploads,
                          total: max(total, 1))
        }
    }

    /// One task's end. In the batch the sheet waits for: a delivered file's copy goes, a failed one stays for Try
    /// again. Otherwise the copy goes, and a failure is reported.
    func complete(_ id: Int, note: UploadNote?, failed: Bool, status: Int?, body: Data) {
        let refused = (status ?? 0) >= 400
        let inBatch = lock.withLock { () -> (upload: Upload, delivered: @Sendable (Upload) -> Void, all: Bool, error: (any Error)?)? in
            guard var b = batch, let upload = b.uploads.removeValue(forKey: id) else { return nil }
            if b.error == nil {
                if failed {
                    b.error = FerryError.unreachable(machine: b.machineName)
                } else if refused {
                    let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    b.error = FerryError.refused(status: status ?? 0, message: text)
                }
            }
            batch = b
            return (upload, b.delivered, b.uploads.isEmpty, b.error)
        }
        guard let inBatch else {
            if let note {
                UploadCopies.remove(note)
                if failed || refused { onOrphanFailure(note) }
            }
            return
        }
        if !failed, !refused {
            if let note { UploadCopies.remove(note) }
            inBatch.delivered(inBatch.upload)
        }
        if inBatch.all { finish(inBatch.error) }
    }

    /// Nothing sent for `stall` while the extension ran: the computer stopped answering. The sheet says so, and the
    /// uploads are cancelled (their copies stay for Try again).
    private func watch() async {
        var w = StallWatch(limit: stall, now: .now)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let (running, name) = lock.withLock { (tasks, batch?.machineName) }
            guard let name else { return }
            let bytes = running.reduce(Int64(0)) { $0 + $1.countOfBytesSent + $1.countOfBytesReceived }
            guard w.tick(at: .now, bytes: bytes) else { continue }
            finish(FerryError.unreachable(machine: name))
            running.forEach { $0.cancel() }
            return
        }
    }

    private func finish(_ error: (any Error)?) {
        let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            let c = batch?.continuation
            batch = nil
            tasks = []
            watchdog?.cancel()
            watchdog = nil
            return c
        }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let report = lock.withLock { () -> (@Sendable (Double) -> Void, Double)? in
            guard var b = batch, b.uploads[task.taskIdentifier] != nil else { return nil }
            b.sent[task.taskIdentifier] = totalBytesSent
            batch = b
            return (b.progress, min(1, Double(b.sent.values.reduce(0, +)) / Double(b.total)))
        }
        if let (progress, fraction) = report { progress(fraction) }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { batch?.bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let body = lock.withLock { batch?.bodies[task.taskIdentifier] } ?? Data()
        complete(task.taskIdentifier, note: UploadNote.decode(task.taskDescription), failed: error != nil,
                 status: (task.response as? HTTPURLResponse)?.statusCode, body: body)
    }
}

/// The app's side of the background session: iOS wakes the app when the share's uploads end after the extension is
/// gone. Each copy goes; a failure is handed on for a notification.
public final class UploadFinisher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onFailure: @Sendable (UploadNote) -> Void
    private let onAllDone: @Sendable () -> Void

    public init(onFailure: @escaping @Sendable (UploadNote) -> Void, onAllDone: @escaping @Sendable () -> Void) {
        self.onFailure = onFailure
        self.onAllDone = onAllDone
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let note = UploadNote.decode(task.taskDescription) else { return }
        UploadCopies.remove(note)
        let refused = (task.response as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? false
        if error != nil || refused { onFailure(note) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onAllDone()
    }
}
