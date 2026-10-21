import ImageIO
import Photos
import UniformTypeIdentifiers

enum JobMode: String, Identifiable {
    case compress
    case convert

    var id: Self { self }
    var title: String { self == .compress ? "圧縮" : "JPEG / PNG 変換" }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case png = "PNG"

    var id: Self { self }

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        }
    }

    var isLossy: Bool { self != .png }
}

struct JobSettings {
    var mode: JobMode
    var format: OutputFormat
    /// 0.0〜1.0（JPEG / HEIC のみ）
    var quality: Double
    /// 長辺の最大ピクセル数。nil なら元のサイズ
    var maxDimension: Int?
}

enum ProcessingError: LocalizedError {
    case noData
    case decodeFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noData: "写真データを取得できませんでした"
        case .decodeFailed: "画像を読み込めませんでした"
        case .encodeFailed: "画像を書き出せませんでした"
        }
    }
}

/// 写真の読み出し・再エンコード・保存を行う
enum ImageProcessor {
    struct Source {
        let data: Data
        let type: UTType?
        let filename: String
    }

    /// 写真ライブラリから元データを取り出す（iCloud上の写真はダウンロードする）
    static func loadSource(for asset: PHAsset) async throws -> Source {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let (data, uti): (Data, String?) = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                guard !resumed else { return }
                resumed = true
                if let data {
                    continuation.resume(returning: (data, uti))
                } else {
                    let error = info?[PHImageErrorKey] as? Error ?? ProcessingError.noData
                    continuation.resume(throwing: error)
                }
            }
        }

        let resource = PHAssetResource.assetResources(for: asset).first { $0.type == .photo }
        let filename = resource?.originalFilename ?? "IMG_\(Int(Date().timeIntervalSince1970))"
        return Source(data: data, type: uti.flatMap { UTType($0) }, filename: filename)
    }

    /// 向きを正しく回転したうえで縮小・再エンコードする。撮影情報（Exif・GPS）は引き継ぐ
    static func encode(_ data: Data, settings: JobSettings) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProcessingError.decodeFailed
        }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = metadata[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = metadata[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)

        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if longest > 0 {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = min(longest, settings.maxDimension ?? longest)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ProcessingError.decodeFailed
        }

        // 画素はすでに正しい向きに回転済みなので、向き情報は「標準」に戻す
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata.removeValue(forKey: kCGImagePropertyPixelWidth)
        metadata.removeValue(forKey: kCGImagePropertyPixelHeight)
        if settings.format.isLossy {
            metadata[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, settings.format.type.identifier as CFString, 1, nil
        ) else {
            throw ProcessingError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.encodeFailed
        }
        return output as Data
    }

    /// 新しい写真として保存する。撮影日・位置情報・お気に入りは元の写真と同じにする
    static func save(_ data: Data, filename: String, copying original: PHAsset) async throws {
        let creationDate = original.creationDate
        let location = original.location
        let isFavorite = original.isFavorite

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .photo, data: data, options: options)
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = isFavorite
        }
    }

    /// 元の写真を削除する（iOS の確認ダイアログが表示され、「最近削除した項目」に移動する）
    static func delete(identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    static func outputFilename(for original: String, format: OutputFormat) -> String {
        let base = (original as NSString).deletingPathExtension
        return "\(base).\(format.fileExtension)"
    }
}
