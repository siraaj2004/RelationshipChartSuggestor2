import Photos
import UIKit

/// Errors for the Recent Chat flow, written for the user — not codes.
enum RecentScreenshotError: Error, LocalizedError {
    case noPermission
    case noScreenshots
    case couldNotLoad
    public var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Photo access is off. Allow photo access in iOS Settings → Relationship AI, then tap again. Only your latest screenshot is read."
        case .noScreenshots:
            return "No screenshot found in your Photos. Take a screenshot of the new chat first, then tap again."
        case .couldNotLoad:
            return "The latest screenshot could not be read. Try the “Choose screenshots” option and pick it manually."
        }
    }
}

struct RecentScreenshot {
    let assetID: String
    let creationDate: Date?
    let image: UIImage
}

/// Reads ONLY the single most recent screenshot from Photos.
///
/// Why this exists: iOS does not let an app watch another app's chats, or
/// take a screenshot of another app by itself. So the honest flow is:
/// you screenshot the new chat yourself, then this app grabs that one
/// latest screenshot — no browsing, no old chat, no re-picking.
///
/// Privacy: the screenshot itself is never uploaded. It is OCR'd on-device
/// by the same Vision pipeline as the other imports, and only the
/// extracted message text can go to the backend (and only with consent).
enum RecentScreenshotImporter {

    static func fetchLatest() async throws -> RecentScreenshot {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                throw RecentScreenshotError.noPermission
            }
        } else if status == .denied || status == .restricted {
            throw RecentScreenshotError.noPermission
        }

        // Prefer the system Screenshots album. Only fall back to the newest
        // image overall on full photo access: with limited access the newest
        // visible photo might be an old, unrelated photo, and importing it
        // as the "recent chat" would be worse than saying none was found.
        let asset = latestScreenshotAsset()
            ?? (status == .authorized ? latestImageAsset() : nil)
        guard let asset else { throw RecentScreenshotError.noScreenshots }
        guard let image = try await loadImage(for: asset) else {
            throw RecentScreenshotError.couldNotLoad
        }
        return RecentScreenshot(assetID: asset.localIdentifier,
                                creationDate: asset.creationDate,
                                image: image)
    }

    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return options
    }

    private static func latestScreenshotAsset() -> PHAsset? {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil)
        guard let album = albums.firstObject else { return nil }
        let assets = PHAsset.fetchAssets(in: album, options: fetchOptions())
        return assets.firstObject
    }

    private static func latestImageAsset() -> PHAsset? {
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions())
        return assets.firstObject
    }

    private static func loadImage(for asset: PHAsset) async throws -> UIImage? {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                guard !resumed else { return }
                resumed = true
                if let data, let image = UIImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
