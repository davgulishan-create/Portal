import Photos
import UniformTypeIdentifiers

/// Files from the Mac: images/videos go into Photos, everything else into the app's
/// Documents folder (visible in the Files app under "On My iPhone ▸ Portal").
enum IncomingSaver {
    enum Destination { case photos, files }

    static func save(name rawName: String, data: Data) async throws -> Destination {
        let name = FileNames.sanitize(rawName)
        let type = UTType(filenameExtension: (name as NSString).pathExtension)

        if let type, type.conforms(to: .image) || type.conforms(to: .movie),
           await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized {
            let isVideo = type.conforms(to: .movie)
            // Videos must be added from a file URL.
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
            if isVideo { try data.write(to: tempURL) }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                if isVideo {
                    options.shouldMoveFile = true
                    request.addResource(with: .video, fileURL: tempURL, options: options)
                } else {
                    request.addResource(with: .photo, data: data, options: options)
                }
            }
            return .photos
        }

        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        try data.write(to: FileNames.uniqueURL(in: docs, for: name), options: .atomic)
        return .files
    }
}
