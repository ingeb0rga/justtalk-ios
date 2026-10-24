//
//  DictationActivityAttributes.swift
//  JustTalk
//
//  Атрибуты Live Activity записи (этап 5). Компилируется в приложение
//  и в widget extension — определения должны совпадать.
//  Live Activity — единственный канал статуса: уведомлений нет,
//  надписи («Запись началась», «Распознаю…», «Скопировано») — в Dynamic Island.
//

import ActivityKit
import Foundation

/// nonisolated: ActivityAttributes-конформация используется из @concurrent
/// контекста (SE-0449), изоляция MainActor по умолчанию не подходит.
nonisolated struct DictationActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        /// Первые секунды записи — надпись «Запись началась».
        case started
        /// Идёт запись — таймер.
        case recording
        case transcribing
        /// Текст в буфере; message — начало текста.
        case done
        /// message — ошибка.
        case failed
        /// Прошлый процесс убит посреди записи.
        case interrupted
    }

    struct ContentState: Codable, Hashable {
        /// Момент старта записи — для таймера в UI.
        var startedAt: Date
        var phase: Phase = .recording
        var message: String?

        init(startedAt: Date, phase: Phase = .recording, message: String? = nil) {
            self.startedAt = startedAt
            self.phase = phase
            self.message = message
        }

        /// Терпимо к активностям прежних сборок (без phase/message).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .recording
            message = try c.decodeIfPresent(String.self, forKey: .message)
        }
    }
}

extension DictationActivityAttributes.Phase {
    /// Короткая надпись для компактного Dynamic Island.
    var shortTitle: String {
        switch self {
        case .started: "Запись"
        case .recording: "Запись"
        case .transcribing: "Распознаю"
        case .done: "Готово"
        case .failed: "Ошибка"
        case .interrupted: "Прервано"
        }
    }

    /// Полная надпись: развёрнутый остров и экран блокировки.
    var title: String {
        switch self {
        case .started: "Запись началась"
        case .recording: "Идёт запись"
        case .transcribing: "Запись закончилась, распознаю…"
        case .done: "Скопировано в буфер обмена"
        case .failed: "Не удалось распознать"
        case .interrupted: "Запись прервалась"
        }
    }

    var symbol: String {
        switch self {
        case .started, .recording: "mic.fill"
        case .transcribing: "waveform"
        case .done: "checkmark.circle.fill"
        case .failed, .interrupted: "exclamationmark.triangle.fill"
        }
    }

    var isRecording: Bool { self == .started || self == .recording }
}
