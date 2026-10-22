import Foundation
import Vision
import CoreImage

/// Apple Vision text recognition over a single broadcast frame.
/// Accurate recognition is requested; language correction is OFF because the
/// target languages are romanised Telugu/Urdu, which an English corrector mangles.
public enum OCRService {
    public static func recognise(cgImage: CGImage, capturedAt: Date = Date()) -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        return results.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return OCRObservation(text: candidate.string, x: b.origin.x, y: b.origin.y,
                                  width: b.size.width, height: b.size.height,
                                  confidence: candidate.confidence, capturedAt: capturedAt)
        }
    }

    public static func recognise(pixelBuffer: CVPixelBuffer, capturedAt: Date = Date()) -> [OCRObservation] {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return [] }
        return recognise(cgImage: cg, capturedAt: capturedAt)
    }
}
