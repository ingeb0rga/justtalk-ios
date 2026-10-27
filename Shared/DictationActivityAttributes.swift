//
//  DictationActivityAttributes.swift
//  JustTalk
//
//  Атрибуты Live Activity записи (этап 5). Компилируется в приложение
//  и в widget extension — определения должны совпадать.
//  Live Activity — единственный канал статуса, без текста: таймер записи,
//  кольцо распознавания, галочка (или ⚠) в конце.
//

import ActivityKit
import Foundation

/// nonisolated: ActivityAttributes-конформация используется из @concurrent
/// контекста (SE-0449), изоляция MainActor по умолчанию не подходит.
nonisolated struct DictationActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        /// Не используется (была надпись «Запись началась»); оставлена для
        /// декодирования активностей прежних сборок.
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
        /// Ожидаемый конец распознавания — для кольца прогресса.
        var until: Date?

        init(startedAt: Date, phase: Phase = .recording, message: String? = nil, until: Date? = nil) {
            self.startedAt = startedAt
            self.phase = phase
            self.message = message
            self.until = until
        }

        /// Терпимо к активностям прежних сборок (без phase/message).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .recording
            message = try c.decodeIfPresent(String.self, forKey: .message)
            until = try c.decodeIfPresent(Date.self, forKey: .until)
        }
    }
}

extension DictationActivityAttributes.Phase {
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
