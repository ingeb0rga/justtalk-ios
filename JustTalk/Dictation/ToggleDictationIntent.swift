//
//  ToggleDictationIntent.swift
//  JustTalk
//
//  Интент диктовки для Action Button и «Быстрых команд» (этап 5).
//  Только в приложении: если тот же тип есть и в widget extension, система
//  может выполнить копию из extension — та не умеет распознавать и вернула бы
//  в команду пустую строку. Для кнопки Stop в Live Activity —
//  StopDictationIntent (Shared/).
//

import AppIntents

/// LiveActivityIntent обязателен: даёт право поднять Live Activity из фона.
/// Без неё AppIntents роняет процесс («AudioRecordingIntent was performed
/// with an active audio session but without a Live Activity»).
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Диктовка JustTalk"
    static let description = IntentDescription(
        "Старт/стоп диктовки: запись с микрофона, офлайн-распознавание, текст в буфер обмена."
    )

    /// Только фон: экран приложения при Action Button не открываем.
    static let supportedModes: IntentModes = [.background]

    /// Возвращает распознанный текст (при старте — пустую строку): в
    /// «Быстрой команде» его можно отдать в «Скопировать в буфер» —
    /// Shortcuts копирует сам, без фонового запрета iOS.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Прямой тоггл контроллера. Без диалогов — баннер
        // диалога рисует системную кнопку «Готово»; фидбек дают
        // Live Activity в Dynamic Island (уведомлений нет).
        let controller = DictationController.shared
        switch controller.state {
        case .recording:
            let text = await controller.stopAndTranscribe()
            return .result(value: text)
        case .idle, .busy:
            // Прошлый процесс убит посреди записи — этот тап пользователь
            // жмёт как «стоп»: не начинать новую запись.
            if controller.consumeInterruptedRecording() { break }
            do {
                try await controller.startDictation()
            } catch {
                // Не бросаем: «Команды» показали бы баннер с ошибкой.
                // Статус — только в Dynamic Island.
                controller.showStartFailure(error)
            }
        }
        return .result(value: "")
    }
}
