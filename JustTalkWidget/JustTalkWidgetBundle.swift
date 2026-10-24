//
//  JustTalkWidgetBundle.swift
//  JustTalkWidget
//
//  Widget extension: Live Activity диктовки (этап 5).
//  Dynamic Island и экран блокировки показывают фазу: «Запись началась» →
//  таймер → «Распознаю» → «Скопировано» / ошибка. Stop — только пока идёт запись.
//

import WidgetKit
import SwiftUI
import AppIntents

@main
struct JustTalkWidgetBundle: WidgetBundle {
    var body: some Widget {
        DictationActivityWidget()
    }
}

private typealias Phase = DictationActivityAttributes.Phase

private extension Phase {
    var tint: Color {
        switch self {
        case .started, .recording: .red
        case .transcribing: .orange
        case .done: .green
        case .failed, .interrupted: .yellow
        }
    }
}

/// Таймер записи или короткая надпись фазы.
private struct StatusText: View {
    let state: DictationActivityAttributes.ContentState
    var short = false

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        } else {
            Text(short ? state.phase.shortTitle : state.phase.title)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopDictationIntent()) {
            Image(systemName: "stop.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.borderless)
    }
}

struct DictationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            // Lock screen / баннер
            let state = context.state
            HStack(spacing: 12) {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.phase.title)
                        .font(.subheadline).bold()
                    if state.phase.isRecording {
                        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if let message = state.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if state.phase.isRecording {
                    StopButton()
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.phase.symbol)
                        .foregroundStyle(state.phase.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.phase.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase.isRecording {
                        StopButton()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if state.phase.isRecording {
                            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                                .monospacedDigit()
                        } else if let message = state.message {
                            Text(message).lineLimit(2)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
            } compactTrailing: {
                StatusText(state: state, short: true)
                    .font(.caption2)
                    .foregroundStyle(state.phase.tint)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
            }
            .widgetURL(URL(string: "justtalk://dictation"))
        }
    }
}
