import Foundation
import Testing
@testable import FerryKit

/// What can be checked of the background upload outside the simulator: the session's settings, the note a task
/// carries, and the clean-up of copies. The upload itself runs in ShareTests (ios/uitest.sh).
struct BackgroundUploadTests {
    @Test func noteRoundTrips() {
        let note = UploadNote(name: "photo.jpg", machineName: "MacBook", copy: URL(filePath: "/tmp/x/photo.jpg"))
        #expect(UploadNote.decode(note.encoded()) == note)
        #expect(UploadNote.decode(nil) == nil)
        #expect(UploadNote.decode("x") == nil)
    }

    @Test func pruneKeepsRecentFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "uploads-\(UUID().uuidString)")
        let old = root.appending(path: UUID().uuidString), new = root.appending(path: UUID().uuidString)
        for dir in [old, new] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appending(path: "a.jpg"))
        }
        let now = Date()
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-3 * 3600)], ofItemAtPath: old.path())
        UploadCopies.prune(root, olderThan: 7200, now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path()))
        #expect(FileManager.default.fileExists(atPath: new.path()))
    }

    @Test func removeTakesTheCopysFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: "a.jpg")
        try Data("x".utf8).write(to: copy)
        UploadCopies.remove(UploadNote(name: "a.jpg", machineName: "MacBook", copy: copy))
        #expect(!FileManager.default.fileExists(atPath: dir.path()))
    }

    @Test func configurationValues() {
        let c = BackgroundUploader.configuration(appGroup: "group.fi.feature.ferry")
        #expect(c.identifier == "fi.feature.ferry.share")
        #expect(c.sharedContainerIdentifier == "group.fi.feature.ferry")
        #expect(c.timeoutIntervalForResource == 3600)
        #expect(c.sessionSendsLaunchEvents)
        #expect(!c.isDiscretionary)
    }
}

/// The uploader's handling of a task's end, and of the stall check (review: Try again found its copies deleted, and
/// an upload went on unseen while the extension was suspended, then was cancelled as stalled).
@Suite(.serialized) struct BackgroundUploaderEndTests {
    func copy() throws -> (Upload, UploadNote) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "photo.jpg")
        try Data("x".utf8).write(to: file)
        return (Upload(file: file, name: "photo.jpg", type: "image/jpeg"),
                UploadNote(name: "photo.jpg", machineName: "MacBook", copy: file))
    }

    final class Heard: @unchecked Sendable {
        let lock = NSLock()
        var notes: [UploadNote] = []
        var delivered: [Upload] = []
        func note(_ n: UploadNote) { lock.withLock { notes.append(n) } }
        func deliver(_ u: Upload) { lock.withLock { delivered.append(u) } }
    }

    @Test func aFailedUploadKeepsItsCopyForTryAgain() throws {
        let heard = Heard()
        let u = BackgroundUploader(appGroup: "group.test", onOrphanFailure: heard.note)
        let (upload, note) = try copy()
        u.begin([1: upload], machineName: "MacBook", progress: { _ in }, delivered: heard.deliver)
        u.complete(1, note: note, failed: true, status: nil, body: Data())
        #expect(FileManager.default.fileExists(atPath: upload.file.path()))
        #expect(heard.delivered.isEmpty)
        #expect(heard.notes.isEmpty)   // the sheet says it, not a notification
    }

    @Test func aDeliveredUploadRemovesItsCopy() throws {
        let heard = Heard()
        let u = BackgroundUploader(appGroup: "group.test", onOrphanFailure: heard.note)
        let (upload, note) = try copy()
        u.begin([1: upload], machineName: "MacBook", progress: { _ in }, delivered: heard.deliver)
        u.complete(1, note: note, failed: false, status: 200, body: Data())
        #expect(!FileManager.default.fileExists(atPath: upload.file.path()))
        #expect(heard.delivered == [upload])
    }

    @Test func aRefusedUploadIsAFailure() throws {
        let heard = Heard()
        let u = BackgroundUploader(appGroup: "group.test", onOrphanFailure: heard.note)
        let (upload, note) = try copy()
        u.begin([1: upload], machineName: "MacBook", progress: { _ in }, delivered: heard.deliver)
        u.complete(1, note: note, failed: false, status: 507, body: Data("Disk full".utf8))
        #expect(heard.delivered.isEmpty)
        #expect(FileManager.default.fileExists(atPath: upload.file.path()))
    }

    @Test func anEndHeardWithNoSheetWaitingIsReported() throws {
        let heard = Heard()
        let u = BackgroundUploader(appGroup: "group.test", onOrphanFailure: heard.note)
        let (upload, note) = try copy()
        u.complete(7, note: note, failed: true, status: nil, body: Data())   // a task from an earlier share
        #expect(heard.notes == [note])
        #expect(!FileManager.default.fileExists(atPath: upload.file.path()))
    }

    @Test func afterContinueInBackgroundAFailureIsReported() throws {
        let heard = Heard()
        let u = BackgroundUploader(appGroup: "group.test", onOrphanFailure: heard.note)
        let (upload, note) = try copy()
        u.begin([1: upload], machineName: "MacBook", progress: { _ in }, delivered: heard.deliver)
        u.detach()
        u.complete(1, note: note, failed: true, status: nil, body: Data())
        #expect(heard.notes == [note])
        #expect(!FileManager.default.fileExists(atPath: upload.file.path()))
    }

    @Test func stallCountsOnlyWhileNothingMoves() {
        let start = ContinuousClock.now
        var w = StallWatch(limit: .seconds(8), now: start)
        for s in 1...20 { let r = w.tick(at: start + .seconds(s), bytes: Int64(s) * 1000); #expect(!r) }   // moving
        var stalled = false
        for s in 21...30 { stalled = w.tick(at: start + .seconds(s), bytes: 20_000) }
        #expect(stalled)
    }

    @Test func aSuspendedProcessIsNoStall() {
        let start = ContinuousClock.now
        var w = StallWatch(limit: .seconds(8), now: start)
        let r1 = w.tick(at: start + .seconds(1), bytes: 100); #expect(!r1)
        let r2 = w.tick(at: start + .seconds(60), bytes: 100); #expect(!r2)   // the screen locked: the daemon went on unseen
        for s in 61...68 { let r = w.tick(at: start + .seconds(s), bytes: 100); #expect(!r) }
        let r3 = w.tick(at: start + .seconds(70), bytes: 100); #expect(r3)     // awake again, and really nothing moves
    }
}
