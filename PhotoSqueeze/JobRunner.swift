import Photos
import SwiftUI

struct JobResult: Identifiable {
    enum Status {
        case saved
        case skipped(String)
        case failed(String)
    }

    /// 元の写真の localIdentifier
    let id: String
    let filename: String
    let originalBytes: Int
    let newBytes: Int
    let status: Status

    var isSaved: Bool {
        if case .saved = status { return true }
        return false
    }
}

/// 選択した写真を1枚ずつ処理し、結果と削除対象を管理する
@MainActor
@Observable
final class JobRunner: Identifiable {
    let id = UUID()
    let settings: JobSettings
    let total: Int
    private let assets: [PHAsset]

    private(set) var results: [JobResult] = []
    private(set) var isRunning = false
    private(set) var isCancelled = false
    private(set) var currentFilename = ""
    /// 処理中の1本（動画）の進み具合 0〜1
    private(set) var currentProgress: Double = 0
    /// 写真の処理をアプリの外でも続けられる状態か
    private(set) var backgroundMode: BackgroundWork.Mode = .none
    /// 動画の処理中にアプリを離れたため中断した
    private(set) var wasInterrupted = false

    @ObservationIgnored private let background = BackgroundWork()
    @ObservationIgnored private var runTask: Task<Void, Never>?

    /// 削除する元写真（保存に成功したものだけが対象）
    var deleteSelection: Set<String> = []
    private(set) var isDeleting = false
    private(set) var deletedIDs: Set<String> = []
    var message: String?

    init(assets: [PHAsset], settings: JobSettings) {
        self.assets = assets
        self.settings = settings
        self.total = assets.count
    }

    var savedResults: [JobResult] { results.filter(\.isSaved) }
    var deletableResults: [JobResult] { savedResults.filter { !deletedIDs.contains($0.id) } }
    var savedOriginalBytes: Int { savedResults.reduce(0) { $0 + $1.originalBytes } }
    var savedNewBytes: Int { savedResults.reduce(0) { $0 + $1.newBytes } }

    private var isVideo: Bool { settings.mode == .video }
    private var unit: String { isVideo ? "本" : "枚" }

    /// 今の1件が終わったところで止める
    func cancel() { isCancelled = true }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    /// アプリがバックグラウンドに移ったときに呼ぶ
    /// 動画は途中で止められると書き出しが失敗するので、ここで安全に中断する（元の動画には手を付けない）
    func appDidEnterBackground() {
        guard isVideo, isRunning, !isCancelled else { return }
        wasInterrupted = true
        isCancelled = true
        runTask?.cancel()
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false; currentFilename = "" }

        // 写真はアプリを離れても続ける。動画はアプリを開いたまま処理する
        if !isVideo {
            background.begin(
                title: settings.mode == .compress ? "写真を圧縮中" : "写真を変換中",
                subtitle: "0 / \(total) \(unit)",
                total: total
            ) { [weak self] in
                // 画面上部から中止された、または iOS に止められた
                self?.isCancelled = true
            }
            backgroundMode = background.mode
        }

        for asset in assets {
            if isCancelled || Task.isCancelled { break }
            results.append(await process(asset))
            if !isVideo {
                background.update(done: results.count, subtitle: "\(results.count) / \(total) \(unit)")
            }
        }

        if !isVideo {
            background.end(success: !isCancelled)
            backgroundMode = .none
        }
        if wasInterrupted {
            message = "アプリを離れたため、動画の圧縮を中断しました。処理中だった動画は保存していません（元の動画はそのままです）。"
        }
        // 保存できたものは、最初は削除対象として選択しておく（実行するかはユーザーが決める）
        deleteSelection = Set(savedResults.map(\.id))
    }

    private func process(_ asset: PHAsset) async -> JobResult {
        if settings.mode == .video { return await processVideo(asset) }
        let id = asset.localIdentifier
        var filename = ""
        var originalBytes = 0
        do {
            let source = try await ImageProcessor.loadSource(for: asset)
            filename = source.filename
            originalBytes = source.data.count
            currentFilename = filename

            if settings.mode == .convert, source.type == settings.format.type {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: 0,
                                 status: .skipped("すでに\(settings.format.rawValue)形式です"))
            }

            let settings = self.settings
            let data = source.data
            let encoded = try await Task.detached(priority: .userInitiated) {
                try ImageProcessor.encode(data, settings: settings)
            }.value

            if settings.mode == .compress, encoded.count >= originalBytes {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: encoded.count,
                                 status: .skipped("これ以上小さくなりません"))
            }

            let newName = ImageProcessor.outputFilename(for: filename, format: settings.format)
            try await ImageProcessor.save(encoded, filename: newName, copying: asset)
            return JobResult(id: id, filename: newName, originalBytes: originalBytes, newBytes: encoded.count,
                             status: .saved)
        } catch {
            return JobResult(id: id, filename: filename.isEmpty ? "（不明）" : filename,
                             originalBytes: originalBytes, newBytes: 0,
                             status: .failed(error.localizedDescription))
        }
    }

    private func processVideo(_ asset: PHAsset) async -> JobResult {
        let id = asset.localIdentifier
        var filename = ""
        var originalBytes = 0
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let source = try await VideoProcessor.loadSource(for: asset)
            filename = source.filename
            originalBytes = source.originalBytes
            currentFilename = filename
            currentProgress = 0

            try await VideoProcessor.compress(source.avAsset, to: tempURL, preset: settings.videoPreset) { value in
                Task { @MainActor [weak self] in self?.currentProgress = value }
            }

            let newBytes = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if originalBytes > 0, newBytes >= originalBytes {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: newBytes,
                                 status: .skipped("これ以上小さくなりません"))
            }

            let newName = VideoProcessor.outputFilename(for: filename)
            try await VideoProcessor.save(fileURL: tempURL, filename: newName, copying: asset)
            return JobResult(id: id, filename: newName, originalBytes: originalBytes, newBytes: newBytes,
                             status: .saved)
        } catch {
            let reason = wasInterrupted || error is CancellationError
                ? "アプリを離れたため中断しました（元の動画はそのままです）"
                : error.localizedDescription
            return JobResult(id: id, filename: filename.isEmpty ? "（不明）" : filename,
                             originalBytes: originalBytes, newBytes: 0,
                             status: .failed(reason))
        }
    }

    func toggleDelete(_ result: JobResult) {
        if deleteSelection.contains(result.id) { deleteSelection.remove(result.id) } else { deleteSelection.insert(result.id) }
    }

    func deleteOriginals() async {
        let ids = Array(deleteSelection.subtracting(deletedIDs))
        guard !ids.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await ImageProcessor.delete(identifiers: ids)
            deletedIDs.formUnion(ids)
            deleteSelection.subtract(ids)
            message = "元の写真を\(ids.count)枚削除しました。「最近削除した項目」から30日以内なら復元できます。"
        } catch {
            // iOS の確認ダイアログでキャンセルした場合もここに来る
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.userCancelled.rawValue {
                message = "削除をキャンセルしました。"
            } else {
                message = "削除できませんでした：\(error.localizedDescription)"
            }
        }
    }
}

extension Int {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
