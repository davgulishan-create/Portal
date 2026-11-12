import Photos
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []

    let imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var observing = false

    var hasAccess: Bool { status == .authorized || status == .limited }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess {
            if !observing { PHPhotoLibrary.shared().register(self); observing = true }
            reload()
        }
    }

    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        fetchResult = result
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let fetchResult, changeInstance.changeDetails(for: fetchResult) != nil else { return }
            reload()
        }
    }

    // MARK: - Export

    struct ExportError: LocalizedError {
        var errorDescription: String? { "Couldn't read the photo's data." }
    }

    /// Original bytes (HEIC/JPEG/PNG…) plus a filename whose extension matches the bytes.
    func exportOriginal(_ asset: PHAsset) async throws -> (name: String, data: Data) {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .photo } ?? resources.first
        let originalName = resource?.originalFilename ?? "Photo.jpg"

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // pull from iCloud if needed
        options.deliveryMode = .highQualityFormat // → handler is called exactly once
        options.version = .current              // include edits

        let (data, uti): (Data, String?) = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                if let data { cont.resume(returning: (data, uti)) } else { cont.resume(throwing: ExportError()) }
            }
        }

        // Edited HEICs come back as JPEG, so fix the extension to match the actual data.
        var name = originalName
        if let uti, let actual = UTType(uti), let ext = actual.preferredFilenameExtension,
           UTType(filenameExtension: (name as NSString).pathExtension) != actual {
            name = ((name as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? name
        }
        return (name, data)
    }
}
