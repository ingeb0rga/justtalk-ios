//
//  DictationController.swift
//  JustTalk
//
//  Единый конечный автомат диктовки (этапы 4–5): запись → распознавание
//  → буфер обмена. Используется UI и ToggleDictationIntent (Action Button,
//  кнопка Stop в Live Activity). Live Activity обязательна при записи,
//  запущенной через AudioRecordingIntent (требование Apple).
//

import ActivityKit
import SherpaOnnx
import UIKit
import UserNotifications

enum DictationState {
    case idle
    case recording
    case busy
}

/// Попап внутри приложения: сам исчезает (текст 2 с, «скопировано» 1 с).
struct DictationToast: Equatable {
    enum Kind { case result, copied, info }
    var text: String
    var kind: Kind
    var title: String?
}

enum DictationError: LocalizedError {    case modelNotReady
    case engineFailed
    case micPermissionDenied
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "Модель не найдена — скопируйте её в Documents/models/."
        case .engineFailed: "Не удалось загрузить движок распознавания."
        case .micPermissionDenied: "Нет доступа к микрофону — разрешите в Настройки → Конфиденциальность → Микрофон."
        case .recordingFailed(let msg): "Ошибка записи: \(msg)"
        }
    }
}

@Observable
final class DictationController {
    static let shared = DictationController()

    private(set) var state: DictationState = .idle
    private(set) var modelStatus: ModelStatus = .notFound
    private(set) var diagnostics = ""
    private(set) var resultText = ""
    private(set) var timingText = ""
    private(set) var toast: DictationToast?
    /// Движок загружен (после успешного await задачи загрузки).
    private(set) var engineReady = false
    /// Было ли приложение на экране в этом процессе. Если нет (процесс
    /// запущен интентом в фоне) — запись из фона iOS не разрешит.
    private(set) var wasForegroundThisLaunch = false
    /// Текст, который не удалось положить в буфер из фона (iOS не пускает
    /// фоновые процессы к буферу). Копируется при следующем открытии.
    private var pendingCopy: String?

    private var probedFiles: Qwen3ModelFiles?
    private var recorder: Recorder?
    private var engineTask: Task<SherpaTranscriber, Error>?
    private var activity: Activity<DictationActivityAttributes>?

