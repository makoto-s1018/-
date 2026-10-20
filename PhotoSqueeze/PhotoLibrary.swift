import Photos
import SwiftUI

/// 写真のまとめ方
enum Grouping: String, CaseIterable, Identifiable {
    case day = "日ごと"
    case month = "月ごと"
    case year = "年ごと"

    var id: Self { self }
}

struct PhotoGroup: Identifiable {
    let id: String
    let title: String
    let assets: [PHAsset]
}

/// 写真ライブラリの読み込み・日付グループ化・選択状態を管理する
@MainActor
@Observable
final class PhotoLibrary {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: [PHAsset] = []
    private(set) var groups: [PhotoGroup] = []
    var selection: Set<String> = []
    var collapsed: Set<String> = []

    var grouping: Grouping = .month {
        didSet {
            collapsed = []
            regroup()
        }
    }

    let imageManager = PHCachingImageManager()

    var hasAccess: Bool { status == .authorized || status == .limited }

    var selectedAssets: [PHAsset] {
        assets.filter { selection.contains($0.localIdentifier) }
    }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { load() }
    }

    func load() {
        guard hasAccess else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        selection.formIntersection(Set(list.map(\.localIdentifier)))
        regroup()
    }

    // MARK: - 選択

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectedCount(in group: PhotoGroup) -> Int {
        group.assets.reduce(0) { $0 + (selection.contains($1.localIdentifier) ? 1 : 0) }
    }

    func isFullySelected(_ group: PhotoGroup) -> Bool {
        selectedCount(in: group) == group.assets.count
    }

    func toggleGroup(_ group: PhotoGroup) {
        let ids = group.assets.map(\.localIdentifier)
        if isFullySelected(group) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func selectAll() { selection = Set(assets.map(\.localIdentifier)) }
    func clearSelection() { selection = [] }

    func toggleCollapsed(_ group: PhotoGroup) {
        if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
    }

    // MARK: - グループ化

    private func regroup() {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PHAsset]] = [:]
        var titles: [String: String] = [:]

        for asset in assets {
            let key: String
            let title: String
            if let date = asset.creationDate {
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
            buckets[key, default: []].append(asset)
        }
        groups = order.map { PhotoGroup(id: $0, title: titles[$0]!, assets: buckets[$0]!) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E)"
        return f
    }()
}
