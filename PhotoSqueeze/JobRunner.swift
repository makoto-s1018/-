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

    func cancel() { isCancelled = true }

    func run() async {
        isRunning = true
        defer { isRunning = false; currentFilename = "" }

        for asset in assets {
            if isCancelled { break }
            results.append(await process(asset))
        }
        // 保存できた写真は、最初は削除対象として選択しておく（実行するかはユーザーが決める）
        deleteSelection = Set(savedResults.map(\.id))
    }

    private func process(_ asset: PHAsset) async -> JobResult {
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
