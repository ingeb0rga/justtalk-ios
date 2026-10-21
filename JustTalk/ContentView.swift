//
//  ContentView.swift
//  JustTalk
//
//  UI диктовки (этапы 2–5): статус модели, запись, результат + буфер.
//  Логика — в DictationController.
//

import SwiftUI
import SherpaOnnx

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = DictationController.shared
    @State private var showSettings = false
    @State private var errorText: String?

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private func showError(_ error: Error) {
        errorText = error.localizedDescription
    }

    var body: some View {
        NavigationStack {
            mainView
                .navigationTitle("JustTalk")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusView

            if case .ready = controller.modelStatus {
                controlsView
            }

            if controller.state == .busy {
                ProgressView("Распознаю…")
            }
            if !controller.timingText.isEmpty {
                Text(controller.timingText)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !controller.resultText.isEmpty {
                Text(controller.resultText)
                Button("Скопировать") {
                    UIPasteboard.general.string = controller.resultText
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }        .task { controller.probe() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { controller.probe() }
        }
        .alert("JustTalk", isPresented: showErrorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .overlay(alignment: .top) {
            if let toast = controller.toast {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = toast.title {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(toast.text)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.toast)
    }

    /// Движок грузится сам при старте записи (параллельно с ней).
    @ViewBuilder
    private var controlsView: some View {
        switch controller.state {
        case .recording:
            Button("Стоп и распознать") { Task { await controller.stopAndTranscribe() } }
                .tint(.red)
        case .idle, .busy:
            Button("● Записать") {
                Task {
                    do { try await controller.startDictation() }
                    catch { showError(error) }
                }
            }
            .disabled(controller.state == .busy)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.modelStatus {
        case .notFound:
            Label("Модель не найдена", systemImage: "xmark.circle")
                .foregroundStyle(.red)
            Text("""
            Скачайте и распакуйте \(archiveName) на маке, затем скопируйте каталог через Finder → iPhone → Файлы → JustTalk в Documents/models/.
            """)
            .font(.footnote).foregroundStyle(.secondary)
            Button("Проверить снова") { controller.probe() }
                .font(.footnote)
            Text("Видно в приложении:\n\(controller.diagnostics)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        case .corrupted(let reasons):
            Label("Модель повреждена", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            ForEach(reasons, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        case .ready(let files):
            Label("Модель найдена: \(files.directory.lastPathComponent)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    private var archiveName: String { "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2" }
}

#Preview {
    ContentView()
}
