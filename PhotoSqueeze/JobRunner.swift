import AVFoundation
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 処理する1件（写真アプリの写真・動画、または「ファイル」アプリのファイル）
enum JobItem {
    case asset(PHAsset)
    case file(URL)

    var id: String {
        switch self {
        case .asset(let asset): asset.localIdentifier
        case .file(let url): url.path
        }
    }
}

struct JobResult: Identifiable, Codable {
    enum Status: Codable {
        case saved
        case skipped(String)
        case failed(String)
    }

    /// 元の写真の localIdentifier（「ファイル」アプリの場合はファイルの場所）
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

/// 途中で止まった処理（アプリを閉じても残るように保存する）
struct PendingJob: Codable {
    var settings: JobSettings
    /// まだ処理していないもの（写真アプリは localIdentifier、「ファイル」アプリはファイル名。処理する順）
    var remainingIDs: [String]
    /// ここまでの結果
    var results: [JobResult]
    var deletedIDs: [String]
    var total: Int
    var savedAt: Date
    /// 「ファイル」アプリのフォルダー（写真アプリの処理では nil）
    var folderBookmark: Data?

    var isFiles: Bool { folderBookmark != nil }
    var isVideo: Bool { settings.mode == .video }
    var unit: String { isVideo ? "本" : "枚" }
}

/// 途中経過の保存先（この iPhone の中だけに保存される）
enum PendingJobStore {
    private static let key = "PhotoSqueeze.pendingJob"

    static func load() -> PendingJob? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingJob.self, from: data)
    }

    static func save(_ job: PendingJob) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 選択した写真・動画を1件ずつ処理し、結果と削除対象を管理する
/// 1件終わるごとに途中経過を保存するので、中断しても続きから再開できる
@MainActor
@Observable
final class JobRunner: Identifiable {
    let id = UUID()
    let settings: JobSettings
    let total: Int
    /// まだ処理していないもの（先頭から順に処理する）
    private var pending: [JobItem]
    /// 「ファイル」アプリのフォルダー（処理中は読み書きの権利を持ち続ける）
    @ObservationIgnored private let folder: FolderAccess?

    private(set) var results: [JobResult]
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
    private(set) var deletedIDs: Set<String>
    /// ゴミ箱に移せなかったため、完全に削除してよいか確認が必要なファイル
    var needsPermanentDelete: [String] = []
    var message: String?

    init(items: [JobItem], settings: JobSettings, folder: FolderAccess? = nil) {
        self.pending = items
        self.settings = settings
        self.folder = folder
        self.total = items.count
        self.results = []
        self.deletedIDs = []
    }

    /// 保存しておいた途中経過から再開する
    init(resuming job: PendingJob, items: [JobItem], folder: FolderAccess? = nil) {
        self.pending = items
        self.settings = job.settings
        self.folder = folder
        self.total = job.total
        self.results = job.results
        self.deletedIDs = Set(job.deletedIDs)
        self.deleteSelection = Set(job.results.filter(\.isSaved).map(\.id)).subtracting(job.deletedIDs)
    }

    var savedResults: [JobResult] { results.filter(\.isSaved) }
    var deletableResults: [JobResult] { savedResults.filter { !deletedIDs.contains($0.id) } }
    var savedOriginalBytes: Int { savedResults.reduce(0) { $0 + $1.originalBytes } }
    var savedNewBytes: Int { savedResults.reduce(0) { $0 + $1.newBytes } }
    /// 残りの件数（中断・中止したときに続きから再開できる分）
    var remainingCount: Int { pending.count }
    /// 「ファイル」アプリのファイルを処理しているか
    var isFiles: Bool { folder != nil }

    private var isVideo: Bool { settings.mode == .video }
    private var unit: String { isVideo ? "本" : "枚" }
    private var noun: String { isVideo ? "動画" : "写真" }

    /// 今の1件が終わったところで止める（残りは続きから再開できる）
    func cancel() { isCancelled = true }

    func start() {
        guard !isRunning, !pending.isEmpty else { return }
        isCancelled = false
        wasInterrupted = false
        runTask = Task { await run() }
    }

    /// 中断・中止したところから続きを再開する
    func resume() { start() }

