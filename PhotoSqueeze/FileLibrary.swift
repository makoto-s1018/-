import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 「ファイル」アプリで選んだフォルダーへのアクセス権（持っている間だけ中のファイルを読み書きできる）
final class FolderAccess: @unchecked Sendable {
    let url: URL
    private let isAccessing: Bool

    init(url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing { url.stopAccessingSecurityScopedResource() }
    }

    /// 次回アプリを開いたときにも同じフォルダーを使えるようにするための情報
    var bookmark: Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ bookmark: Data) -> FolderAccess? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        return FolderAccess(url: url)
    }
}

/// フォルダーの中の写真・動画1つ分
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date?
    let size: Int
    let isVideo: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct FileGroup: Identifiable {
    let id: String
    let title: String
    let items: [FileItem]
}

/// 「ファイル」アプリのフォルダーの中身の読み込み・日付グループ化・選択状態を管理する
@MainActor
@Observable
final class FileLibrary {
    private static let bookmarkKey = "PhotoSqueeze.folderBookmark"

    @ObservationIgnored private(set) var folder: FolderAccess?
    private(set) var folderName: String?
    private(set) var items: [FileItem] = []
    private(set) var groups: [FileGroup] = []
    private(set) var isLoading = false
    var selection: Set<String> = []
    var collapsed: Set<String> = []

    private var kind: MediaKind = .photo
    private var grouping: Grouping = .month

    /// 今の種類（写真／動画）のファイル
    var visibleItems: [FileItem] { items.filter { $0.isVideo == (kind == .video) } }
    var selectedItems: [FileItem] { visibleItems.filter { selection.contains($0.id) } }

    /// 前回選んだフォルダーを開き直す
    func restore() {
        guard folder == nil,
              let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let access = FolderAccess.resolve(bookmark) else { return }
        use(access)
    }

    /// 「ファイル」アプリでフォルダーを選んだとき
    func open(_ url: URL) {
        let access = FolderAccess(url: url)
        if let bookmark = access.bookmark {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        use(access)
    }

    private func use(_ access: FolderAccess) {
        folder = access
        folderName = access.url.lastPathComponent
        selection = []
        collapsed = []
        reload()
    }

    /// 写真／動画の切り替え・まとめ方の変更を反映する
    func update(kind: MediaKind, grouping: Grouping) {
        let kindChanged = kind != self.kind
        self.kind = kind
        self.grouping = grouping
        if kindChanged {
            selection = []
            collapsed = []
        }
        regroup()
    }

    func reload() {
        guard let folder else { return }
        isLoading = true
        let url = folder.url
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                Self.scan(url)
            }.value
            items = scanned
            selection.formIntersection(Set(scanned.map(\.id)))
            isLoading = false
            regroup()
        }
    }

    // MARK: - 選択

    func toggle(_ item: FileItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectedCount(in group: FileGroup) -> Int {
        group.items.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    func toggleGroup(_ group: FileGroup) {
        let ids = group.items.map(\.id)
        if selectedCount(in: group) == group.items.count {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func toggleCollapsed(_ group: FileGroup) {
        if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
    }

    func selectAll() { selection = Set(visibleItems.map(\.id)) }
    func clearSelection() { selection = [] }

    // MARK: - グループ化

    private func regroup() {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        var titles: [String: String] = [:]

        for item in visibleItems {
            let key: String
            let title: String
            if let date = item.date {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                switch grouping {
                case .day:
                    key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
                    title = Self.dayFormatter.string(from: date)
                case .month:
                    key = String(format: "%04d-%02d", c.year!, c.month!)
                    title = "\(c.year!)年\(c.month!)月"
                case .year:
                    key = String(format: "%04d", c.year!)
                    title = "\(c.year!)年"
                }
            } else {
                key = "none"
                title = "日付なし"
            }
            if buckets[key] == nil {
                order.append(key)
                titles[key] = title
            }
            buckets[key, default: []].append(item)
        }
        groups = order.map { FileGroup(id: $0, title: titles[$0]!, items: buckets[$0]!) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E)"
        return f
    }()

    // MARK: - フォルダーの読み込み

    /// フォルダー直下の写真・動画を探す（サブフォルダーの中は含めない）。新しい順に並べる
    nonisolated private static func scan(_ folder: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [
            .contentTypeKey, .fileSizeKey, .isRegularFileKey,
            .creationDateKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [FileItem] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType else { continue }
            let isImage = type.conforms(to: .image)
            let isVideo = type.conforms(to: .movie)
            guard isImage || isVideo else { continue }

            // 端末にある写真は撮影日時（Exif）を使う。iCloud上にしかないものはファイルの日付
            let isLocal = values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
            let date = (isImage && isLocal ? exifDate(of: url) : nil)
                ?? values.creationDate ?? values.contentModificationDate
            result.append(FileItem(url: url, date: date, size: values.fileSize ?? 0, isVideo: isVideo))
        }
        return result.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    nonisolated private static func exifDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
