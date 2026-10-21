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
        let preset = CompressionPreset.medium
        _quality = State(initialValue: mode == .compress ? preset.quality : 0.9)
        _maxDimension = State(initialValue: mode == .compress ? preset.maxDimension : 0)
    }

    private var formatChoices: [OutputFormat] {
        mode == .compress ? [.jpeg, .heic] : [.jpeg, .png]
    }

    /// 今の画質・サイズに一致するプリセット（手動で変えた場合は nil）
    private var currentPreset: CompressionPreset? {
        CompressionPreset.allCases.first {
            $0.maxDimension == maxDimension && abs($0.quality - quality) < 0.001
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .compress {
                    presetSection
                }

                Section {
                    Picker(mode == .compress ? "保存形式" : "変換先", selection: $format) {
                        ForEach(formatChoices) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(formatNote)
                }

                if format.isLossy {
                    Section(mode == .compress ? "細かく調整：画質 \(Int(quality * 100))%" : "画質 \(Int(quality * 100))%") {
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
                        Text("画質やサイズを変えると「カスタム」になります。")
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
        .presentationDetents([.large])
    }

    private var presetSection: some View {
        Section {
            ForEach(CompressionPreset.allCases) { preset in
                Button {
                    quality = preset.quality
                    maxDimension = preset.maxDimension
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: currentPreset == preset ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(currentPreset == preset ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(preset.title).font(.body.bold())
                                Spacer()
                                Text(preset.estimate(for: format))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(preset.usage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(preset.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if currentPreset == nil {
                Label("カスタム設定（画質 \(Int(quality * 100))%・\(maxDimension == 0 ? "元のサイズ" : "\(maxDimension)px")）", systemImage: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            Text("用途を選ぶ")
        } footer: {
            Text("1枚あたりの大きさは、iPhoneの標準的な写真（1200万画素）での目安です。細かい模様や暗い場所の写真は大きくなります。")
        }
    }

    private var formatNote: String {
        switch format {
        case .jpeg: "どの機器でも開ける標準的な形式です。"
        case .heic: "JPEGより同じ画質で約半分のサイズになります（iPhone標準形式）。"
        case .png: "劣化のない形式です。写真ではファイルサイズが大きくなります。"
        }
    }
}

/// 圧縮の用途別プリセット
enum CompressionPreset: String, CaseIterable, Identifiable {
    case printing
    case high
    case medium
    case web
    case light

    var id: Self { self }

    var title: String {
        switch self {
        case .printing: "印刷向け"
        case .high: "高画質"
        case .medium: "中画質（おすすめ）"
        case .web: "Web向け"
        case .light: "軽量"
        }
    }

    var usage: String {
        switch self {
        case .printing: "A4〜A3の印刷、元の画質をほぼ保ちたいとき"
        case .high: "A4印刷、拡大して細部を見る写真"
        case .medium: "L判〜2L判の印刷、報告書、ANDPADなどへの登録"
        case .web: "ホームページ、SNS、ブログ"
        case .light: "メール、LINE、チャットで送る"
        }
    }

    var maxDimension: Int {
        switch self {
        case .printing: 0
        case .high: 3024
        case .medium: 2048
        case .web: 1600
        case .light: 1280
        }
    }

    var quality: Double {
        switch self {
        case .printing: 0.9
        case .high: 0.85
        case .medium: 0.75
        case .web: 0.7
        case .light: 0.65
        }
    }

    var detail: String {
        "長辺 \(maxDimension == 0 ? "元のサイズ" : "\(maxDimension)px")・画質 \(Int(quality * 100))%"
    }

    /// JPEG で保存したときの1枚あたりの目安（KB）
    private var jpegRangeKB: (Int, Int) {
        switch self {
        case .printing: (2500, 4000)
        case .high: (1200, 2000)
        case .medium: (500, 800)
        case .web: (250, 400)
        case .light: (150, 250)
        }
    }

    /// 1枚あたりの大きさの目安。HEIC は JPEG のおよそ半分
    func estimate(for format: OutputFormat) -> String {
        var (low, high) = jpegRangeKB
        if format == .heic {
            low /= 2
            high /= 2
        }
        return "約\(Self.sizeText(low))〜\(Self.sizeText(high))"
    }

    private static func sizeText(_ kb: Int) -> String {
        guard kb >= 1000 else { return "\(kb)KB" }
        let mb = Double(kb) / 1000
        return mb == mb.rounded() ? "\(Int(mb))MB" : String(format: "%.1fMB", mb)
    }
}
