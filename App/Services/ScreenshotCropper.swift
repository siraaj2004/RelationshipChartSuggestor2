import UIKit
import CoreGraphics

/// Screenshot Adjustor — the accuracy step before suggestions.
///
/// Why this exists: a full phone screenshot contains a lot that is NOT
/// the chat — the status bar, the chat header, the keyboard/composer,
/// sometimes another chat above or below. The OCR pipeline already
/// drops the top 8% / bottom 10%, but a tall screenshot, a keyboard
/// left open, or a chat list peeking in can still leak wrong words
/// into the context, and old messages at the top can pull the reply
/// back to an old topic. Cropping to just the chat bubbles, and
/// keeping only the last few messages, gives the AI a cleaner,
/// current context — and that is what makes the reply more accurate.
///
/// The screenshot itself is never uploaded; cropping happens
/// on-device, before the same Vision OCR used by every other import.
enum ScreenshotCropper {

    /// Crop a screenshot by fractions of its height.
    /// - topFraction: 0.0 (keep from the very top) to 0.4 (drop the top 40%)
    /// - bottomFraction: 0.0 (keep to the very bottom) to 0.4 (drop the bottom 40%)
    /// Returns nil if the remaining slice would be empty or the
    /// image has no CGImage backing.
    static func croppedCGImage(from image: UIImage,
                               topFraction: CGFloat,
                               bottomFraction: CGFloat) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        let top = min(max(topFraction, 0), 0.4)
        let bottom = min(max(bottomFraction, 0), 0.4)
        guard top + bottom < 0.9 else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let y = height * top
        let cropHeight = height * (1 - top - bottom)
        guard cropHeight > 20 else { return nil }
        let rect = CGRect(x: 0, y: y, width: width, height: cropHeight)
        return cgImage.cropping(to: rect)
    }

    /// Preview image for the Adjustor screen, using the same crop.
    static func croppedUIImage(from image: UIImage,
                               topFraction: CGFloat,
                               bottomFraction: CGFloat) -> UIImage? {
        guard let cgImage = croppedCGImage(from: image,
                                           topFraction: topFraction,
                                           bottomFraction: bottomFraction) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
