//
//  StopDictationIntent.swift
//  JustTalk
//
//  Кнопка Stop в Live Activity (этап 5). Компилируется в приложение И в
//  widget extension (кнопке нужен тип интента в обоих процессах).
//  - в процессе приложения — прямой вызов контроллера;
//  - в процессе extension — Darwin-уведомление, приложение слушает.
//  Интент Action Button / «Быстрых команд» — ToggleDictationIntent
//  (только приложение, JustTalk/Dictation/).
//

import AppIntents
import CoreFoundation

/// Имя Darwin-уведомления «переключить диктовку». Строка используется
/// и в DictationController (регистрация наблюдателя) — держим в одном месте.
nonisolated let JustTalkToggleNotification = "com.spirt.JustTalk.toggle"

/// Постит Darwin-уведомление (работает из любого процесса, в т.ч. extension).
nonisolated func postToggleDictation() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(
        center,
        CFNotificationName(JustTalkToggleNotification as CFString),
        nil, nil, true
    )
}

struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Остановить диктовку JustTalk"
    /// Служебный: только для кнопки в Live Activity, не в «Командах».
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
#if JUSTTALK_APP
        let controller = DictationController.shared
        if controller.state == .recording {
            await controller.stopAndTranscribe()
        } else {
            // Записи в этом процессе нет — активность осталась от убитого
            // процесса: просто убрать её из шторки.
            controller.endStaleActivities()
        }
#else
        // Extension: сигнал приложению.
        postToggleDictation()
#endif
        return .result()
    }
}
