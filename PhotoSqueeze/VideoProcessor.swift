import AVFoundation
import Photos
import VideoToolbox

/// 動画の圧縮プリセット（映像は HEVC で再エンコード、音声はそのまま）
enum VideoPreset: String, CaseIterable, Identifiable {
    case high
    case medium
    case light
    case minimum

    var id: Self { self }

    var title: String {
        switch self {
        case .high: "高画質"
        case .medium: "中画質（おすすめ）"
        case .light: "軽量"
        case .minimum: "最小"
        }
    }

    var usage: String {
        switch self {
        case .high: "フルHD。大きな画面で見る、きれいに残したい動画"
        case .medium: "フルHD。スマホやPCで見るには十分な画質"
        case .light: "HD（720p）。LINE・メールで送る、記録用"
        case .minimum: "SD相当。とにかく容量を減らしたいとき"
        }
    }

    /// 長辺の最大ピクセル数
    var maxDimension: Int {
        switch self {
        case .high, .medium: 1920
        case .light: 1280
        case .minimum: 960
        }
    }

    /// 映像の平均ビットレート（bps）
    var bitRate: Int {
        switch self {
        case .high: 8_000_000
        case .medium: 4_000_000
        case .light: 2_000_000
        case .minimum: 1_000_000
        }
    }

    /// 1分あたりの大きさの目安（MB、音声込み）
    var megabytesPerMinute: Int { bitRate * 60 / 8 / 1_000_000 + 1 }

    var detail: String { "長辺 \(maxDimension)px・\(bitRate / 1_000_000)Mbps・HEVC" }
}

/// 動画の読み出し・再エンコード・保存
enum VideoProcessor {
    struct Source {
        let avAsset: AVAsset
        let filename: String
        /// 元のファイルサイズ（分からない場合は 0）
        let originalBytes: Int
    }

    /// 写真ライブラリから動画を取り出す（iCloud上の動画はダウンロードする）
    static func loadSource(for asset: PHAsset) async throws -> Source {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard !resumed else { return }
                resumed = true
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? ProcessingError.noData)
                }
            }
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .fullSizeVideo } ?? resources.first { $0.type == .video }
        let filename = resource?.originalFilename ?? "VIDEO_\(Int(Date().timeIntervalSince1970)).MOV"

        var bytes = 0
        if let url = (avAsset as? AVURLAsset)?.url,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            bytes = size
        }
        return Source(avAsset: avAsset, filename: filename, originalBytes: bytes)
    }

    /// 動画を縮小・再エンコードして outputURL に書き出す
    /// 向き・撮影情報（日時・位置）は引き継ぐ。HDR（HLG/PQ）の動画は 10bit HDR のまま書き出す
    static func compress(
        _ source: AVAsset,
        to outputURL: URL,
        preset: VideoPreset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let videoTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.decodeFailed
        }
        let audioTrack = try await source.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform, formats) = try await videoTrack.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let duration = try await source.load(.duration).seconds
        let metadata = try await source.load(.metadata)

        // 出力サイズ（回転前の縦横で計算し、偶数にそろえる）
        let longest = max(naturalSize.width, naturalSize.height)
        let scale = min(1, CGFloat(preset.maxDimension) / max(longest, 1))
        let width = max(2, Int((naturalSize.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((naturalSize.height * scale / 2).rounded()) * 2)

        let colors = colorProperties(of: formats.first)
        let isHDR = colors?.isHDR ?? false

        let reader = try AVAssetReader(asset: source)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true

        // 映像
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ProcessingError.decodeFailed }
        reader.add(videoOutput)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitRate,
                AVVideoProfileLevelKey: isHDR
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                    : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ]
        if let colors {
            videoSettings[AVVideoColorPropertiesKey] = colors.settings
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ProcessingError.encodeFailed }
        writer.add(videoInput)

        var pumps = [SamplePump(output: videoOutput, input: videoInput, isVideo: true)]

        // 音声（再エンコードせずにそのままコピー）
        if let audioTrack {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormats.first)
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pumps.append(SamplePump(output: audioOutput, input: audioInput, isVideo: false))
            }
        }

        guard reader.startReading() else { throw reader.error ?? ProcessingError.decodeFailed }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ProcessingError.encodeFailed
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for pump in pumps {
                group.enter()
                pump.start(reader: reader, writer: writer, duration: duration,
                           progress: pump.isVideo ? progress : nil) {
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }

        if reader.status == .failed || writer.status == .failed {
            let error = reader.error ?? writer.error ?? ProcessingError.encodeFailed
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ProcessingError.encodeFailed
        }
        progress(1)
    }

    /// 新しい動画として保存する。撮影日・位置情報・お気に入りは元の動画と同じにする
    static func save(fileURL: URL, filename: String, copying original: PHAsset) async throws {
        let creationDate = original.creationDate
        let location = original.location
        let isFavorite = original.isFavorite

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .video, fileURL: fileURL, options: options)
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = isFavorite
        }
    }

    static func outputFilename(for original: String) -> String {
        "\((original as NSString).deletingPathExtension).MOV"
    }

    // MARK: - 色情報

    private struct ColorInfo {
        let settings: [String: String]
        let isHDR: Bool
    }

    private static func colorProperties(of format: CMFormatDescription?) -> ColorInfo? {
        guard let format,
              let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
              let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
              let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        else { return nil }

        let hdrTransfers = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
        ]
        return ColorInfo(
            settings: [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ],
            isHDR: hdrTransfers.contains(transfer)
        )
    }
}

/// 読み出し側から書き込み側へサンプルを流し込む（映像・音声それぞれ1つずつ）
private final class SamplePump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let isVideo: Bool
    private let queue: DispatchQueue
    private var finished = false
    private var lastReported = -1.0

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, isVideo: Bool) {
        self.output = output
        self.input = input
        self.isVideo = isVideo
        self.queue = DispatchQueue(label: "PhotoSqueeze.pump.\(isVideo ? "video" : "audio")")
    }

    func start(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        duration: Double,
        progress: (@Sendable (Double) -> Void)?,
        done: @escaping @Sendable () -> Void
    ) {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !finished else { return }
            while input.isReadyForMoreMediaData {
                guard reader.status == .reading, writer.status == .writing,
                      let buffer = output.copyNextSampleBuffer() else {
                    finish(writer: writer, done: done)
                    return
                }
                if let progress, duration > 0 {
                    let fraction = CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(min(max(fraction, 0), 1))
                    }
                }
                if !input.append(buffer) {
                    finish(writer: writer, done: done)
                    return
                }
            }
        }
    }

    private func finish(writer: AVAssetWriter, done: @Sendable () -> Void) {
        guard !finished else { return }
        finished = true
        if writer.status == .writing {
            input.markAsFinished()
        }
        done()
    }
}
