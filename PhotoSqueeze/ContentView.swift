import Photos
import SwiftUI

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    @State private var settingsMode: JobMode?
    @State private var runner: JobRunner?
    @State private var pendingSettings: JobSettings?
    @State private var showsDuplicates = false

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
        .task { library.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.load() }
        }
        .sheet(item: $settingsMode, onDismiss: startPendingJob) { mode in
            JobSettingsView(mode: mode, count: library.selection.count) { settings in
                pendingSettings = settings
                settingsMode = nil
            }
        }
        .fullScreenCover(item: $runner) { job in
            ResultView(runner: job) {
                runner = nil
                library.clearSelection()
                library.load()
            }
        }
        .fullScreenCover(isPresented: $showsDuplicates) {
            DuplicateView(allAssets: library.assets, selectedAssets: library.selectedAssets) {
                showsDuplicates = false
                library.load()
            }
        }
    }

    /// 設定シートが閉じきってから処理画面を出す（同時に出すと表示に失敗するため）
    private func startPendingJob() {
        guard let settings = pendingSettings else { return }
        pendingSettings = nil
        let job = JobRunner(assets: library.selectedAssets, settings: settings)
        runner = job
        Task { await job.run() }
    }

    // MARK: - 一覧

    private var photoList: some View {
        @Bindable var library = library
        return ScrollView {
            Picker("まとめ方", selection: $library.grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)

            if library.assets.isEmpty {
                ContentUnavailableView("写真がありません", systemImage: "photo.on.rectangle")
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
                Button {
                    showsDuplicates = true
                } label: {
                    Label("重複を探す", systemImage: "square.on.square")
                        .labelStyle(.titleAndIcon)
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
            Text(library.selection.isEmpty ? "写真をタップ、または日付の「選択」でまとめて選べます" : "\(library.selection.count)枚を選択中")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
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
            .controlSize(.large)
            .disabled(library.selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
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
                    Text("\(group.assets.count)枚")
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
