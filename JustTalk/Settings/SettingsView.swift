//
//  SettingsView.swift
//  JustTalk
//
//  Настройки (этап 7): каталог моделей (0.6B / 1.7B) с загрузкой,
//  удалением и выбором активной; потоки распознавания; лимит записи.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TranscriptionSettings.activeModelKey) private var activeModelId =
        ModelVariant.catalog[0].id
    @AppStorage(TranscriptionSettings.numThreadsKey) private var numThreads = 6
    @AppStorage(TranscriptionSettings.maxRecordSecondsKey) private var maxRecordSeconds = 300

    @State private var downloader = ModelDownloader.shared
    /// Статус вариантов: id → nil (нет каталога) / corrupted / ready.
    @State private var states: [String: ModelStatus?] = [:]
    @State private var deleteCandidate: ModelVariant?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                modelsSection
                recognitionSection
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task { refreshStates() }
            // Статусы устарели после завершения/ошибки загрузки.
            .onChange(of: downloader.phase) { refreshStates() }
            .onDisappear { DictationController.shared.probe() }
            .alert(
                "JustTalk",
                isPresented: .init(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    // MARK: - Модели

    private var modelsSection: some View {
        Section {
            ForEach(ModelVariant.catalog) { variant in
                modelRow(variant)
            }
        } header: {
            Text("Модель распознавания")
        } footer: {
            Text("Загрузка идёт в Documents/models. Активной становится модель, отмеченная галочкой. 0.6B — быстрее, 1.7B — точнее.")
        }
    }

    @ViewBuilder
    private func modelRow(_ variant: ModelVariant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(variant.displayName).font(.body)
                        if variant.recommended {
                            Text("рекомендуется")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    statusLine(variant)
                }

                Spacer(minLength: 8)

                HStack(spacing: 14) {
                    controls(variant)
                }
            }

            // Текст ошибки последней загрузки — на всю ширину под строкой.
            if case .failed(let message) = downloader.phase,
               downloader.failedVariantId == variant.id {
                Text("Ошибка: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Удалить \(variant.displayName)?",
            isPresented: .init(
                get: { deleteCandidate == variant },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { delete(variant) }
            Button("Отмена", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("Освободит около \(variant.sizeLabel) на устройстве.")
        }
    }

    @ViewBuilder
    private func statusLine(_ variant: ModelVariant) -> some View {
        // Во время загрузки каталог неполный — не показывать «Повреждена».
        if downloader.isDownloading(variant.id) {
            Text("Загрузка… · \(variant.sizeLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            statusText(variant)
        }
    }

    @ViewBuilder
    private func statusText(_ variant: ModelVariant) -> some View {
        switch states[variant.id] {
        case .some(.ready):
            Text("Готова · \(variant.sizeLabel)")
                .font(.caption)
                .foregroundStyle(.green)
        case .some(.corrupted(let reasons)):
            Text("Повреждена: \(reasons.first ?? "")")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            Text("Не загружена · \(variant.sizeLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(_ variant: ModelVariant) -> some View {
        if downloader.isDownloading(variant.id) {
            HStack(spacing: 10) {
                downloadProgress(variant)
                Button {
                    downloader.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        } else {
            switch states[variant.id] {
            case .some(.ready):
                if activeModelId == variant.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                } else {
                    Button("Выбрать") {
                        select(variant)
                    }
                    .buttonStyle(.borderless)
                }
                // Корзина доступна и у активной модели.
                Button {
                    deleteCandidate = variant
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            case .some(.corrupted):
                // Каталог есть, но комплект битый — дать удалить и начать заново.
                Button {
                    deleteCandidate = variant
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                Button("Скачать") {
                    downloader.start(variant: variant)
                }
                .buttonStyle(.borderless)
            default:
                Button("Скачать") {
                    downloader.start(variant: variant)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func downloadProgress(_ variant: ModelVariant) -> some View {
        let progress: ModelDownloader.Progress? = {
            if case .downloading(let p) = downloader.phase { return p }
            return nil
        }()
        return VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: progress?.fraction ?? 0)
                .frame(width: 90)
            Text(progress.map { "\(Int($0.fraction * 100))%" } ?? "…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func select(_ variant: ModelVariant) {
        activeModelId = variant.id
        // Движок с другой моделью — сброс, перезагрузится при следующей диктовке.
        DictationController.shared.resetEngine()
    }

    private func delete(_ variant: ModelVariant) {
        do {
            try FileManager.default.removeItem(at: ModelStore.variantDirectory(variant))
        } catch {
            errorText = error.localizedDescription
        }
        if activeModelId == variant.id {
            activeModelId = ModelVariant.catalog[0].id
            DictationController.shared.resetEngine()
        }
        refreshStates()
    }

    private func refreshStates() {
        var result: [String: ModelStatus?] = [:]
        for variant in ModelVariant.catalog {
            result[variant.id] = ModelStore().installedState(variant)
        }
        states = result
    }

    // MARK: - Распознавание

    private var recognitionSection: some View {
        Section {
            Stepper("Потоков: \(numThreads)", value: $numThreads, in: 1...8)
                .onChange(of: numThreads) {
                    DictationController.shared.resetEngine()
                }
            Picker("Лимит записи", selection: $maxRecordSeconds) {
                Text("1 мин").tag(60)
                Text("2 мин").tag(120)
                Text("3 мин").tag(180)
                Text("5 мин").tag(300)
            }
        } header: {
            Text("Распознавание")
        } footer: {
            Text("Больше потоков — быстрее распознавание, сильнее нагрев. Лимит — запись остановится сама и распознается.")
        }
    }
}
