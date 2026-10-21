import Photos
import SwiftUI

/// 写真のまとめ方
enum Grouping: String, CaseIterable, Identifiable {
    case day = "日ごと"
    case month = "月ごと"
    case year = "年ごと"

    var id: Self { self }
}

/// 一覧に出すもの
enum MediaKind: String, CaseIterable, Identifiable {
    case photo = "写真"
    case video = "動画"

    var id: Self { self }
    var assetType: PHAssetMediaType { self == .photo ? .image : .video }
    /// 数える単位
    var unit: String { self == .photo ? "枚" : "本" }
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

    var mediaKind: MediaKind = .photo {
        didSet {
            guard mediaKind != oldValue else { return }
            selection = []
            collapsed = []
            load()
        }
    }

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
        let result = PHAsset.fetchAssets(with: mediaKind.assetType, options: options)
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

extension PHImageManager {
    /// 写真の縮小画像を取り出す。結果が複数回届いても、最終的な画像を1回だけ返す
    func image(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
