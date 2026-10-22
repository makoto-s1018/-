import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// 「ファイル」アプリのフォルダーの写真・動画一覧
struct FileListView: View {
    @Environment(FileLibrary.self) private var files
    let kind: MediaKind
    @State private var showsFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            folderBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            if files.folderName == nil {
                ContentUnavailableView {
                    Label("フォルダーを選んでください", systemImage: "folder")
                } description: {
                    Text("「ファイル」アプリのフォルダー（iPhone内・iCloud Drive など）を選ぶと、中の\(kind.rawValue)を日付ごとに表示します。圧縮したものは同じフォルダーに「_圧縮」を付けた名前で保存します。")
                } actions: {
                    Button("フォルダーを選ぶ") { showsFolderPicker = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 40)
            } else if files.isLoading {
                ProgressView("読み込み中…")
                    .padding(.top, 60)
            } else if files.visibleItems.isEmpty {
                ContentUnavailableView("このフォルダーに\(kind.rawValue)はありません",
                                       systemImage: kind == .photo ? "photo.on.rectangle" : "video.slash")
                    .padding(.top, 40)
            } else {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(files.groups) { group in
                        Section {
                            if !files.collapsed.contains(group.id) {
                                FileGrid(items: group.items)
                            }
                        } header: {
                            FileGroupHeader(group: group, unit: kind.unit)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                files.open(url)
            }
        }
    }

    private var folderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(files.folderName ?? "フォルダー未選択")
                .font(.subheadline.bold())
                .lineLimit(1)
            Spacer()
            if files.folderName != nil {
                Button {
                    files.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            Button(files.folderName == nil ? "選ぶ" : "変更") { showsFolderPicker = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 見出し

private struct FileGroupHeader: View {
    @Environment(FileLibrary.self) private var files
    let group: FileGroup
    let unit: String

    var body: some View {
        let selected = files.selectedCount(in: group)
        let full = selected == group.items.count
        HStack(spacing: 8) {
            Button {
                files.toggleCollapsed(group)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: files.collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                        .frame(width: 14)
                    Text(group.title).font(.headline)
                    Text("\(group.items.count)\(unit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if selected > 0 && !full {
                Text("\(selected)\(unit)選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                files.toggleGroup(group)
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

private struct FileGrid: View {
    let items: [FileItem]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(items) { item in
                FileCell(item: item)
            }
        }
    }
}

private struct FileCell: View {
    @Environment(FileLibrary.self) private var files
    @Environment(\.displayScale) private var displayScale
    let item: FileItem
    @State private var image: UIImage?

    var body: some View {
        let isSelected = files.selection.contains(item.id)
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .overlay {
                if isSelected { Color.black.opacity(0.25) }
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.size.byteString)
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
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
            .onTapGesture { files.toggle(item) }
            .task(id: item.id) { image = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 120, height: 120),
            scale: displayScale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}
