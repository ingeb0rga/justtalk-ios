//
//  DictationActivityAttributes.swift
//  JustTalk
//
//  Атрибуты Live Activity записи (этап 5). Компилируется в приложение
//  и в widget extension — определения должны совпадать.
//

import ActivityKit
import Foundation

/// nonisolated: ActivityAttributes-конформация используется из @concurrent
/// контекста (SE-0449), изоляция MainActor по умолчанию не подходит.
nonisolated struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Момент старта записи — для таймера в UI.
        var startedAt: Date
    }
}
