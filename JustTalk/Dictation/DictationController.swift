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
import os
import SherpaOnnx
import UIKit

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
    case notEnoughMemory(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notEnoughMemory(let needed, let available):
            String(format: "Модели не хватит памяти: нужно ≈%.1f ГБ, iOS даёт %.1f ГБ. Выберите 0.6B в настройках.",
                   Double(needed) / 1e9, Double(available) / 1e9)
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
    /// Прошлый процесс умер посреди записи (jetsam, падение): при старте
    /// нашлась его недавняя Live Activity. Следующий тап — «стоп», а не
    /// новая запись: пользователь думает, что запись ещё идёт.
    private var interruptedRecording = false

    private var probedFiles: Qwen3ModelFiles?
    private var recorder: Recorder?
    private var engineTask: Task<SherpaTranscriber, Error>?
    private var activity: Activity<DictationActivityAttributes>?

    private init() {
        registerToggleObserver()
        interruptedRecording = endOrphanedActivities()
        wasForegroundThisLaunch = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wasForegroundThisLaunch = true
                self?.interruptedRecording = false
                self?.flushPendingCopy()
            }
        }
    }

    /// Ошибка старта — в Dynamic Island вместо системного баннера «Команд».
    func showStartFailure(_ error: Error) {
        showOneShotActivity(.failed, message: error.localizedDescription)
    }

    /// Тап после гибели прошлого процесса: сообщить и не начинать запись.
    /// true — тап поглощён.
    func consumeInterruptedRecording() -> Bool {
        guard interruptedRecording, state == .idle else { return false }
        interruptedRecording = false
        showOneShotActivity(.interrupted, message: "iOS закрыла приложение. Нажмите ещё раз, чтобы начать заново.")
        return true
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

    /// Пиковая память движка: файлы модели × 1,5 (на устройстве 1.7B,
    /// 2,3 ГБ файлов, дошла до 3,4 ГБ и была убита по лимиту).
    nonisolated private static func estimatedEngineMemory(_ files: Qwen3ModelFiles) -> Int64 {
        let bytes = [files.convFrontend, files.encoder, files.decoder].reduce(Int64(0)) { sum, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
        return bytes * 3 / 2
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
        // Холодный запуск интентом: экран не открывался, probe() не вызывался.
        if case .ready = modelStatus {} else { probe() }
        guard case .ready(let files) = modelStatus else { throw DictationError.modelNotReady }
        if !engineReady, engineTask == nil {
            // 1.7B раздувает процесс до лимита iOS — jetsam убивает его
            // посреди записи. Лучше отказать сразу, до микрофона.
            let needed = Self.estimatedEngineMemory(files)
            let available = Int64(os_proc_available_memory())
            if available > 0, available < needed {
                throw DictationError.notEnoughMemory(needed: needed, available: available)
            }
        }
        if !engineReady { _ = ensureEngine() }

        let activityError = startActivity()
        let inBackground = UIApplication.shared.applicationState != .active
        // Из фона (интент) запись без Live Activity AppIntents считает
        // нарушением и роняет процесс — не включаем микрофон.
        if inBackground, let activityError {
            throw DictationError.recordingFailed("Live Activity не запустилась: \(activityError)")
        }
        // iOS 27.2: микрофон сразу после Activity.request — AppIntents
        // иногда не успевает увидеть активность и роняет процесс
        // («AudioRecordingIntent was performed with an active audio session
        // but without a Live Activity»). Пауза до активации аудиосессии.
        if activityError == nil {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        Self.debugLog("mic start")
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

        if UIApplication.shared.applicationState == .active {
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
        Self.debugLog(Self.audioStats(recorded.samples, sampleRate: recorded.sampleRate))
        // Кольцо в острове: оценка времени распознавания (журнал: ~0,4 × длина + 1,5 с).
        let audioSeconds = recorded.sampleRate > 0 ? Double(recorded.samples.count) / recorded.sampleRate : 0
        updateActivity(.transcribing, until: Date().addingTimeInterval(audioSeconds * 0.4 + 1.5))
        var outcomeText = ""
        var failure: String?

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
            if outcome.text.isEmpty {
                failure = "Ничего не распознано"
            } else {
                // Из фона iOS может не пустить к буферу — тогда копирует
                // «Быстрая команда» (результат интента), а текст ещё
                // скопируется при открытии приложения (pendingCopy).
                _ = copyToPasteboard(outcome.text)
            }
        } catch {
            timingText = error.localizedDescription
            // Провалившаяся загрузка не должна блокировать повторную.
            engineTask = nil
            failure = error.localizedDescription
            if UIApplication.shared.applicationState == .active {
                toast = DictationToast(text: error.localizedDescription, kind: .result)
            }
        }

        if !outcomeText.isEmpty {
            // Этап 6: попапы без кнопок, сами закрываются.
            let body = outcomeText.count > 120
                ? String(outcomeText.prefix(120)) + "…"
                : outcomeText
            if UIApplication.shared.applicationState == .active {
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

        // Итог — в Dynamic Island на 3 с, потом остров закрывается сам.
        if let failure {
            endActivity(.failed, message: failure)
        } else {
            endActivity(.done, message: String(outcomeText.prefix(80)))
        }
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
            state: DictationActivityAttributes.ContentState(startedAt: Date(), phase: .recording),
            staleDate: nil
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            Self.debugLog("request ok id=\(activity?.id ?? "-") appState=\(UIApplication.shared.applicationState.rawValue) all=\(Activity<DictationActivityAttributes>.activities.count)")
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

    /// Смена надписи в Dynamic Island (startedAt сохраняется для таймера).
    /// Без alert: iOS не разворачивала остров на старте записи, а без
    /// надписи о старте развёрнутые надписи на финише смысла не имеют.
    private func updateActivity(
        _ phase: DictationActivityAttributes.Phase, message: String? = nil, until: Date? = nil
    ) {
        guard let activity else { return }
        var state = activity.content.state
        state.phase = phase
        state.message = message
        state.until = until
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Длина, RMS и пик записи (dBFS) — понять «Ничего не распознано»:
    /// тишина (около −90 дБ) или нормальный голос (−40…−20 дБ).
    nonisolated static func audioStats(_ samples: [Float], sampleRate: Double) -> String {
        guard !samples.isEmpty else { return "audio: 0 samples, rate=\(sampleRate)" }
        var sum: Double = 0
        var peak: Float = 0
        for x in samples {
            sum += Double(x * x)
            peak = max(peak, abs(x))
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        func db(_ v: Double) -> String { String(format: "%.1f", 20 * log10(max(v, 1e-9))) }
        let seconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        return String(format: "audio: %.2f s, rate=%.0f, ", seconds, sampleRate)
            + "rms=\(db(rms)) dBFS, peak=\(db(Double(peak))) dBFS"
    }

    /// Отладочный журнал: Documents/activity.log (снимается devicectl).
    /// Временный — до выяснения причин «Ничего не распознано».
    nonisolated static func debugLog(_ line: String) {
        let url = URL.documentsDirectory.appendingPathComponent("activity.log")
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Итоговая фаза в острове на 3 с, затем активность закрывается сама.
    private func endActivity(_ phase: DictationActivityAttributes.Phase, message: String?) {
        guard let activity else { return }
        self.activity = nil
        var state = activity.content.state
        state.phase = phase
        state.message = message
        let content = ActivityContent(state: state, staleDate: nil)
        Self.debugLog("final -> \(phase): \(message ?? "")")
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3))) }
    }

    /// Надпись без записи (например «Запись прервалась»): поднять и
    /// сразу завершить с показом на 3 с.
    private func showOneShotActivity(_ phase: DictationActivityAttributes.Phase, message: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DictationActivityAttributes.ContentState(startedAt: Date(), phase: phase, message: message)
        guard let shot = try? Activity.request(
            attributes: DictationActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil)
        ) else { return }
        Task {
            await shot.end(ActivityContent(state: state, staleDate: nil),
                           dismissalPolicy: .after(Date().addingTimeInterval(3)))
        }
    }

    /// Закрывает все Live Activity, кроме текущей записи. Нужна, когда
    /// процесс умер посреди записи: активность остаётся в шторке, таймер
    /// идёт, а «Стоп» слать некому.
    func endStaleActivities() {
        for stale in Activity<DictationActivityAttributes>.activities where stale.id != activity?.id {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// При старте процесса: закрыть активности прошлого процесса.
    /// true — среди них была недавняя (запись прервалась в пределах лимита).
    private func endOrphanedActivities() -> Bool {
        let orphans = Activity<DictationActivityAttributes>.activities
        let window = Recorder.maxSeconds + 120
        // Только живые активности записи: итоговые («Готово») прошлого
        // процесса уже завершены и досиживают свои 3 с.
        let recent = orphans.contains {
            $0.activityState == .active
                && $0.content.state.phase.isRecording
                && Date().timeIntervalSince($0.content.state.startedAt) < window
        }
        for orphan in orphans where orphan.activityState == .active {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
        return recent
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