    private init() {
        registerToggleObserver()
        wasForegroundThisLaunch = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wasForegroundThisLaunch = true
                self?.flushPendingCopy()
            }
        }
    }

    // MARK: - Модель

    func probe() {
        let store = ModelStore()
        // Приоритет — активная модель из настроек (этап 7); иначе
        // прежний рекурсивный поиск (модель, скопированная через Finder).
        let active = store.installedState(TranscriptionSettings.activeVariant)
        if case .ready(let files) = active {
            modelStatus = .ready(files)
            probedFiles = files
            diagnostics = store.diagnostics()
            return
        }
        let (status, files) = store.probeQwen3()
        modelStatus = status
        probedFiles = files
        diagnostics = store.diagnostics()
    }

    /// Запускает загрузку движка (кнопка «Загрузить модель» и старт записи).
    /// Потоки берутся из настроек; модель — активная в каталоге.
    @discardableResult
    private func ensureEngine() -> Task<SherpaTranscriber, Error>? {
        guard engineTask == nil, !engineReady else { return engineTask }
        guard case .ready(let files) = modelStatus else { return nil }
        let threads = TranscriptionSettings.numThreads
        let task = Task.detached(priority: .userInitiated) {
            guard let engine = SherpaTranscriber.make(modelFiles: files, numThreads: threads) else {
                throw DictationError.engineFailed
            }
            return engine
        }
        engineTask = task
        return task
    }

    /// Сброс движка: смена активной модели или числа потоков в настройках.
    func resetEngine() {
        guard state == .idle else { return }
        engineTask?.cancel()
        engineTask = nil
        engineReady = false
        probe()
    }

    // MARK: - Диктовка

    /// Старт записи. Live Activity — до включения микрофона (требование
    /// AudioRecordingIntent).
    func startDictation() async throws {
        guard state == .idle else { return }
        // Без разрешения активация аудиосессии падает
        // «Session activation failed» — проверяем явно.
        guard await Recorder.hasMicPermission() else {
            throw DictationError.micPermissionDenied
        }
        // Для попапов с результатом (этап 6); вопрос показывается один раз.
        try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])
        // Холодный запуск интентом: экран не открывался, probe() не вызывался.
        if case .ready = modelStatus {} else { probe() }
        guard case .ready = modelStatus else { throw DictationError.modelNotReady }
        if !engineReady { _ = ensureEngine() }

        let activityError = startActivity()
        let inBackground = UIApplication.shared.applicationState != .active
        // Из фона (интент) запись без Live Activity AppIntents считает
        // нарушением и роняет процесс — не включаем микрофон.
        if inBackground, let activityError {
            throw DictationError.recordingFailed("Live Activity не запустилась: \(activityError)")
        }
        do {
            let rec = Recorder()
            rec.onLimitReached = { [weak self] in
                Task { await self?.stopAndTranscribe() }
            }
            try rec.start(mixable: inBackground)
            recorder = rec
        } catch {
            endActivity()
            // Диагностика для разбора на устройстве: код AVAudioSession
            // (FourCC), режим запуска, удалось ли поднять Live Activity.
            var details = [Self.describe(error)]
            details.append(inBackground
                ? (wasForegroundThisLaunch ? "фон" : "холодный фон")
                : "на экране")
            if let activityError {
                details.append("Live Activity: \(activityError)")
            }
            throw DictationError.recordingFailed(details.joined(separator: " · "))
        }
        state = .recording
        resultText = ""
        timingText = ""
        toast = nil

        // Попап о старте записи (в фоне — уведомление).
        if UIApplication.shared.applicationState != .active {
            notify(title: "Диктовка", body: "Запись начата")
        } else {
            toast = DictationToast(text: "Запись начата", kind: .info)
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if toast?.kind == .info { toast = nil }
            }
        }
    }

    /// Стоп → распознавание → буфер обмена. Возвращает текст (для диалога интента).
    @discardableResult
    func stopAndTranscribe() async -> String {
        guard state == .recording, let rec = recorder else { return resultText }
        recorder = nil
        state = .busy

        let recorded = rec.stop()
        var outcomeText = ""
        var copied = false

        do {
            guard let engineTask else { throw DictationError.modelNotReady }
            let engine = try await engineTask.value
            engineReadyFlagSet()

            let outcome = await Task.detached(priority: .userInitiated) {
                Self.transcribe(recorded.samples, sampleRate: recorded.sampleRate, engine: engine)
            }.value

            outcomeText = outcome.text
            resultText = outcome.text
            timingText = outcome.timing
            if !outcome.text.isEmpty {
                copied = copyToPasteboard(outcome.text)
            }
        } catch {
            timingText = error.localizedDescription
            // Провалившаяся загрузка не должна блокировать повторную.
            engineTask = nil
            if UIApplication.shared.applicationState != .active {
                notify(title: "Диктовка", body: error.localizedDescription)
            } else {
                toast = DictationToast(text: error.localizedDescription, kind: .result)
            }
        }

        if !outcomeText.isEmpty {
            // Этап 6: попапы без кнопок, сами закрываются.
            let body = outcomeText.count > 120
                ? String(outcomeText.prefix(120)) + "…"
                : outcomeText
            if UIApplication.shared.applicationState != .active {
                // В фоне: уведомления без кнопок (баннер интента даёт
                // системную кнопку «Готово» — не используем).
                notify(title: "Результат распознавания", body: body)
                // Если iOS не пустила к буферу из фона — молчим: при запуске
                // через «Быструю команду» буфер заполнит она (результат
                // интента → «Скопировать»), а текст ещё скопируется при
                // открытии приложения (pendingCopy).
                if copied {
                    notify(title: "Диктовка", body: "Скопировано в буфер обмена")
                }
            } else {
                // В приложении: свои попапы — текст 2 с, потом «скопировано» 1 с.
                toast = DictationToast(text: body, kind: .result,
                                       title: "Результат распознавания")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard toast?.kind == .result else { return }
                    toast = DictationToast(text: "Скопировано в буфер обмена", kind: .copied)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if toast?.kind == .copied { toast = nil }
                }
            }
        }

        endActivity()
        state = .idle
        return outcomeText
    }

    /// Пишет в буфер; true — если запись реально прошла (changeCount вырос).
    /// Из фона iOS запись в буфер может молча отклонить — тогда текст
    /// откладывается до открытия приложения.
    private func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = text
        if pasteboard.changeCount != before {
            pendingCopy = nil
            return true
        }
        pendingCopy = text
        return false
    }

    private func flushPendingCopy() {
        guard let text = pendingCopy else { return }
        pendingCopy = nil
        UIPasteboard.general.string = text
        toast = DictationToast(text: "Скопировано в буфер обмена", kind: .copied)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if toast?.kind == .copied { toast = nil }
        }
    }

    /// Локальное уведомление-попап (работает и когда приложение не активно).
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Движок готов (после успешной загрузки задачи).
    private func engineReadyFlagSet() {
        engineReady = true
    }

    nonisolated private static func transcribe(
        _ samples: [Float], sampleRate: Double, engine: SherpaTranscriber
    ) -> (text: String, timing: String) {
        let seconds = Double(samples.count) / sampleRate
        let t0 = Date()
        let text = engine.transcribe(samples, sampleRate: Int(sampleRate))
        let elapsed = Date().timeIntervalSince(t0)
        let rtf = seconds > 0 ? elapsed / seconds : 0
        let timing = String(format: "%.2f с аудио, распознано за %.2f с, RTF %.2f, потоков %d",
                            seconds, elapsed, rtf, engine.numThreads)
        return (text, timing)
    }

    // MARK: - Live Activity

    /// Возвращает текст ошибки, если Live Activity поднять не удалось.
    private func startActivity() -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "выключены в настройках"
        }
        let attributes = DictationActivityAttributes()
        let content = ActivityContent(
            state: DictationActivityAttributes.ContentState(startedAt: Date()),
            staleDate: nil
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Текст ошибки + код; для OSStatus-кодов AVAudioSession — FourCC ('!pla').
    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var code = "\(ns.code)"
        let raw = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((raw >> UInt32($0)) & 0xFF) }
        if ns.domain == NSOSStatusErrorDomain,
           bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            code += " '" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return "\(ns.localizedDescription) (\(code))"
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Stop из extension (кнопка в Live Activity)

    nonisolated private func registerToggleObserver() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<DictationController>
                    .fromOpaque(observer).takeUnretainedValue()
                // Сигнал шлёт только кнопка Stop в Live Activity — только стоп.
                Task { @MainActor in
                    if controller.state == .recording {
                        await controller.stopAndTranscribe()
                    }
                }
            },
            JustTalkToggleNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
}