    /// 残りを処理せずに終える（途中経過の保存も消す）
    func discardRemaining() {
        pending = []
        PendingJobStore.clear()
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
        defer {
            isRunning = false
            currentFilename = ""
            runTask = nil
        }
        persist()

        // 写真はアプリを離れても続ける。動画はアプリを開いたまま処理する
        if !isVideo {
            background.begin(
                title: settings.mode == .compress ? "写真を圧縮中" : "写真を変換中",
                subtitle: "\(results.count) / \(total) \(unit)",
                total: total
            ) { [weak self] in
                // 画面上部から中止された、または iOS に止められた
                self?.isCancelled = true
            }
            background.update(done: results.count, subtitle: "\(results.count) / \(total) \(unit)")
            backgroundMode = background.mode
        }

        while let item = pending.first {
            if isCancelled || Task.isCancelled { break }
            // nil は「アプリを離れたため中断」。その1件は残りに戻して、次回やり直す
            let processed: JobResult?
            if isVideo {
                processed = await processVideo(item)
            } else {
                processed = await processPhoto(item)
            }
            guard let result = processed else { break }
            results.append(result)
            pending.removeFirst()
            if result.isSaved { deleteSelection.insert(result.id) }
            persist()
            if !isVideo {
                background.update(done: results.count, subtitle: "\(results.count) / \(total) \(unit)")
            }
        }

        if !isVideo {
            background.end(success: pending.isEmpty)
            backgroundMode = .none
        }
        if wasInterrupted {
            message = "アプリを離れたため、動画の圧縮を中断しました（元の動画はそのままです）。「続きから再開」で、中断した動画からやり直せます。"
        }
    }

    /// 途中経過を保存する。すべて終わったら消す
    private func persist() {
        guard !pending.isEmpty else {
            PendingJobStore.clear()
            return
        }
        let remaining = pending.map { item -> String in
            switch item {
            case .asset(let asset): asset.localIdentifier
            case .file(let url): url.lastPathComponent
            }
        }
        PendingJobStore.save(PendingJob(
            settings: settings,
            remainingIDs: remaining,
            results: results,
            deletedIDs: Array(deletedIDs),
            total: total,
            savedAt: Date(),
            folderBookmark: folder?.bookmark
        ))
    }

    // MARK: - 写真

    private func processPhoto(_ item: JobItem) async -> JobResult? {
        let id = item.id
        var filename = ""
        var originalBytes = 0
        do {
            let data: Data
            let type: UTType?
            switch item {
            case .asset(let asset):
                let source = try await ImageProcessor.loadSource(for: asset)
                data = source.data
                type = source.type
                filename = source.filename
            case .file(let url):
                data = try await Task.detached(priority: .userInitiated) {
                    try FileProcessor.readData(url)
                }.value
                type = UTType(filenameExtension: url.pathExtension)
                filename = url.lastPathComponent
            }
            originalBytes = data.count
            currentFilename = filename

            if settings.mode == .convert, type == settings.format.type {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: 0,
                                 status: .skipped("すでに\(settings.format.rawValue)形式です"))
            }

            let settings = self.settings
            let encoded = try await Task.detached(priority: .userInitiated) {
                try ImageProcessor.encode(data, settings: settings)
            }.value

            if settings.mode == .compress, encoded.count >= originalBytes {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: encoded.count,
                                 status: .skipped("これ以上小さくなりません"))
            }

