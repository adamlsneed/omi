import Foundation
import WatchConnectivity
import BackgroundTasks
import Flutter
import UIKit

final class WatchCaptureHost: WatchCaptureHostAPI {
    let store = WatchCaptureStore()
    private(set) var owner = ""
    private static let backgroundIdentifier = "com.omi.watch-capture.processing"
    private var foregroundMessenger: FlutterBinaryMessenger?
    private var backgroundEngine: FlutterEngine?
    private var flutter: WatchCaptureFlutterAPI?
    private var ready = false
    private var needsWake = false
    private var waking = false
    private var lease = UIBackgroundTaskIdentifier.invalid
    private var backgroundGrant: BGTask?
    private var wakeGeneration = 0

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundIdentifier, using: .main) { [weak self] task in
            guard let self else { task.setTaskCompleted(success: false); return }
            self.backgroundGrant = task
            task.expirationHandler = { [weak self] in
                DispatchQueue.main.async { self?.finishWake(success: false) }
            }
            self.requestProcessing()
        }
    }

    func attachForeground(messenger: FlutterBinaryMessenger) {
        foregroundMessenger = messenger
        // Finish a cold worker before admitting the UI engine as another writer.
        guard backgroundEngine == nil else { return }
        install(messenger)
    }

    private func install(_ messenger: FlutterBinaryMessenger) {
        ready = false
        flutter = WatchCaptureFlutterAPI(binaryMessenger: messenger)
        WatchCaptureHostAPISetup.setUp(binaryMessenger: messenger, api: self)
    }

    func requestProcessing() {
        needsWake = true
        scheduleRetry()
        if lease == .invalid {
            lease = UIApplication.shared.beginBackgroundTask(withName: "Save Watch capture") { [weak self] in
                DispatchQueue.main.async { self?.finishWake(success: false) }
            }
        }
        if flutter == nil {
            // Dedicated entrypoint restores auth and saves files only. It never
            // runs the ordinary app bootstrap, presents UI, or starts capture.
            let engine = FlutterEngine(name: "omi-watch-capture", project: nil, allowHeadlessExecution: true)
            backgroundEngine = engine
            guard engine.run(withEntrypoint: "watchCaptureBackgroundMain") else {
                finishWake(success: false)
                return
            }
            GeneratedPluginRegistrant.register(with: engine)
            install(engine.binaryMessenger)
        }
        flushWake()
    }

    private func flushWake() {
        guard ready, needsWake, !waking, let flutter else { return }
        needsWake = false
        waking = true
        let generation = wakeGeneration
        flutter.processPendingCaptures { [weak self] result in
            guard let self, generation == self.wakeGeneration else { return }
            self.waking = false
            if self.needsWake {
                self.flushWake()
            } else {
                if case .success = result { self.finishWake(success: true) }
                else { self.finishWake(success: false) }
            }
        }
    }

    private func finishWake(success: Bool) {
        wakeGeneration += 1
        waking = false
        needsWake = false
        if lease != .invalid {
            UIApplication.shared.endBackgroundTask(lease)
            lease = .invalid
        }
        backgroundGrant?.expirationHandler = nil
        backgroundGrant?.setTaskCompleted(success: success)
        backgroundGrant = nil
        if let engine = backgroundEngine {
            backgroundEngine = nil
            flutter = nil
            ready = false
            engine.destroyContext()
            if let messenger = foregroundMessenger { install(messenger) }
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard let records = try? store.records(), records.contains(where: { $0.status == "queued" }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { NSLog("[WatchCapture] Background retry remains queued: %@", String(describing: type(of: error))) }
    }

    func processIfDue() {
        guard let records = try? store.records(), records.contains(where: {
            $0.status == "queued" && $0.nextAttemptAt <= Date().timeIntervalSince1970
        }) else { return }
        requestProcessing()
    }

    func setCaptureOwner(owner: String) throws {
        self.owner = owner
        if !ready {
            ready = true
            DispatchQueue.main.async { self.flushWake() }
        }
        publishOwner()
    }

    func publishOwner() {
        let session = WCSession.default
        guard ready, session.activationState == .activated,
              session.applicationContext["captureOwner"] as? String != owner else { return }
        var context = session.applicationContext
        context["captureOwner"] = owner
        do { try session.updateApplicationContext(context) }
        catch { NSLog("[WatchCapture] Account context delivery deferred") }
    }

    func pendingCaptures() throws -> [WatchCaptureItem] {
        let pending = try store.records().filter {
            $0.owner == owner && $0.status == "queued" && $0.nextAttemptAt <= Date().timeIntervalSince1970
        }
        var items: [WatchCaptureItem] = []
        for record in pending {
            do {
                let audio = try record.transcript.isEmpty ? store.transcriptionAudioURL(record.id) : store.audioURL(record.id)
                items.append(WatchCaptureItem(id: record.id, owner: record.owner, destination: record.destination,
                                              path: audio.path, createdAt: record.createdAt,
                                              duration: record.duration, transcript: record.transcript,
                                              conversationId: record.conversationId))
            } catch {
                // One unreadable recording must not prevent its siblings from saving.
                try failCapture(id: record.id, owner: record.owner, reason: "audio_decode")
            }
        }
        return items
    }

    func checkpointCapture(id: String, owner: String, transcript: String, conversationId: String) throws {
        guard self.owner == owner else { throw WatchCaptureStoreError.conflictingRecord }
        _ = try store.update(id: id, owner: owner) { record in
            guard record.status != "saved" else { return }
            record.transcript = transcript
            record.conversationId = conversationId
        }
    }

    func finishCapture(id: String, owner: String, resultId: String) throws {
        guard self.owner == owner, !resultId.isEmpty else { throw WatchCaptureStoreError.conflictingRecord }
        let record = try store.update(id: id, owner: owner) {
            $0.resultId = resultId
            $0.status = "saved"
            $0.error = ""
        }
        sendReceipt(record)
    }

    func failCapture(id: String, owner: String, reason: String) throws {
        guard self.owner == owner else { return }
        let record = try store.update(id: id, owner: owner) {
            guard $0.status != "saved" else { return }
            let retryable = ["save_failed", "processing", "transport", "authTransient", "rateLimited", "server", "transcription"].contains(reason)
            $0.status = retryable ? "queued" : "failed"
            $0.retryCount += 1
            $0.nextAttemptAt = Date().timeIntervalSince1970 + min(900, 15 * pow(2, Double(min($0.retryCount, 6))))
            $0.error = reason
        }
        sendReceipt(record)
    }

    func reply(to message: [String: Any]) -> [String: Any] {
        do {
            if message["method"] as? String == "retryQuickCapture",
               let id = message["id"] as? String,
               let recordingOwner = message["owner"] as? String {
                // Retry may arrive before cold-start auth restoration. Requeue
                // only the matching record; the worker still requires live auth.
                _ = try store.update(id: id, owner: recordingOwner) {
                    guard $0.status != "saved" else { return }
                    $0.status = "queued"
                    $0.error = ""
                    $0.nextAttemptAt = 0
                    $0.retryCount = 0
                }
            }
            let ids = Set((message["ids"] as? [String] ?? []) + [message["id"] as? String ?? ""])
            let receipts = try store.records().filter { ids.contains($0.id) }.prefix(20).map {
                var value = $0.wire
                value.removeValue(forKey: "transcript")
                return value
            }
            return ready ? ["owner": owner, "captures": Array(receipts)] : ["captures": Array(receipts)]
        } catch {
            return ["owner": owner, "error": "storage"]
        }
    }

    private func sendReceipt(_ record: WatchCaptureRecord) {
        var message = record.wire
        message["method"] = "quickCaptureReceipt"
        // Receipt contains no transcript. The Watch only needs destination and server identity.
        message.removeValue(forKey: "transcript")
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }
}
