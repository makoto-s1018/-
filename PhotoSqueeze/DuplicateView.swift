import Photos
import SwiftUI

/// 重複写真の検索・確認・削除画面
struct DuplicateView: View {
    let allAssets: [PHAsset]
    let selectedAssets: [PHAsset]
    /// 写真・動画のどちらを探すか
    let kind: MediaKind
    let onClose: () -> Void

    @State private var finder = DuplicateFinder()
    @State private var strictness: DuplicateStrictness = .same
    @State private var onlySelected = false

    var body: some View {
        NavigationStack {
            Group {
                switch finder.phase {
                case .idle: startView
                case .scanning, .grouping: scanningView
                case .done: resultView
                }
            }
            .navigationTitle("重複\(kind.rawValue)を探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if finder.phase == .scanning {
                        Button("中止", role: .destructive) { finder.cancel() }
                    } else {
                        Button("閉じる") { onClose() }
                            .disabled(finder.phase == .grouping || finder.isDeleting)
                    }
                }
            }
            .interactiveDismissDisabled()
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .alert("お知らせ", isPresented: Binding(
                get: { finder.message != nil },
                set: { if !$0 { finder.message = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(finder.message ?? "")
            }
        }
    }

    // MARK: - 開始前

    private var startView: some View {
        Form {
            Section {
                Picker("探し方", selection: $strictness) {
                    ForEach(DuplicateStrictness.allCases) { Text($0.label(for: kind)).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("探し方")
            } footer: {
                Text(strictness.note(for: kind))
            }

            Section("探す範囲") {
                Picker("範囲", selection: $onlySelected) {
                    Text("すべての\(kind.rawValue)（\(allAssets.count)\(kind.unit)）").tag(false)
                    Text("選択中の\(kind.rawValue)（\(selectedAssets.count)\(kind.unit)）").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(selectedAssets.count < 2)
            }

            Section {
                Button {
                    let targets = onlySelected ? selectedAssets : allAssets
                    Task { await finder.scan(targets, strictness: strictness) }
                } label: {
                    Label("検索を開始", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
            } footer: {
                Text("見つかった\(kind.rawValue)はすぐには削除しません。確認してから、削除する\(kind.rawValue)を選べます。")
            }
        }
    }

    // MARK: - 検索中

    private var scanningView: some View {
        VStack(spacing: 16) {
            if finder.phase == .grouping {
                ProgressView()
                Text("似ている\(kind.rawValue)をまとめています…")
            } else {
                ProgressView(value: Double(finder.scanned), total: Double(max(finder.total, 1)))
                Text("\(finder.scanned) / \(finder.total) \(kind.unit)を確認中")
                    .font(.headline)
                    .monospacedDigit()
            }
            Text("\(kind.rawValue)が多いと数分かかることがあります。アプリを閉じずにお待ちください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - 結果

    @ViewBuilder
    private var resultView: some View {
        if finder.groups.isEmpty {
            ContentUnavailableView {
                Label("重複は見つかりませんでした", systemImage: "checkmark.seal")
            } description: {
                Text("「似ている\(kind.rawValue)も」で探すと、続けて撮った似た\(kind.rawValue)も見つかります。")
            } actions: {
                Button("条件を変えて探す") { finder = DuplicateFinder() }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    summary
                    ForEach(finder.groups) { group in
                        GroupCard(finder: finder, group: group)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { deleteBar }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(finder.groups.count)組・\(finder.groups.reduce(0) { $0 + $1.assets.count })\(kind.unit)の重複が見つかりました")
                .font(.headline)
            Picker("残す\(kind.rawValue)", selection: $finder.keepRule) {
                ForEach(KeepRule.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("各組で1\(kind.unit)を残し、それ以外を削除候補にしています。\(kind.rawValue)をタップすると「残す／削除」を切り替えられます。お気に入りの\(kind.rawValue)は優先して残します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deleteBar: some View {
        Button(role: .destructive) {
            Task { await finder.deleteSelected() }
        } label: {
            HStack {
                if finder.isDeleting { ProgressView() }
                Label("選択した\(finder.deleteCount)\(kind.unit)を削除", systemImage: "trash")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(finder.deleteCount == 0 || finder.isDeleting)
        .padding()
        .background(.bar)
    }
}

// MARK: - 1組分

private struct GroupCard: View {
    let finder: DuplicateFinder
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let date = group.assets.first?.creationDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.subheadline.bold())
                }
                Text("\(group.assets.count)\(group.assets.first?.mediaType == .video ? "本" : "枚")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if finder.isWholeGroupMarked(group) {
                    Label("すべて削除", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        DuplicateCell(asset: asset,
                                      marked: finder.deleteSelection.contains(asset.localIdentifier),
                                      size: finder.videoSizes[asset.localIdentifier] ?? 0)
                            .onTapGesture { finder.toggle(asset) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DuplicateCell: View {
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    let asset: PHAsset
    let marked: Bool
    /// 動画のファイルサイズ（分からなければ 0）
    let size: Int
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Color(.tertiarySystemBackground)
                .frame(width: 110, height: 110)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if marked {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                    }
                }
                .overlay(alignment: .topLeading) {
                    Text(marked ? "削除" : "残す")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(marked ? Color.red : Color.green, in: Capsule())
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if asset.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                            .padding(4)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(marked ? Color.red : Color.green, lineWidth: 2)
                }
            if asset.mediaType == .video {
                Text(Self.durationText(asset.duration) + (size > 0 ? "・\(size.byteString)" : ""))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(asset.pixelWidth)×\(asset.pixelHeight)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: asset.localIdentifier) { image = await load() }
    }

    private func load() async -> UIImage? {
        await PHImageManager.default().image(for: asset, side: 110 * displayScale)
    }
}
