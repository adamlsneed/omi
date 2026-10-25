import AVFoundation
import Combine
import SwiftUI
import WatchConnectivity
import WatchKit

/// Short intentional capture uses a file handoff, never the pendant's live stream.
@MainActor
final class WatchQuickCapture: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var transfers: [String: Progress] = [:]
    @Published private(set) var records: [WatchCaptureRecord] = []
    @Published private(set) var active: WatchCaptureRecord?
    @Published private(set) var starting = false
    @Published private(set) var errorKey: String?
    private let store = WatchCaptureStore()
    private let account = WatchCaptureOwnerCache()
    private let session: WCSession
    private var recorder: AVAudioRecorder?
    private var generation = 0
    private var interruption: AnyCancellable?

    init(session: WCSession) {
        self.session = session
        super.init()
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                        AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.stop() }
            }
        reload()
        // Interrupted recordings remain visible and retained. Retry sends the audio we have.
        for record in records where record.status == "recording" {
            do {
                let url = try store.audioURL(record.id)
                let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
                _ = try store.update(id: record.id, owner: record.owner) {
                    $0.duration = min(duration, 300)
                    $0.status = "failed"
                    $0.error = "interrupted"
                }
            } catch { errorKey = "watch.capture.storageError" }
        }
        reload()
    }

    func start(_ destination: String) {
        guard !starting, active == nil, ["idea", "task"].contains(destination) else { return }
        guard !account.owner.isEmpty else {
            errorKey = "watch.capture.openPhone"
            refresh()
            return
        }
        starting = true
        errorKey = nil
        generation += 1
        // Recording never waits for phone reachability or a network request.
        begin(destination: destination, owner: account.owner, generation: generation)
    }

    private func begin(destination: String, owner: String, generation current: Int) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                defer { self.starting = false }
                guard granted else { self.errorKey = "watch.capture.microphoneError"; return }
                var newRecord: WatchCaptureRecord?
                do {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.record, mode: .default)
                    try audio.setActive(true)
                    let record = WatchCaptureRecord(owner: owner, destination: destination,
                                                    createdAt: Date().timeIntervalSince1970)
                    try self.store.save(record)
                    newRecord = record
                    let recorder = try AVAudioRecorder(url: self.store.audioURL(record.id), settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 16000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32000
                    ])
                    recorder.delegate = self
                    guard recorder.record(forDuration: 300) else { throw WatchCaptureStoreError.invalidRecord }
                    self.recorder = recorder
                    self.active = record
                    WKInterfaceDevice.current().play(.start)
                } catch {
                    if let record = newRecord {
                        _ = try? self.store.update(id: record.id, owner: record.owner) {
                            $0.status = "failed"
                            $0.error = "recording"
                        }
                    }
                    self.errorKey = "watch.capture.recordingError"
                    try? AVAudioSession.sharedInstance().setActive(false)
                    self.reload()
                }
            }
        }
    }

    func stop() {
        guard let current = active, let recorder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        finish(current, duration: duration)
    }

    private func finish(_ current: WatchCaptureRecord, duration: Double) {
        guard active?.id == current.id else { return }
        active = nil
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        do {
            let record = try store.update(id: current.id, owner: current.owner) {
                $0.duration = min(max(duration, 0.01), 300)
                $0.status = "queued"
            }
            transfer(record)
            WKInterfaceDevice.current().play(.stop)
        } catch { errorKey = "watch.capture.storageError" }
        reload()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, let record = self.active else { return }
            let duration = (try? AVAudioPlayer(contentsOf: recorder.url).duration) ?? 0
            self.finish(record, duration: duration)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.errorKey = "watch.capture.recordingError"
            self.stop()
        }
    }

    func retry(_ id: String) {
        guard let record = records.first(where: { $0.id == id && $0.status != "saved" }) else { return }
        do {
            _ = try store.update(id: id, owner: record.owner) {
                $0.status = "queued"
                $0.error = ""
                $0.processingPhase = nil
            }
            // Queued user-info delivery works with the phone locked or offline.
            session.transferUserInfo(["method": "retryQuickCapture", "id": id, "owner": record.owner])
            transfer(record)
            reload()
            refresh()
        } catch { errorKey = "watch.capture.storageError" }
    }

    func connected() {
        receiveAccountContext(session.receivedApplicationContext)
        for record in records where record.status == "queued" { transfer(record) }
        refresh()
    }

    func receiveAccountContext(_ context: [String: Any]) {
        if let owner = context["captureOwner"] as? String { account.receive(owner) }
    }

    private func transfer(_ record: WatchCaptureRecord) {
        guard session.activationState == .activated else { return }
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["id"] as? String == record.id }) else { return }
        do {
            let url = try store.audioURL(record.id)
            var metadata = record.wire
            metadata["method"] = "quickCaptureFile"
            metadata.removeValue(forKey: "transcript")
            session.transferFile(url, metadata: metadata)
        } catch { errorKey = "watch.capture.storageError" }
    }

    func transferFinished(id: String, failed: Bool) {
        // A newer phone receipt takes precedence over transport completion.
        guard let record = records.first(where: { $0.id == id }), record.status == "queued",
              record.processingPhase == nil || record.processingPhase == "" else { return }
        do {
            _ = try store.update(id: id, owner: record.owner) {
                if failed {
                    $0.status = "failed"
                    $0.error = "transport"
                } else {
                    $0.processingPhase = "waitingProcessing"
                }
            }
            reload()
        } catch { errorKey = "watch.capture.storageError" }
        refresh()
    }

    func refresh() {
        transfers = Dictionary(session.outstandingFileTransfers.compactMap { transfer in
            guard let id = transfer.file.metadata?["id"] as? String else { return nil }
            return (id, transfer.progress)
        }, uniquingKeysWith: { first, _ in first })
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["method": "quickCaptureContext", "ids": Array(records.filter { $0.status == "queued" }.prefix(20).map(\.id))], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.applyContext(reply) }
        }, errorHandler: { _ in })
    }

    private func applyContext(_ context: [String: Any]) {
        if let owner = context["owner"] as? String { account.receive(owner) }
        let receipts = context["captures"] as? [[String: String]] ?? []
        let received = Set(receipts.compactMap { $0["id"] })
        for receipt in receipts { receive(receipt) }
        // Relaunch/reconnection resumes file delivery, but failed server writes require Retry.
        for record in records where record.status == "queued" && record.owner == context["owner"] as? String && !received.contains(record.id) {
            transfer(record)
        }
    }

    func receive(_ receipt: [String: String]) {
        guard let id = receipt["id"], let owner = receipt["owner"],
              let before = records.first(where: { $0.id == id && $0.owner == owner }), before.status != "saved" else { return }
        do {
            let updated = try store.update(id: id, owner: owner) { _ = $0.applyReceipt(receipt) }
            if updated.status == "saved" { WKInterfaceDevice.current().play(.success) }
        } catch { errorKey = "watch.capture.storageError" }
        reload()
    }

    private func reload() {
        do { records = try store.records() }
        catch { errorKey = "watch.capture.storageError" }
    }
}

