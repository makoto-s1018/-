import AVFoundation
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

    /// 似ている写真は、撮影時刻がこの秒数以内のものだけをまとめる（連写・続けて撮った写真）
    var maxTimeGap: TimeInterval? { self == .same ? nil : 10 * 60 }

    var note: String {
        switch self {
        case .same: "同じ写真の保存し直し・圧縮前後の写真・LINEなどで受け取った同じ写真を探します。"
        case .similar: "連写や、同じ場所で続けて撮った写真（撮影時刻が10分以内）もまとめて探します。残す写真をよく確認してください。"
        }
    }

    /// 画面に出す名前（写真・動画で言い方を変える）
    func label(for kind: MediaKind) -> String {
        switch self {
        case .same: "同じ\(kind.rawValue)だけ"
        case .similar: "似ている\(kind.rawValue)も"
        }
    }

    func note(for kind: MediaKind) -> String {
        guard kind == .video else { return note }
        switch self {
        case .same: return "同じ動画の保存し直し・圧縮前後の動画・LINEなどで受け取った同じ動画を探します（最初の場面の見た目と長さで判定）。"
        case .similar: return "同じ場所で続けて撮った、見た目と長さが近い動画（撮影時刻が10分以内）もまとめて探します。残す動画をよく確認してください。"
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
    private var scanTask: Task<[PerceptualHash.Entry], Never>?
    /// 動画のファイルサイズ（同じ解像度の動画で「高画質／軽い方」を決めるのに使う）
    private(set) var videoSizes: [String: Int] = [:]

    var deleteSelection: Set<String> = []
    var message: String?
    var keepRule: KeepRule = .highest {
        didSet { applyKeepRule() }
    }

    var deleteCount: Int { deleteSelection.count }

    func cancel() { scanTask?.cancel() }

    func scan(_ assets: [PHAsset], strictness: DuplicateStrictness) async {
        phase = .scanning
        scanned = 0
        total = assets.count
        groups = []
        deleteSelection = []

        // 画面を止めないよう、写真の読み込みと指紋づくりはバックグラウンドで行う
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await DuplicateFinder.hashAll(assets) { done in
                await MainActor.run { self?.scanned = done }
            }
        }
        scanTask = task
        let entries = await task.value
        scanTask = nil

        phase = .grouping
        let threshold = strictness.threshold
        let maxTimeGap = strictness.maxTimeGap
        let found = await Task.detached(priority: .userInitiated) {
            PerceptualHash.group(entries, threshold: threshold, maxTimeGap: maxTimeGap)
        }.value

        groups = found
            .map { DuplicateGroup(assets: $0.map { assets[$0] }) }
            .sorted { ($0.assets.first?.creationDate ?? .distantPast) > ($1.assets.first?.creationDate ?? .distantPast) }

        // 動画は同じ解像度のこともあるので、ファイルの大きさも調べておく（見つかった組の分だけ）
        var sizes: [String: Int] = [:]
        for asset in groups.flatMap(\.assets) where asset.mediaType == .video {
            sizes[asset.localIdentifier] = await Self.videoFileSize(asset)
        }
        videoSizes = sizes
        applyKeepRule()
        phase = .done
    }

    /// 残す写真を先頭に並べ替え、それ以外を削除候補にする
    private func applyKeepRule() {
        let rule = keepRule
        let sizes = videoSizes
        groups = groups.map { group in
            var group = group
            group.assets.sort { Self.keepFirst($0, $1, rule: rule, sizes: sizes) }
            return group
        }
        deleteSelection = Set(groups.flatMap { $0.assets.dropFirst().map(\.localIdentifier) })
    }

    private static func keepFirst(_ a: PHAsset, _ b: PHAsset, rule: KeepRule, sizes: [String: Int]) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        let pa = a.pixelWidth * a.pixelHeight
        let pb = b.pixelWidth * b.pixelHeight
        if pa != pb { return rule == .highest ? pa > pb : pa < pb }
        // 解像度が同じ動画は、ファイルが大きい方を高画質とみなす
        let sa = sizes[a.localIdentifier] ?? 0
        let sb = sizes[b.localIdentifier] ?? 0
        if sa != sb, sa > 0, sb > 0 { return rule == .highest ? sa > sb : sa < sb }
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
            message = "\(ids.count)件を削除しました。「最近削除した項目」から30日以内なら復元できます。"
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.userCancelled.rawValue {
                message = "削除をキャンセルしました。"
            } else {
                message = "削除できませんでした：\(error.localizedDescription)"
            }
        }
    }

    /// 動画のファイルサイズ（端末にある場合だけ。分からなければ 0）
    private static func videoFileSize(_ asset: PHAsset) async -> Int {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                let url = (avAsset as? AVURLAsset)?.url
                let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                continuation.resume(returning: size)
            }
        }
    }

    /// すべての写真の指紋を作る（中止されたらそこまでの分を返す）
    /// 同期モードで1枚ずつ取り出すので、返事が2回届いて落ちることがない
    nonisolated private static func hashAll(
        _ assets: [PHAsset],
        progress: @escaping @Sendable (Int) async -> Void
    ) async -> [PerceptualHash.Entry] {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        // 端末内の縮小画像だけを使う（iCloudからのダウンロードは発生しない）
        options.isNetworkAccessAllowed = false

        var entries: [PerceptualHash.Entry] = []
        entries.reserveCapacity(assets.count)
        var processed = 0
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { break }
            processed = index + 1
            autoreleasepool {
                var hash: UInt64?
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 64, height: 64),
                    contentMode: .aspectFit,
                    options: options
                ) { image, _ in
                    if hash == nil, let image { hash = PerceptualHash.dHash(image) }
                }
                if let hash {
                    let aspect = Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
                    let date = asset.creationDate?.timeIntervalSince1970
                    // 動画は最初の場面の見た目に加えて、長さも比べる（写真は 0）
                    let duration = asset.mediaType == .video ? asset.duration : 0
                    entries.append(.init(index: index, hash: hash, aspect: aspect, date: date, duration: duration))
                }
            }
            if index % 50 == 0 { await progress(processed) }
        }
        await progress(processed)
        return entries
    }
}

