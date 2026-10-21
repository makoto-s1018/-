import Photos
import SwiftUI

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    @State private var settingsMode: JobMode?
    @State private var runner: JobRunner?
    @State private var pendingSettings: JobSettings?
    @State private var showsDuplicates = false
    /// 前回途中で止まった処理
    @State private var pendingJob: PendingJob?

    var body: some View {
        NavigationStack {
            Group {
                if library.hasAccess {
                    photoList
                } else {
                    AccessView()
                }
            }
            .navigationTitle("写真圧縮")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if library.hasAccess { bottomBar }
            }
        }
        .task {
            library.load()
            refreshPendingJob()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.load()
                refreshPendingJob()
            }
            if phase == .background { runner?.appDidEnterBackground() }
        }
        .sheet(item: $settingsMode, onDismiss: startPendingJob) { mode in
            JobSettingsView(
                mode: mode,
                count: library.selection.count,
                videoDuration: library.selectedAssets.reduce(0) { $0 + $1.duration }
            ) { settings in
                pendingSettings = settings
                settingsMode = nil
            }
        }
        .fullScreenCover(item: $runner) { job in
            ResultView(runner: job) {
                runner = nil
                library.clearSelection()
                library.load()
                refreshPendingJob()
            }
        }
        .fullScreenCover(isPresented: $showsDuplicates) {
            DuplicateView(allAssets: library.assets, selectedAssets: library.selectedAssets) {
                showsDuplicates = false
                library.load()
            }
        }
    }

    private func refreshPendingJob() {
        pendingJob = runner == nil ? PendingJobStore.load() : nil
    }

    /// 前回途中で止まった処理を、続きから再開する
    private func resumePendingJob(_ job: PendingJob) {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: job.remainingIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        // 削除済みなどで見つからないものは飛ばし、元の順番で並べる
        let assets = job.remainingIDs.compactMap { byID[$0] }
        pendingJob = nil
        guard !assets.isEmpty else {
            PendingJobStore.clear()
            return
        }
        let resumed = JobRunner(resuming: job, assets: assets)
        runner = resumed
        resumed.start()
    }

    private func discardPendingJob() {
        PendingJobStore.clear()
        pendingJob = nil
    }

    /// 設定シートが閉じきってから処理画面を出す（同時に出すと表示に失敗するため）
    private func startPendingJob() {
        guard let settings = pendingSettings else { return }
        pendingSettings = nil
        let job = JobRunner(assets: library.selectedAssets, settings: settings)
        runner = job
        job.start()
    }

    // MARK: - 一覧

    private var photoList: some View {
        @Bindable var library = library
        return ScrollView {
            if let pendingJob {
                PendingJobBanner(
                    job: pendingJob,
                    onResume: { resumePendingJob(pendingJob) },
                    onDiscard: { discardPendingJob() }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Picker("種類", selection: $library.mediaKind) {
                ForEach(MediaKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind == .photo ? "photo" : "video").tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Picker("まとめ方", selection: $library.grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)

            if library.assets.isEmpty {
                ContentUnavailableView("\(library.mediaKind.rawValue)がありません",
                                       systemImage: library.mediaKind == .photo ? "photo.on.rectangle" : "video.slash")
                    .padding(.top, 80)
            }

            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(library.groups) { group in
                    Section {
                        if !library.collapsed.contains(group.id) {
                            PhotoGrid(assets: group.assets)
                        }
                    } header: {
                        GroupHeader(group: group)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if library.hasAccess {
            ToolbarItem(placement: .topBarLeading) {
                if library.mediaKind == .photo {
                    Button {
                        showsDuplicates = true
                    } label: {
                        Label("重複を探す", systemImage: "square.on.square")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("すべて選択", systemImage: "checkmark.circle") { library.selectAll() }
                    Button("選択を解除", systemImage: "xmark.circle") { library.clearSelection() }
                    if library.status == .limited {
                        Divider()
                        Text("アクセスが「選択した写真」に制限されています。設定アプリで変更できます。")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(library.selection.isEmpty
                 ? "\(library.mediaKind.rawValue)をタップ、または日付の「選択」でまとめて選べます"
                 : "\(library.selection.count)\(library.mediaKind.unit)を選択中")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if library.mediaKind == .video {
                    Button {
                        settingsMode = .video
                    } label: {
                        Label("動画を圧縮", systemImage: "arrow.down.right.and.arrow.up.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        settingsMode = .compress
                    } label: {
                        Label("圧縮", systemImage: "arrow.down.right.and.arrow.up.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        settingsMode = .convert
                    } label: {
                        Label("JPEG / PNG 変換", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(library.selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }
}

// MARK: - 途中で止まった処理のお知らせ

private struct PendingJobBanner: View {
    let job: PendingJob
    let onResume: () -> Void
    let onDiscard: () -> Void
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("前回の「\(job.settings.mode.title)」が途中で止まっています", systemImage: "pause.circle.fill")
                .font(.subheadline.bold())
            Text("\(job.results.count) / \(job.total) \(job.unit)完了・残り \(job.remainingIDs.count) \(job.unit)（\(job.savedAt.formatted(date: .abbreviated, time: .shortened))）")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    onResume()
                } label: {
                    Label("続きから再開", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("やめる", role: .destructive) {
                    confirmsDiscard = true
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("残りの処理をやめますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("残りをやめる", role: .destructive) { onDiscard() }
        } message: {
            Text("ここまでに保存した\(job.isVideo ? "動画" : "写真")はそのまま残ります。")
        }
    }
}

// MARK: - グループ見出し

private struct GroupHeader: View {
    @Environment(PhotoLibrary.self) private var library
    let group: PhotoGroup

    var body: some View {
        let selected = library.selectedCount(in: group)
        let full = selected == group.assets.count
        HStack(spacing: 8) {
            Button {
                library.toggleCollapsed(group)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: library.collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                        .frame(width: 14)
                    Text(group.title).font(.headline)
                    Text("\(group.assets.count)\(library.mediaKind.unit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if selected > 0 && !full {
                Text("\(selected)枚選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                library.toggleGroup(group)
            } label: {
                Label(full ? "解除" : "選択", systemImage: full ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

// MARK: - サムネイル

private struct PhotoGrid: View {
    let assets: [PHAsset]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets, id: \.localIdentifier) { asset in
                ThumbnailCell(asset: asset)
            }
        }
    }
}

private struct ThumbnailCell: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.displayScale) private var displayScale
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        let isSelected = library.selection.contains(asset.localIdentifier)
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if isSelected { Color.black.opacity(0.25) }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Text(Self.durationText(asset.duration))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, isSelected ? Color.accentColor : Color.black.opacity(0.2))
                    .shadow(radius: 1)
                    .padding(4)
            }
            .contentShape(Rectangle())
            .onTapGesture { library.toggle(asset) }
            .task(id: asset.localIdentifier) { image = await loadThumbnail() }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private func loadThumbnail() async -> UIImage? {
        await library.imageManager.image(for: asset, side: 120 * displayScale)
    }
}

// MARK: - 許可画面

private struct AccessView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        ContentUnavailableView {
            Label("写真へのアクセスが必要です", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("写真を日付ごとに表示し、圧縮・変換・削除するために、写真ライブラリへの「フルアクセス」を許可してください。")
        } actions: {
            if library.status == .notDetermined {
                Button("アクセスを許可") {
                    Task { await library.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
