import BackgroundTasks
import UIKit

/// 写真の処理を、アプリを離れても続けるための仕組み
/// - iOS 26 以降：「継続処理」（BGContinuedProcessingTask）で、ほかのアプリを使っている間も続ける。
///   進み具合は iPhone の画面上部に表示され、そこから中止もできる
/// - それ以外：アプリを離れてから約30秒だけ続ける（UIApplication の短時間延長）
/// 動画の圧縮には使わない（途中で止められると書き出しが失敗するため、動画はアプリを開いたまま処理する）
@MainActor
final class BackgroundWork {
    enum Mode {
        case none
        /// 約30秒だけ続けられる
        case shortExtension
        /// iOS 26 の継続処理（アプリを離れても続く）
        case continued
    }

    private(set) var mode: Mode = .none
    private var shortTaskID: UIBackgroundTaskIdentifier = .invalid
    /// iOS 26 の BGContinuedProcessingTask（古い iOS でもビルドできるよう Any で持つ）
    private var continuedTask: Any?
    private var onExpire: (() -> Void)?
    private var title = ""
    private var subtitle = ""
    private var done = 0
    private var total = 0

    /// 処理の開始時に呼ぶ。iOS や設定により継続処理が使えない場合は短時間延長だけになる
    func begin(title: String, subtitle: String, total: Int, onExpire: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.total = total
        self.done = 0
        self.onExpire = onExpire

        beginShortExtension()
        mode = .shortExtension

        #if compiler(>=6.2)
        if #available(iOS 26.0, *), submitContinuedTask() {
            mode = .continued
        }
        #endif
    }

    /// 進み具合を伝える（継続処理では、定期的に伝えないと iOS に止められることがある）
    func update(done: Int, subtitle: String) {
        self.done = done
        self.subtitle = subtitle
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            apply(to: task)
        }
        #endif
    }

    /// 処理の終了時に必ず呼ぶ
    func end(success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        #endif
        continuedTask = nil
        onExpire = nil
        endShortExtension()
        mode = .none
    }

    // MARK: - 短時間延長（約30秒）

    private func beginShortExtension() {
        guard shortTaskID == .invalid else { return }
        shortTaskID = UIApplication.shared.beginBackgroundTask(withName: "PhotoSqueeze.photos") { [weak self] in
            // 時間切れ。ここで終了を伝えないとアプリが強制終了されるので、すぐに閉じる
            // （写真の処理はそのまま一時停止し、アプリに戻ると続きから再開する）
            MainActor.assumeIsolated {
                self?.endShortExtension()
            }
        }
    }

    private func endShortExtension() {
        guard shortTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortTaskID)
        shortTaskID = .invalid
    }

    // MARK: - iOS 26 の継続処理

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func submitContinuedTask() -> Bool {
        // Info.plist の BGTaskSchedulerPermittedIdentifiers に "photosqueeze.compress.*" を登録してある
        let identifier = "photosqueeze.compress.\(UUID().uuidString)"
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // すぐに始められない場合は待たずに失敗させ、短時間延長だけで続ける
        request.strategy = .fail
        do {
            try scheduler.submit(request)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        // 開始前に処理が終わっていた場合はすぐに閉じる
        guard mode == .continued, onExpire != nil else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.expirationHandler = { [weak self] in
            // ユーザーが画面上部から中止した、または iOS が止めた
            Task { @MainActor in
                self?.onExpire?()
            }
        }
        apply(to: task)
    }

    @available(iOS 26.0, *)
    private func apply(to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(max(total, 1))
        task.progress.completedUnitCount = Int64(min(done, total))
        task.updateTitle(title, subtitle: subtitle)
    }
    #endif
}