struct WatchQuickCaptureView: View {
    @ObservedObject var capture: WatchQuickCapture
    @ObservedObject var recorder: WatchAudioRecorderViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let active = capture.active {
                    Label(active.destination == "idea" ? "watch.capture.idea" : "watch.capture.task",
                          systemImage: active.destination == "idea" ? "lightbulb" : "checkmark.circle")
                    Text(Date(timeIntervalSince1970: active.createdAt), style: .timer)
                        .font(.title2).monospacedDigit()
                    Button("watch.capture.stopSave") { capture.stop() }
                        .accessibilityIdentifier("watch-stop-save")
                    Text("watch.capture.limit").font(.caption2).foregroundStyle(.secondary)
                } else {
                    if let error = recorder.recoveryError {
                        Text(error).font(.caption2).multilineTextAlignment(.center)
                    }
                    if recorder.pendingRecoverySegments > 0 {
                        if recorder.recoveryError == nil {
                            Text("watch.recovery.pending").font(.caption2)
                        }
                        Button("watch.recovery.retry") { recorder.retryRecoveryTransfers() }
                            .accessibilityIdentifier("watch-retry-recording-recovery")
                    }
                    Button { capture.start("idea") } label: {
                        Label("watch.capture.idea", systemImage: "lightbulb")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.accessibilityIdentifier("watch-record-idea")
                    Button { capture.start("task") } label: {
                        Label("watch.capture.task", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.accessibilityIdentifier("watch-record-task")
                    if capture.starting { ProgressView() }
                    if let error = capture.errorKey { Text(LocalizedStringKey(error)).font(.caption2) }
                    let pending = capture.records.filter { $0.status != "recording" && $0.status != "saved" }
                    let saved = Array(capture.records.filter { $0.status == "saved" }.prefix(10))
                    if !pending.isEmpty {
                        Text("watch.capture.pendingHeading").font(.caption).foregroundStyle(.secondary)
                        ForEach(pending) { record in captureRow(record) }
                    }
                    if !saved.isEmpty {
                        Text("watch.capture.savedHeading").font(.caption).foregroundStyle(.secondary)
                        ForEach(saved) { record in captureRow(record) }
                    }
                }
            }.disabled(capture.starting).padding(.horizontal, 4)
        }
        .task {
            while !Task.isCancelled {
                capture.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    private func captureRow(_ record: WatchCaptureRecord) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let transfer = capture.transfers[record.id]
            let stage = record.stage(now: context.date.timeIntervalSince1970,
                                     transferFraction: transfer?.fractionCompleted)
            VStack(spacing: 4) {
                Text(record.destination == "idea" ? "watch.capture.idea" : "watch.capture.task").font(.headline)
                Text(Date(timeIntervalSince1970: record.createdAt), style: .time).font(.caption2)
                if stage == .sending, let transfer {
                    ProgressView(transfer)
                        .accessibilityLabel(Text("watch.capture.sending"))
                } else if stage.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: stage.isSaved ? "checkmark.circle.fill" : (stage.showsRetry ? "exclamationmark.circle" : "clock"))
                        .foregroundStyle(stage.isSaved ? .green : .secondary)
                        .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(stage.localizationKey)).font(.caption)
                if stage.showsRetry {
                    Button("watch.capture.retry") { capture.retry(record.id) }
                        .accessibilityIdentifier("watch-retry-\(record.id)")
                }
            }.padding(.vertical, 6)
        }
    }
}
