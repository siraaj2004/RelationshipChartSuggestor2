import ReplayKit
import Vision
import CoreImage

/// ReplayKit Broadcast Upload Extension.
/// - Runs ONLY inside a broadcast the user started in iOS's system UI.
/// - Throttles to ~1 frame / 1.2s (scrolling produces near-duplicate frames;
///   ChatParser deduplicates what remains).
/// - OCR happens on-device. Only parsed text is written to the App Group.
///   Video frames are processed in memory and discarded — never saved or uploaded.
/// - Memory discipline: extensions are killed at ~50MB, so frames are handled
///   one at a time on a serial queue with an autorelease pool.
final class SampleHandler: RPBroadcastSampleHandler {

    private let store = SharedStore.shared
    private let queue = DispatchQueue(label: "broadcast.ocr", qos: .utility)
    private var frames: [ChatParser.Frame] = []
    private var sequence = 0
    private var lastProcessed = Date.distantPast
    private var lastUpload = Date.distantPast
    private let ciContext = CIContext()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        store?.scanState = .broadcasting
        frames = []; sequence = 0
    }

    override func broadcastPaused() { store?.scanState = .processing }
    override func broadcastResumed() { store?.scanState = .broadcasting }
    override func broadcastFinished() {
        persist()
        uploadToBackend(force: true)
        store?.scanState = .ready
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return } // audio is ignored entirely
        guard store?.scanState != .stopped else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= 1.2 else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let observations = OCRService.recognise(pixelBuffer: pixelBuffer, capturedAt: now)
                guard !observations.isEmpty else { return }
                self.frames.append(ChatParser.Frame(observations: observations, capturedAt: now, sequence: self.sequence))
                self.sequence += 1
                // Persist incrementally so a system kill of the extension loses nothing.
                if self.sequence % 3 == 0 { self.persist(); self.uploadToBackend(force: false) }
            }
        }
    }

    private func persist() {
        guard let store, !frames.isEmpty else { return }
        let ctx = ChatParser.parse(frames: frames)
        if !ctx.messages.isEmpty { store.saveContext(ctx) }
    }

    // MARK: Server relay (works even when the App Group is blocked)
    //
    // On free-signed installs iOS can block the App Group, so the context saved
    // above never reaches the app. As a second channel, the parsed text is also
    // POSTed to the user's backend (/scan-ingest), which generates suggestions
    // and holds them briefly for the app/keyboard to fetch (/scan-latest).
    // This runs ONLY during a broadcast the user explicitly started from the
    // app's consent-gated Scan screen — that start is the upload consent.
    // Only extracted text is sent; frames/video never leave the device.
    private func uploadToBackend(force: Bool) {
        guard !frames.isEmpty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpload) >= 15 else { return }
        lastUpload = now
        let ctx = ChatParser.parse(frames: frames)
        guard !ctx.messages.isEmpty else { return }
        guard let base = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
              let url = URL(string: base)?.appendingPathComponent("scan-ingest"),
              let key = Bundle.main.object(forInfoDictionaryKey: "AppAPIKey") as? String,
              !key.isEmpty else { return }
        let payload: [String: Any] = [
            "messages": ctx.messages.map { ["text": $0.text, "sender": $0.sender.rawValue, "confidence": $0.confidence] },
            "language_hint": ctx.language.rawValue,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.httpBody = body
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}
