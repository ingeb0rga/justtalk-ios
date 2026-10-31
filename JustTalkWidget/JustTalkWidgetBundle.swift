//
//  JustTalkWidgetBundle.swift
//  JustTalkWidget
//
//  Widget extension: Live Activity диктовки (этап 5). Без текста:
//  запись — таймер, распознавание — кольцо, итог — галочка (или ⚠).
//  Развёрнутый остров — одна строка (значок, таймер, «Стоп»): развернуть
//  его iOS может сама, отключить это нельзя.
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

private typealias State = DictationActivityAttributes.ContentState

private extension DictationActivityAttributes.Phase {
    var tint: Color {
        switch self {
        case .started, .recording: .red
        case .transcribing: .orange
        case .done: .green
        case .failed, .interrupted: .yellow
        }
    }
}

/// Значок фазы.
private struct PhaseIcon: View {
    let state: State

    var body: some View {
        Image(systemName: state.phase.symbol)
            .foregroundStyle(state.phase.tint)
    }
}

/// Правая часть: таймер записи, кольцо распознавания или ничего.
private struct PhaseStatus: View {
    let state: State

    var body: some View {
        switch state.phase {
        case .started, .recording:
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(state.phase.tint)
        case .transcribing:
            let start = Date()
            ProgressView(
                timerInterval: start...max(state.until ?? start.addingTimeInterval(5), start.addingTimeInterval(1)),
                countsDown: false,
                label: { EmptyView() },
                currentValueLabel: { EmptyView() }
            )
            .progressViewStyle(.circular)
            .tint(state.phase.tint)
        case .done, .failed, .interrupted:
            EmptyView()
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
            // Экран блокировки / шторка
            let state = context.state
            HStack(spacing: 12) {
                PhaseIcon(state: state)
                    .font(.title2)
                PhaseStatus(state: state)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state.phase.isRecording {
                    StopButton()
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // Развернуть остров iOS может сама (при старте, по долгому
                // нажатию) — запретить нельзя. Поэтому одна низкая строка на
                // уровне камеры: слева значок + таймер/кольцо, справа «Стоп».
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PhaseIcon(state: state)
                        PhaseStatus(state: state)
                            .frame(width: 56, alignment: .leading)
                    }
                    .font(.title3)
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase.isRecording {
                        StopButton()
                            .padding(.trailing, 8)
                            .frame(maxHeight: .infinity)
                    }
                }
            } compactLeading: {
                PhaseIcon(state: state)
            } compactTrailing: {
                PhaseStatus(state: state)
                    .font(.caption2)
                    .frame(width: 40)
            } minimal: {
                PhaseIcon(state: state)
            }
            .widgetURL(URL(string: "justtalk://dictation"))
        }
    }
}