/// 画像の「見た目」から作る64ビットの指紋（dHash）。大きさや圧縮率が違っても同じ写真ならほぼ同じ値になる
enum PerceptualHash {
    struct Entry: Sendable {
        let index: Int
        let hash: UInt64
        let aspect: Double
        let date: TimeInterval?
        /// 動画の長さ（秒）。写真は 0
        let duration: Double
    }

    /// 1組あたりの上限（これを超える分は次の組に回す）
    static let maxGroupSize = 50

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

    /// 指紋が近く、縦横比も同じ写真をまとめる。2枚以上の組だけを返す（中身は元の配列の番号）
    /// 「AとBが似ている・BとCが似ている → A・B・Cを同じ組」という数珠つなぎはせず、
    /// 組の最初の1枚（基準の写真）と似ているものだけを同じ組にする。巨大な組ができるのを防ぐため
    static func group(_ entries: [Entry], threshold: Int, maxTimeGap: TimeInterval?) -> [[Int]] {
        var assigned = [Bool](repeating: false, count: entries.count)
        var result: [[Int]] = []

        for i in entries.indices where !assigned[i] {
            let base = entries[i]
            var members = [base.index]
            var j = i + 1
            while j < entries.count, members.count < maxGroupSize {
                defer { j += 1 }
                guard !assigned[j] else { continue }
                let other = entries[j]
                guard (base.hash ^ other.hash).nonzeroBitCount <= threshold,
                      abs(base.aspect - other.aspect) <= base.aspect * 0.03 else { continue }
                if let maxTimeGap {
                    guard let a = base.date, let b = other.date, abs(a - b) <= maxTimeGap else { continue }
                }
                // 動画は長さがほぼ同じもの（1秒、または長さの2%以内）だけを同じ組にする
                if base.duration > 0 || other.duration > 0 {
                    let tolerance = max(1, base.duration * 0.02)
                    guard abs(base.duration - other.duration) <= tolerance else { continue }
                }
                assigned[j] = true
                members.append(other.index)
            }
            if members.count >= 2 {
                assigned[i] = true
                result.append(members)
            }
        }
        return result
    }
}
