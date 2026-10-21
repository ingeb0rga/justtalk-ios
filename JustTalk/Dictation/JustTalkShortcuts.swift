//
//  JustTalkShortcuts.swift
//  JustTalk
//
//  Регистрация ярлыка для кнопки Action (этап 5): Настройки → Кнопка действия
//  → JustTalk → «Диктовка».
//

import AppIntents

struct JustTalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Диктовка в \(.applicationName)",
                "Запиши в \(.applicationName)",
            ],
            shortTitle: "Диктовка",
            systemImageName: "mic.circle"
        )
    }
}
