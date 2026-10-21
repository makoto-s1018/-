import Photos
import UIKit

struct DuplicateGroup: Identifiable {
    let id = UUID()
    var assets: [PHAsset]
}

/// どこまでを「重複」とみなすか
enum DuplicateStrictness: String, CaseIterable, Identifiable {
    case same = "同じ写真だけ"
    case similar = "似ている写真も"

    var id: Self { self }

    /// 画像ハッシュ（64ビット）の違いが何ビットまでなら同じとみなすか
    var threshold: Int { self == .same ? 3 : 10 }

    var note: String {
        switch self {
        case .same: "同じ写真の保存し直し・圧縮前後の写真・LINEなどで受け取った同じ写真を探します。"
        case .similar: "連写や、同じ場所で続けて撮った写真もまとめて探します。残す写真をよく確認してください。"
        }
    }
}

/// グループの中でどれを残すか（残す1枚以外が削除候補になる）
enum KeepRule: String, CaseIterable, Identifiable {
    case highest = "高画質を残す"
    case lightest = "軽い方を残す"

    var id: Self { self }
}

/// 写真ライブラリから重複・類似写真を探し、削除する
@MainActor
@Observable
final class DuplicateFinder {
    enum Phase { case idle, scanning, grouping, done }

    private(set) var phase: Phase = .idle
    private(set) var scanned = 0
    private(set) var total = 0
    private(set) var groups: [DuplicateGroup] = []
    private(set) var isDeleting = false
    private var cancelled = false

    var deleteSelection: Set<String> = []
    var message: String?
    var keepRule: KeepRule = .highest {
        didSet { applyKeepRule() }
    }

    var deleteCount: Int { deleteSelection.count }

    func cancel() { cancelled = true }

    func scan(_ assets: [PHAsset], strictness: DuplicateStrictness) async {
        phase = .scanning
        cancelled = false
        scanned = 0
        total = assets.count
        groups = []
        deleteSelection = []

        var entries: [PerceptualHash.Entry] = []
        entries.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            if cancelled { break }
            if let image = await Self.smallImage(for: asset), let hash = PerceptualHash.dHash(image) {
                let aspect = Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
                entries.append(.init(index: index, hash: hash, aspect: aspect))
            }
            if index % 20 == 0 || index == assets.count - 1 { scanned = index + 1 }
        }

        phase = .grouping
        let threshold = strictness.threshold
        let hashed = entries
        let found = await Task.detached(priority: .userInitiated) {
            PerceptualHash.group(hashed, threshold: threshold)
        }.value

        groups = found
            .map { DuplicateGroup(assets: $0.map { assets[$0] }) }
            .sorted { ($0.assets.first?.creationDate ?? .distantPast) > ($1.assets.first?.creationDate ?? .distantPast) }
        applyKeepRule()
        phase = .done
    }

    /// 残す写真を先頭に並べ替え、それ以外を削除候補にする
    private func applyKeepRule() {
        let rule = keepRule
        groups = groups.map { group in
            var group = group
            group.assets.sort { Self.keepFirst($0, $1, rule: rule) }
            return group
        }
        deleteSelection = Set(groups.flatMap { $0.assets.dropFirst().map(\.localIdentifier) })
    }

    private static func keepFirst(_ a: PHAsset, _ b: PHAsset, rule: KeepRule) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        let pa = a.pixelWidth * a.pixelHeight
        let pb = b.pixelWidth * b.pixelHeight
        if pa != pb { return rule == .highest ? pa > pb : pa < pb }
        // 同じ大きさなら古い方（最初に保存された方）を残す
        return (a.creationDate ?? .distantFuture) < (b.creationDate ?? .distantFuture)
    }

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if deleteSelection.contains(id) { deleteSelection.remove(id) } else { deleteSelection.insert(id) }
    }

    func isWholeGroupMarked(_ group: DuplicateGroup) -> Bool {
        group.assets.allSatisfy { deleteSelection.contains($0.localIdentifier) }
    }

    func deleteSelected() async {
        let ids = Array(deleteSelection)
        guard !ids.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await ImageProcessor.delete(identifiers: ids)
            let deleted = Set(ids)
            groups = groups.compactMap { group in
                var group = group
                group.assets.removeAll { deleted.contains($0.localIdentifier) }
                return group.assets.count >= 2 ? group : nil
            }
            deleteSelection.subtract(deleted)
            message = "\(ids.count)枚を削除しました。「最近削除した項目」から30日以内なら復元できます。"
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.userCancelled.rawValue {
                message = "削除をキャンセルしました。"
            } else {
                message = "削除できませんでした：\(error.localizedDescription)"
            }
        }
    }

    /// 比較用の小さな画像（端末内のサムネイルを使うのでダウンロードは発生しない）
    private static func smallImage(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// 画像の「見た目」から作る64ビットの指紋（dHash）。大きさや圧縮率が違っても同じ写真ならほぼ同じ値になる
enum PerceptualHash {
    struct Entry: Sendable {
        let index: Int
        let hash: UInt64
        let aspect: Double
    }

    static func dHash(_ image: UIImage) -> UInt64? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // 真っ黒・真っ白など模様のない画像は誤検出のもとになるので対象外
        guard drawn, let maxValue = pixels.max(), let minValue = pixels.min(),
              Int(maxValue) - Int(minValue) >= 8 else { return nil }

        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if pixels[y * width + x] < pixels[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// 指紋が近く、縦横比も同じ写真をまとめる。2枚以上のグループだけを返す（中身は元の配列の番号）
    static func group(_ entries: [Entry], threshold: Int) -> [[Int]] {
        var parent = Array(entries.indices)

        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        for i in entries.indices {
            let a = entries[i]
            for j in (i + 1)..<entries.count {
                let b = entries[j]
                guard (a.hash ^ b.hash).nonzeroBitCount <= threshold,
                      abs(a.aspect - b.aspect) <= a.aspect * 0.03 else { continue }
                let ra = root(i)
                let rb = root(j)
                if ra != rb { parent[rb] = ra }
            }
        }

        var buckets: [Int: [Int]] = [:]
        for i in entries.indices {
            buckets[root(i), default: []].append(entries[i].index)
        }
        return buckets.values.filter { $0.count >= 2 }
    }
}
