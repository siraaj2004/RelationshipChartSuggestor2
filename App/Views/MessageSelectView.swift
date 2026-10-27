import SwiftUI
import UIKit

/// Select Message (new in 1.9.0) — the most accurate way to reply.
///
/// Flow, exactly as shaik asked for it:
///  1. Open the chat (Instagram / WhatsApp / Snapchat) and screenshot it.
///  2. Open Relationship AI → tap "Select a message 📸" — that latest
///     screenshot opens here, in this companion app.
///  3. Drag your finger to draw a rectangle around ONE particular
///     message. Only that rectangle is read — nothing else on the
///     screen, no other message, no header, no keyboard.
///  4. Tap "Generate replies for this message" — on-device OCR reads
///     only the selected message, the app detects Roman Urdu /
///     Roman Telugu / English from that message, and you get 3
///     replies in that language. Tap a suggestion in the app to copy
///     it, or open the custom keyboard where the same suggestions
///     are available.
///
/// Why a rectangle beats a whole screenshot: a whole screenshot
/// always contains other messages, and the AI can answer the wrong
/// one or mix two topics. A single selected message has exactly one
/// thing to answer, so the reply stays on that message.
///
/// The screenshot itself never leaves this phone. Only the text
/// read from the selected rectangle can go to the backend, and only
/// with consent ON — the same rule as every other import.
///
/// Implementation note: the image is shown at a known, computed
/// size (full width, aspect preserved, capped at 65% of screen
/// height), so a drag point maps cleanly to a normalised rectangle
/// in the full image. Sender is judged from the rectangle's centre
/// in the FULL screenshot (left = them, right = you), not in the
/// crop — a cropped bubble on its own would always look centred.
struct MessageSelectView: View {
    let original: UIImage
    /// Called with the selected rectangle, normalised 0...1 in the
    /// full image, origin top-left as the user sees it.
    let onConfirm: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var isDragging = false

    private var aspect: CGFloat {
        guard original.size.width > 0 else { return 1 }
        return original.size.height / original.size.width
    }

    private func displaySize(in geo: GeometryProxy) -> CGSize {
        var width = geo.size.width
        var height = width * aspect
        let maxHeight = geo.size.height * 0.65
        if height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        return CGSize(width: width, height: height)
    }

    private func dragRect(in size: CGSize) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)
        guard w > 4, h > 4 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func normalisedRect(in size: CGSize) -> CGRect? {
        guard let rect = dragRect(in: size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: rect.minX / size.width,
                      y: rect.minY / size.height,
                      width: rect.width / size.width,
                      height: rect.height / size.height)
    }

    var body: some View {
        GeometryReader { geo in
            let size = displaySize(in: geo)
            VStack(spacing: 16) {
                Text("Drag your finger around ONE message. Only that message will be read — nothing else on the screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                    if let rect = dragRect(in: size) {
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 3)
                            .background(Color.yellow.opacity(0.15))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if !isDragging {
                                dragStart = value.location
                                isDragging = true
                            }
                            dragCurrent = value.location
                        }
                        .onEnded { value in
                            dragCurrent = value.location
                            isDragging = false
                        }
                )
                VStack(spacing: 10) {
                    if let rect = normalisedRect(in: size) {
                        Text("Selected: \(Int(rect.width * 100))% wide × \(Int(rect.height * 100))% tall. That message only will be read.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No message selected yet — drag a box around a message above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Generate replies for this message") {
                        if let rect = normalisedRect(in: size) {
                            onConfirm(rect)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(normalisedRect(in: size) == nil)
                    Button("Clear selection") {
                        dragStart = nil
                        dragCurrent = nil
                        isDragging = false
                    }
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 8)
        }
        .navigationTitle("Select a message 📸")
    }
}
