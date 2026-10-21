import SwiftUI

/// 処理の進捗と結果、元写真の削除
struct ResultView: View {
    @Bindable var runner: JobRunner
    let onClose: () -> Void

    private var isVideo: Bool { runner.settings.mode == .video }
    private var noun: String { isVideo ? "動画" : "写真" }
    private var unit: String { isVideo ? "本" : "枚" }

    var body: some View {
        NavigationStack {
            List {
                if runner.isRunning {
                    progressSection
                } else {
                    summarySection
                    if !runner.savedResults.isEmpty { deleteSection }
                }
                resultsSection
            }
            .navigationTitle(runner.isRunning ? "処理中…" : "完了")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        Button("中止", role: .destructive) { runner.cancel() }
                            .disabled(runner.isCancelled)
                    } else {
                        Button("閉じる") { onClose() }
                            .disabled(runner.isDeleting)
                    }
                }
            }
            .interactiveDismissDisabled()
            // 大量処理の途中で画面がロックされて止まらないようにする
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .alert("お知らせ", isPresented: Binding(
                get: { runner.message != nil },
                set: { if !$0 { runner.message = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(runner.message ?? "")
            }
        }
    }

    // MARK: - 進捗

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(runner.results.count), total: Double(max(runner.total, 1)))
                Text("\(runner.results.count) / \(runner.total) \(unit)")
                    .font(.headline)
                if isVideo, !runner.currentFilename.isEmpty {
                    ProgressView(value: runner.currentProgress) {
                        Text("この動画：\(Int(runner.currentProgress * 100))%")
                            .font(.caption)
                    }
                    .tint(.green)
                }
                if !runner.currentFilename.isEmpty {
                    Text(runner.currentFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(isVideo
                     ? "処理中はアプリを開いたままにしてください（ほかのアプリに切り替えると失敗します）。動画は1本あたり数十秒〜数分かかります。"
                     : "処理中はアプリを閉じないでください。iCloud上の写真はダウンロードに時間がかかることがあります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 集計

    private var summarySection: some View {
        let saved = runner.savedResults.count
        let skipped = runner.results.filter { if case .skipped = $0.status { true } else { false } }.count
        let failed = runner.results.filter { if case .failed = $0.status { true } else { false } }.count
        let before = runner.savedOriginalBytes
        let after = runner.savedNewBytes
        let percent = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0

        return Section {
            LabeledContent("保存した\(noun)", value: "\(saved)\(unit)")
            if skipped > 0 { LabeledContent("スキップ", value: "\(skipped)\(unit)") }
            if failed > 0 { LabeledContent("失敗", value: "\(failed)\(unit)") }
            if runner.isCancelled {
                LabeledContent("中止", value: "\(runner.total - runner.results.count)\(unit)は未処理")
            }
            if saved > 0 {
                LabeledContent("サイズ", value: "\(before.byteString) → \(after.byteString)")
                if runner.settings.mode.shrinks {
                    LabeledContent("削減", value: "\((before - after).byteString)（\(percent)%）")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text(runner.settings.mode.title + "の結果")
        } footer: {
            if saved > 0 {
                Text("新しい\(noun)は元の\(noun)と同じ撮影日で、写真アプリに保存されています。")
            }
        }
    }

    // MARK: - 削除

    private var deleteSection: some View {
        let targets = runner.deletableResults
        let selectedCount = targets.filter { runner.deleteSelection.contains($0.id) }.count

        return Section {
            if targets.isEmpty {
                Label("選択した元の\(noun)は削除済みです", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("すべて選択") { runner.deleteSelection.formUnion(targets.map(\.id)) }
                    Spacer()
                    Button("すべて解除") { runner.deleteSelection.subtract(targets.map(\.id)) }
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    Task { await runner.deleteOriginals() }
                } label: {
                    HStack {
                        if runner.isDeleting { ProgressView() }
                        Label("選択した元の\(noun)を削除（\(selectedCount)\(unit)）", systemImage: "trash")
                    }
                }
                .disabled(selectedCount == 0 || runner.isDeleting)
            }
        } header: {
            Text("元の\(noun)を削除しますか？")
        } footer: {
            Text("削除しない場合はそのまま「閉じる」を押してください。下の一覧で削除する\(noun)を個別に選べます。削除した\(noun)は「最近削除した項目」に30日間残ります。")
        }
    }

    // MARK: - 一覧

    private var resultsSection: some View {
        Section("詳細") {
            ForEach(runner.results.reversed()) { result in
                ResultRow(
                    result: result,
                    noun: noun,
                    showsDeleteToggle: !runner.isRunning && result.isSaved,
                    isDeleted: runner.deletedIDs.contains(result.id),
                    isMarkedForDelete: runner.deleteSelection.contains(result.id),
                    onToggle: { runner.toggleDelete(result) }
                )
            }
        }
    }
}

private struct ResultRow: View {
    let result: JobResult
    let noun: String
    let showsDeleteToggle: Bool
    let isDeleted: Bool
    let isMarkedForDelete: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if showsDeleteToggle {
                if isDeleted {
                    Image(systemName: "trash.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                } else {
                    Button(action: onToggle) {
                        Image(systemName: isMarkedForDelete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isMarkedForDelete ? Color.red : Color.secondary)
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isMarkedForDelete ? "元の\(noun)を削除する" : "元の\(noun)を残す")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename).font(.subheadline)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch result.status {
        case .saved:
            Text("\(result.originalBytes.byteString) → \(result.newBytes.byteString)" + (isDeleted ? "　元の\(noun)は削除済み" : ""))
        case .skipped(let reason):
            Text("スキップ：\(reason)")
        case .failed(let reason):
            Text("失敗：\(reason)").foregroundStyle(.red)
        }
    }
}
