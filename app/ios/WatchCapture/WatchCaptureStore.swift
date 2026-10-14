import Foundation
import AVFoundation

/// A receipt belongs to one explicit capture and one signed-in account/environment.
/// Files and checkpoints survive process death; transport completion is never a save receipt.
struct WatchCaptureRecord: Codable, Equatable, Identifiable {
    let id: String
    let owner: String
    let destination: String
    let createdAt: Double
    var duration: Double = 0
    var status = "recording"
    var transcript = ""
    var conversationId = ""
    var resultId = ""
    var error = ""
    var retryCount = 0
    var nextAttemptAt: Double = 0

    var wire: [String: String] {
        ["id": id, "owner": owner, "destination": destination,
         "createdAt": String(createdAt), "duration": String(duration),
         "status": status, "transcript": transcript, "conversationId": conversationId,
         "resultId": resultId, "error": error]
    }

    init(id: String = UUID().uuidString, owner: String, destination: String, createdAt: Double) {
        self.id = id
        self.owner = owner
        self.destination = destination
        self.createdAt = createdAt
    }

    init?(metadata: [String: Any]) {
        guard let id = metadata["id"] as? String, UUID(uuidString: id) != nil,
              let owner = metadata["owner"] as? String,
              owner.count == 64, owner.allSatisfy({ $0.isHexDigit }),
              let destination = metadata["destination"] as? String,
              ["idea", "task"].contains(destination),
              let created = metadata["createdAt"] as? String,
              let createdAt = Double(created), createdAt.isFinite,
              let seconds = metadata["duration"] as? String,
              let duration = Double(seconds), duration.isFinite, duration > 0, duration <= 301
        else { return nil }
        self.init(id: id, owner: owner, destination: destination, createdAt: createdAt)
        self.duration = duration
        status = "queued"
    }

    /// Reject stale, foreign or incomplete receipts. Saved is monotonic.
    mutating func applyReceipt(_ receipt: [String: String]) -> Bool {
        guard receipt["id"] == id, receipt["owner"] == owner,
              receipt["destination"] == destination, status != "saved",
              let next = receipt["status"], ["queued", "failed", "saved"].contains(next)
        else { return false }
        if next == "saved" {
            guard let savedId = receipt["resultId"], !savedId.isEmpty else { return false }
            resultId = savedId
        }
        status = next
        error = receipt["error"] ?? ""
        return true
    }
}

/// A one-time account association lets recording start without a live phone.
/// Captures retain the association they started with across later account changes.
final class WatchCaptureOwnerCache {
    private let defaults: UserDefaults
    private let key = "watch.quickCapture.owner"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var owner: String { defaults.string(forKey: key) ?? "" }
    func receive(_ owner: String) {
        guard owner.isEmpty || (owner.count == 64 && owner.allSatisfy({ $0.isHexDigit })) else { return }
        defaults.set(owner, forKey: key)
    }
}

enum WatchCaptureStoreError: Error { case invalidRecord, missingRecord, conflictingRecord }

/// Shared file/checkpoint primitive for Watch outbox and phone inbox.
final class WatchCaptureStore: @unchecked Sendable {
    let root: URL
    private let lock = NSRecursiveLock()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchQuickCaptures", isDirectory: true)
    }

    func audioURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw WatchCaptureStoreError.invalidRecord }
        return root.appendingPathComponent(id).appendingPathExtension("m4a")
    }

    /// The hosted multipart route accepts WAV, but rejects .m4a filenames.
    /// Decode to PCM WAV so it can also measure the real duration for quota.
    /// Keep the original AAC and publish the derived file only after closing it.
    func transcriptionAudioURL(_ id: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let source = try audioURL(id)
        let target = root.appendingPathComponent(id).appendingPathExtension("wav")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temporary = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try autoreleasepool {
            let input = try AVAudioFile(forReading: source)
            guard input.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)
            else { throw WatchCaptureStoreError.invalidRecord }
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: input.processingFormat.sampleRate,
                AVNumberOfChannelsKey: input.processingFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw WatchCaptureStoreError.invalidRecord }
                try output.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    func records() throws -> [WatchCaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(WatchCaptureRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ record: WatchCaptureRecord) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try audioURL(record.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(
            to: root.appendingPathComponent(record.id).appendingPathExtension("json"), options: .atomic)
    }

    func update(id: String, owner: String, _ change: (inout WatchCaptureRecord) -> Void) throws -> WatchCaptureRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.id == id && $0.owner == owner }) else {
            throw WatchCaptureStoreError.missingRecord
        }
        change(&record)
        try save(record)
        return record
    }

    /// WCSession's temporary file must be copied before its delegate returns.
    /// Repeated transfers cannot overwrite a transcript, error or save receipt.
    func receive(_ source: URL, metadata: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = WatchCaptureRecord(metadata: metadata) else { throw WatchCaptureStoreError.invalidRecord }
        if let existing = try records().first(where: { $0.id == record.id }) {
            guard existing.owner == record.owner, existing.destination == record.destination else {
                throw WatchCaptureStoreError.conflictingRecord
            }
            return
        }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 10_000_000 else { throw WatchCaptureStoreError.invalidRecord }
        let target = try audioURL(record.id)
        // Atomic replacement also recovers a crash between copying audio and writing metadata.
        try Data(contentsOf: source).write(to: target, options: .atomic)
        try save(record)
    }
}
