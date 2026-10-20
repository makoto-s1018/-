import SwiftUI

/// 圧縮 / 変換の設定シート
struct JobSettingsView: View {
    let mode: JobMode
    let count: Int
    let onStart: (JobSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: OutputFormat
    @State private var quality: Double
    @State private var maxDimension: Int

    /// 0 は「元のサイズ」
    private let dimensionChoices = [0, 4032, 3024, 2048, 1600, 1280, 1024]

    init(mode: JobMode, count: Int, onStart: @escaping (JobSettings) -> Void) {
        self.mode = mode
        self.count = count
        self.onStart = onStart
        _format = State(initialValue: .jpeg)
        _quality = State(initialValue: mode == .compress ? 0.7 : 0.9)
        _maxDimension = State(initialValue: mode == .compress ? 2048 : 0)
    }

    private var formatChoices: [OutputFormat] {
        mode == .compress ? [.jpeg, .heic] : [.jpeg, .png]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(mode == .compress ? "保存形式" : "変換先", selection: $format) {
                        ForEach(formatChoices) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(formatNote)
                }

                if format.isLossy {
                    Section("画質 \(Int(quality * 100))%") {
                        Slider(value: $quality, in: 0.3...1.0, step: 0.05) {
                            Text("画質")
                        } minimumValueLabel: {
                            Text("小").font(.caption)
                        } maximumValueLabel: {
                            Text("高").font(.caption)
                        }
                    }
                }

                if mode == .compress {
                    Section {
                        Picker("最大サイズ（長辺）", selection: $maxDimension) {
                            ForEach(dimensionChoices, id: \.self) { value in
                                Text(value == 0 ? "元のサイズ" : "\(value) px").tag(value)
                            }
                        }
                    } footer: {
                        Text("サイズを小さくするほどファイルは軽くなります。2048px でもスマホやPCでの閲覧には十分な画質です。")
                    }
                }

                Section {
                    Label("元の写真はそのまま残ります。処理が終わったあとに、元の写真を削除するかどうかを選べます。", systemImage: "info.circle")
                        .font(.footnote)
                    Label("撮影日・位置情報は元の写真から引き継ぎます。", systemImage: "calendar")
                        .font(.footnote)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart(JobSettings(
                        mode: mode,
                        format: format,
                        quality: quality,
                        maxDimension: maxDimension == 0 ? nil : maxDimension
                    ))
                } label: {
                    Text("\(count)枚を\(mode == .compress ? "圧縮" : "\(format.rawValue)に変換")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var formatNote: String {
        switch format {
        case .jpeg: "どの機器でも開ける標準的な形式です。"
        case .heic: "JPEGより同じ画質で約半分のサイズになります（iPhone標準形式）。"
        case .png: "劣化のない形式です。写真ではファイルサイズが大きくなります。"
        }
    }
}