            let savedName: String
            switch item {
            case .asset(let asset):
                savedName = ImageProcessor.outputFilename(for: filename, format: settings.format)
                try await ImageProcessor.save(encoded, filename: savedName, copying: asset)
            case .file(let url):
                // 同じフォルダーに別名で保存（圧縮は「_圧縮」付き、変換は拡張子だけ変える）
                let output = FileProcessor.outputURL(
                    for: url,
                    suffix: settings.mode == .compress ? "_圧縮" : "",
                    fileExtension: settings.format.fileExtension
                )
                try await Task.detached(priority: .userInitiated) {
                    try FileProcessor.write(encoded, to: output, copyingDatesFrom: url)
                }.value
                savedName = output.lastPathComponent
            }
            return JobResult(id: id, filename: savedName, originalBytes: originalBytes, newBytes: encoded.count,
                             status: .saved)
        } catch {
            return JobResult(id: id, filename: filename.isEmpty ? "（不明）" : filename,
                             originalBytes: originalBytes, newBytes: 0,
                             status: .failed(error.localizedDescription))
        }
    }

    // MARK: - 動画

    /// 動画を1本処理する。アプリを離れて中断した場合は nil（何も保存していない）
    private func processVideo(_ item: JobItem) async -> JobResult? {
        let id = item.id
        var filename = ""
        var originalBytes = 0
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let avAsset: AVAsset
            switch item {
            case .asset(let asset):
                let source = try await VideoProcessor.loadSource(for: asset)
                avAsset = source.avAsset
                filename = source.filename
                originalBytes = source.originalBytes
            case .file(let url):
                try await Task.detached(priority: .userInitiated) {
                    try FileProcessor.ensureDownloaded(url)
                }.value
                avAsset = AVURLAsset(url: url)
                filename = url.lastPathComponent
                originalBytes = FileProcessor.fileSize(url)
            }
            currentFilename = filename
            currentProgress = 0

            try await VideoProcessor.compress(avAsset, to: tempURL, preset: settings.videoPreset) { value in
                Task { @MainActor [weak self] in self?.currentProgress = value }
            }
            if wasInterrupted || Task.isCancelled { return nil }

            let newBytes = FileProcessor.fileSize(tempURL)
            if originalBytes > 0, newBytes >= originalBytes {
                return JobResult(id: id, filename: filename, originalBytes: originalBytes, newBytes: newBytes,
                                 status: .skipped("これ以上小さくなりません"))
            }

            let savedName: String
            switch item {
            case .asset(let asset):
                savedName = VideoProcessor.outputFilename(for: filename)
                try await VideoProcessor.save(fileURL: tempURL, filename: savedName, copying: asset)
            case .file(let url):
                let output = FileProcessor.outputURL(for: url, suffix: "_圧縮", fileExtension: "mov")
                try await Task.detached(priority: .userInitiated) {
                    try FileProcessor.copy(tempURL, to: output, copyingDatesFrom: url)
                }.value
                savedName = output.lastPathComponent
            }
            return JobResult(id: id, filename: savedName, originalBytes: originalBytes, newBytes: newBytes,
                             status: .saved)
        } catch {
            if wasInterrupted || error is CancellationError { return nil }
            return JobResult(id: id, filename: filename.isEmpty ? "（不明）" : filename,
                             originalBytes: originalBytes, newBytes: 0,
                             status: .failed(error.localizedDescription))
        }
    }

    // MARK: - 元の削除

    func toggleDelete(_ result: JobResult) {
        if deleteSelection.contains(result.id) { deleteSelection.remove(result.id) } else { deleteSelection.insert(result.id) }
    }

    func deleteOriginals() async {
        let ids = Array(deleteSelection.subtracting(deletedIDs))
        guard !ids.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }

        if isFiles {
            // 「ファイル」アプリ：まず「最近削除した項目」へ移す
            let urls = ids.map { URL(fileURLWithPath: $0) }
            let failed = await Task.detached(priority: .userInitiated) {
                FileProcessor.moveToTrash(urls)
            }.value.map(\.path)
            let moved = Set(ids).subtracting(failed)
            markDeleted(moved)
            if failed.isEmpty {
                message = "元の\(noun)を\(moved.count)\(unit)、「ファイル」アプリの「最近削除した項目」に移しました。"
            } else {
                // 保存場所にゴミ箱がない場合は、完全に削除してよいか画面で確認する
                needsPermanentDelete = failed
            }
            return
        }

        do {
            try await ImageProcessor.delete(identifiers: ids)
            markDeleted(Set(ids))
            message = "元の\(noun)を\(ids.count)\(unit)削除しました。「最近削除した項目」から30日以内なら復元できます。"
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

    /// ゴミ箱に移せなかったファイルを、確認のうえで完全に削除する
    func deletePermanently() async {
        let urls = needsPermanentDelete.map { URL(fileURLWithPath: $0) }
        needsPermanentDelete = []
        guard !urls.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let deleted = await Task.detached(priority: .userInitiated) {
            FileProcessor.deletePermanently(urls)
        }.value.map(\.path)
        markDeleted(Set(deleted))
        message = deleted.count == urls.count
            ? "元の\(noun)を\(deleted.count)\(unit)削除しました。"
            : "\(deleted.count)\(unit)削除しました。\(urls.count - deleted.count)\(unit)は削除できませんでした。"
    }

    func cancelPermanentDelete() {
        needsPermanentDelete = []
        message = "ゴミ箱に移せなかった\(noun)は、削除せずに残しました。"
    }

    private func markDeleted(_ ids: Set<String>) {
        deletedIDs.formUnion(ids)
        deleteSelection.subtract(ids)
        persist()
    }
}

extension Int {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
