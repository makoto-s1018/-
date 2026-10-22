import Foundation

/// 「ファイル」アプリのファイルの読み書き・削除
enum FileProcessor {
    /// ファイルを読む（iCloud Drive 上にしかない場合はダウンロードしてから読む）
    static func readData(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ProcessingError.noData)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// iCloud Drive 上にしかない場合は、端末にダウンロードしておく（動画用）
    static func ensureDownloaded(_ url: URL) throws {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { _ in }
        if let coordinationError { throw coordinationError }
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// 元のファイルと同じフォルダーに、重ならない名前を作る（例：IMG_1234_圧縮.jpg、IMG_1234_圧縮2.jpg）
    static func outputURL(for original: URL, suffix: String, fileExtension: String) -> URL {
        let folder = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)\(suffix).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)\(suffix)\(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }

    /// 書き出して、作成日・変更日を元のファイルと同じにする（「ファイル」アプリでの並び順を保つため）
    static func write(_ data: Data, to url: URL, copyingDatesFrom original: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        copyDates(from: original, to: url)
    }

    /// 一時ファイルを保存先にコピーする（動画用）
    static func copy(_ temporary: URL, to url: URL, copyingDatesFrom original: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do { try FileManager.default.copyItem(at: temporary, to: writeURL) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        copyDates(from: original, to: url)
    }

    private static func copyDates(from original: URL, to url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: original.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        if let created = attributes[.creationDate] { dates[.creationDate] = created }
        if let modified = attributes[.modificationDate] { dates[.modificationDate] = modified }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: url.path)
    }

    /// 削除の結果
    struct DeleteOutcome: Sendable {
        /// 削除できた（またはすでに無かった）ファイル
        var done: [URL] = []
        /// 削除できなかったファイル
        var failed: [URL] = []
        /// 最後に起きたエラーの説明（原因の確認用）
        var lastError: String?
    }

    /// 「最近削除した項目」へ移す（保存場所によってはゴミ箱がなく、移せないことがある）
    static func moveToTrash(_ urls: [URL]) -> DeleteOutcome {
        delete(urls) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    /// 完全に削除する（元に戻せない）
    static func deletePermanently(_ urls: [URL]) -> DeleteOutcome {
        delete(urls) { try FileManager.default.removeItem(at: $0) }
    }

    /// iCloud Drive などの「ファイル」アプリの保存場所では、ほかのアプリ（ファイルアプリ本体など）と
    /// 取り合いにならないよう、削除も NSFileCoordinator を通して行う必要がある
    private static func delete(_ urls: [URL], using operation: (URL) throws -> Void) -> DeleteOutcome {
        var outcome = DeleteOutcome()
        for url in urls {
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                do { try operation(target) } catch { operationError = error }
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                outcome.done.append(url)
            } else {
                outcome.failed.append(url)
                outcome.lastError = (operationError ?? coordinationError)?.localizedDescription ?? "原因不明"
            }
        }
        return outcome
    }
}
