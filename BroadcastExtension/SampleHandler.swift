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
    private let ciContext = CIContext()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        store?.scanState = .broadcasting
        frames = []; sequence = 0
    }

    override func broadcastPaused() { store?.scanState = .processing }
    override func broadcastResumed() { store?.scanState = .broadcasting }
    override func broadcastFinished() {
        persist()
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
                if self.sequence % 3 == 0 { self.persist() }
            }
        }
    }

    private func persist() {
        guard let store, !frames.isEmpty else { return }
        let ctx = ChatParser.parse(frames: frames)
        if !ctx.messages.isEmpty { store.saveContext(ctx) }
    }
}
