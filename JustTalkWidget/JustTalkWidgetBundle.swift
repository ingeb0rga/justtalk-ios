//
//  JustTalkWidgetBundle.swift
//  JustTalkWidget
//
//  Widget extension: Live Activity записи диктовки (этап 5).
//  Dynamic Island: индикатор + таймер + кнопка Stop. Lock screen: то же.
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

struct DictationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            // Lock screen / баннер
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JustTalk — запись")
                        .font(.subheadline).bold()
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(intent: StopDictationIntent()) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Запись")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopDictationIntent()) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture,
                     countsDown: false)
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            .widgetURL(URL(string: "justtalk://dictation"))
        }
    }
}
