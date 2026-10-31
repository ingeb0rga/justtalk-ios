//
//  ModelStore.swift
//  JustTalk
//
//  Каталог моделей (Qwen3-ASR, GigaAM v3, Whisper large-v3-turbo) и проверка
//  комплекта файлов. Поиск Qwen3, скопированной через Finder, — порт
//  detectModelConfig из Android JustTalk (LocalTranscriber.kt).
//

import Foundation

/// Движок sherpa-onnx, которым грузится модель.
nonisolated enum ModelEngine: Sendable {
    /// Qwen3-ASR: conv_frontend + encoder + decoder + tokenizer/.
    case qwen3
    /// NeMo RNN-T (GigaAM v3): encoder + decoder + joiner + tokens.txt.
    case nemoTransducer
    /// Whisper: encoder + decoder + tokens.txt; окно 30 с.
    case whisper

    /// Предел длины куска для одного decode, с: длинную запись режем
    /// по паузам (Whisper видит только 30 с, GigaAM обучена на коротких
    /// фрагментах). nil — модель берёт запись целиком.
    var maxChunkSeconds: Double? {
        switch self {
        case .qwen3: nil
        case .nemoTransducer: 25
        case .whisper: 28
        }
    }
}

/// Роль файла в комплекте модели.
nonisolated enum ModelRole: String, Sendable {
    case convFrontend, encoder, decoder, joiner, tokens, tokenizer
}

/// Найденный комплект файлов модели.
nonisolated struct ModelFiles: Sendable {
    let engine: ModelEngine
    let directory: URL
    let roles: [ModelRole: URL]

    func url(_ role: ModelRole) -> URL {
        roles[role] ?? directory
    }

    /// Веса (.onnx) — для оценки памяти движка.
    var onnxFiles: [URL] {
        roles.values.filter { $0.pathExtension == "onnx" }
    }
}

enum ModelStatus {
    /// Модель не найдена ни в одном из каталогов поиска.
    case notFound
    /// Каталог есть, но файлы обрезаны/неполны — грузить нельзя.
    case corrupted(reasons: [String])
    /// Модель найдена и прошла проверку размеров.
    case ready(ModelFiles)
}

/// Вариант модели в каталоге загрузчика (этап 7).
/// Все варианты качаются поштучно с HuggingFace — архивов и bzip2 нет.
nonisolated struct ModelVariant: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let engine: ModelEngine
    /// Имя каталога внутри Documents/models/.
    let directoryName: String
    /// HuggingFace repo: https://huggingface.co/<repo>/resolve/main/<file>.
    let hfRepo: String
    let sizeLabel: String
    let recommended: Bool
    /// Роль → путь относительно каталога модели.
    let roles: [ModelRole: String]
    /// Все файлы для загрузки (относительно каталога модели).
    let downloadFiles: [String]
    /// Минимальный размер файла роли, МБ: обрезанный onnx проходит
    /// «по наличию», но валит процесс нативно.
    let minMegabytes: [ModelRole: Int]

    static func == (a: ModelVariant, b: ModelVariant) -> Bool { a.id == b.id }

    private static let qwen3Roles: [ModelRole: String] = [
        .convFrontend: "conv_frontend.onnx",
        .encoder: "encoder.int8.onnx",
        .decoder: "decoder.int8.onnx",
        .tokenizer: "tokenizer",
    ]
    private static let qwen3Files = [
        "conv_frontend.onnx",
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "tokenizer/merges.txt",
        "tokenizer/vocab.json",
        "tokenizer/tokenizer_config.json",
    ]
    private static let qwen3Min: [ModelRole: Int] = [.convFrontend: 20, .encoder: 50, .decoder: 200]

    nonisolated static let catalog: [ModelVariant] = [
        ModelVariant(
            id: "qwen3-0.6b", displayName: "Qwen3-ASR 0.6B", engine: .qwen3,
            directoryName: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            hfRepo: "ilmina/qwen3-asr-0.6b-sherpa-onnx",
            sizeLabel: "≈0,8 ГБ", recommended: true,
            roles: qwen3Roles, downloadFiles: qwen3Files, minMegabytes: qwen3Min
        ),
        ModelVariant(
            id: "qwen3-1.7b", displayName: "Qwen3-ASR 1.7B", engine: .qwen3,
            directoryName: "sherpa-onnx-qwen3-asr-1.7B-int8",
            hfRepo: "ilmina/qwen3-asr-1.7b-sherpa-onnx",
            sizeLabel: "≈2,3 ГБ", recommended: false,
            roles: qwen3Roles, downloadFiles: qwen3Files, minMegabytes: qwen3Min
        ),
        // GigaAM v3 E2E RNN-T (Сбер, MIT): пунктуация и регистр, только русский.
        // sherpa-onnx nemo_transducer; зеркало amidexe/govorun-lite model-gigaam-v3.
        ModelVariant(
            id: "gigaam-v3", displayName: "GigaAM v3 (только русский)", engine: .nemoTransducer,
            directoryName: "gigaam-v3-e2e-rnnt",
            hfRepo: "pantinor/gigaam-v3",
            sizeLabel: "≈0,33 ГБ", recommended: false,
            roles: [
                .encoder: "gigaam_v3_e2e_rnnt_encoder_int8.onnx",
                .decoder: "gigaam_v3_e2e_rnnt_decoder.onnx",
                .joiner: "gigaam_v3_e2e_rnnt_joint.onnx",
                .tokens: "gigaam_v3_e2e_rnnt_tokens.txt",
            ],
            downloadFiles: [
                "gigaam_v3_e2e_rnnt_encoder_int8.onnx",
                "gigaam_v3_e2e_rnnt_decoder.onnx",
                "gigaam_v3_e2e_rnnt_joint.onnx",
                "gigaam_v3_e2e_rnnt_tokens.txt",
            ],
            minMegabytes: [.encoder: 250, .decoder: 1, .joiner: 1]
        ),
        // Whisper large-v3-turbo int8 (99 языков, пунктуация). Окно 30 с —
        // длинные записи режутся по паузам (SherpaTranscriber).
        ModelVariant(
            id: "whisper-turbo", displayName: "Whisper large-v3-turbo", engine: .whisper,
            directoryName: "sherpa-onnx-whisper-turbo",
            hfRepo: "csukuangfj/sherpa-onnx-whisper-turbo",
            sizeLabel: "≈1,0 ГБ", recommended: false,
            roles: [
                .encoder: "turbo-encoder.int8.onnx",
                .decoder: "turbo-decoder.int8.onnx",
                .tokens: "turbo-tokens.txt",
            ],
            downloadFiles: [
                "turbo-encoder.int8.onnx",
                "turbo-decoder.int8.onnx",
                "turbo-tokens.txt",
            ],
            minMegabytes: [.encoder: 500, .decoder: 250]
        ),
    ]
}

/// Активная модель (выбор в Настройках) + настройки распознавания.
nonisolated enum TranscriptionSettings {
    nonisolated static let activeModelKey = "activeModelId"
    nonisolated static let numThreadsKey = "numThreads"
    nonisolated static let maxRecordSecondsKey = "maxRecordSeconds"

    nonisolated static var activeVariant: ModelVariant {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: activeModelKey) ?? ModelVariant.catalog[0].id
        return ModelVariant.catalog.first { $0.id == id } ?? ModelVariant.catalog[0]
    }

    nonisolated static var numThreads: Int {
        let v = UserDefaults.standard.integer(forKey: numThreadsKey)
        return (1...8).contains(v) ? v : 6
    }
}

struct ModelStore {
    /// Каталоги поиска моделей: Documents (копирование через Finder,
    /// включён UIFileSharingEnabled) и Application Support (будущий
    /// загрузчик, этап 7). Поиск рекурсивный — модель может лежать
    /// и в models/, и прямо в корне, и во вложенном каталоге архива.
    var searchRoots: [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documents)
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupport)
        }
        return roots
    }

    /// Ищет модель Qwen3 во всех корнях (рекурсивно, до 3 уровней вложенности).
    /// Возвращает статус и, если найдено достаточно файлов, комплект файлов
    /// (для показа причин «повреждена»).
    func probeQwen3() -> (status: ModelStatus, files: ModelFiles?) {
        var best: (reasons: [String], files: ModelFiles?) = (["нет каталога"], nil)

        for root in searchRoots {
            if let files = findQwen3(below: root, depth: 0) {
                let reasons = validate(files, minMegabytes: [.convFrontend: 20, .encoder: 50, .decoder: 200])
                if reasons.isEmpty {
                    return (.ready(files), files)
                }
                if best.files == nil || reasons.count < best.reasons.count {
                    best = (reasons, files)
                }
            }
        }
        if let files = best.files {
            return (.corrupted(reasons: best.reasons), files)
        }
        return (.notFound, nil)
    }

    /// Обход каталога вглубь: сначала сам каталог, потом подкаталоги (глубина ≤ 3).
    private func findQwen3(below directory: URL, depth: Int) -> ModelFiles? {
        if let files = Self.detectQwen3Files(in: directory) { return files }
        guard depth < 3 else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        for child in entries
        where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let files = findQwen3(below: child, depth: depth + 1) { return files }
        }
        return nil
    }

    // MARK: - Каталог загрузчика (этап 7)

    /// Корень загрузчика: Documents/models.
    nonisolated static func modelsRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("models", isDirectory: true)
    }

    /// Каталог конкретного варианта: Documents/models/<directoryName>.
    nonisolated static func variantDirectory(_ variant: ModelVariant) -> URL {
        modelsRoot().appendingPathComponent(variant.directoryName, isDirectory: true)
    }

    /// Статус конкретного варианта (загрузчик): nil — каталога нет вовсе.
    func installedState(_ variant: ModelVariant) -> ModelStatus? {
        let dir = Self.variantDirectory(variant)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        var roles: [ModelRole: URL] = [:]
        var missing: [String] = []
        for (role, path) in variant.roles {
            let url = dir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                roles[role] = url
            } else {
                missing.append(path)
            }
        }
        if !missing.isEmpty {
            return .corrupted(reasons: missing.sorted().map { "нет файла \($0)" })
        }
        let files = ModelFiles(engine: variant.engine, directory: dir, roles: roles)
        let reasons = validate(files, minMegabytes: variant.minMegabytes)
        return reasons.isEmpty ? .ready(files) : .corrupted(reasons: reasons)
    }

    /// Обнаружение Qwen3 по составу файлов: `conv_frontend*` + `encoder*` +
    /// `decoder*` + каталог `tokenizer/` (без tokens.txt в корне).
    nonisolated static func detectQwen3Files(in directory: URL) -> ModelFiles? {
        guard let convFrontend = Self.findFile(in: directory, prefix: "conv_frontend") else { return nil }
        guard let encoder = Self.findFile(in: directory, prefix: "encoder") else { return nil }
        guard let decoder = Self.findFile(in: directory, prefix: "decoder") else { return nil }
        let tokenizer = directory.appendingPathComponent("tokenizer", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tokenizer.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return ModelFiles(engine: .qwen3, directory: directory, roles: [
            .convFrontend: convFrontend,
            .encoder: encoder,
            .decoder: decoder,
            .tokenizer: tokenizer,
        ])
    }

    /// Проверка минимальных размеров — обрезанный onnx проходит «по наличию»,
    /// но валит процесс нативно (Ort::Exception / SIGABRT на Android).
    func validate(_ files: ModelFiles, minMegabytes: [ModelRole: Int]) -> [String] {
        var reasons: [String] = []
        for (role, minMb) in minMegabytes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let url = files.url(role)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            if size < minMb * 1024 * 1024 {
                reasons.append("\(url.lastPathComponent): \(size / 1024 / 1024) МБ < \(minMb) МБ")
            }
        }
        return reasons
    }

    /// Диагностика для экрана «не найдена»: что видно в корнях поиска
    /// (до 12 имён в каждом).
    func diagnostics() -> String {
        let fm = FileManager.default
        var lines: [String] = []
        for root in searchRoots {
            let entries = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            let names = entries.prefix(12).map { entry -> String in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return isDir ? entry.lastPathComponent + "/" : entry.lastPathComponent
            }
            lines.append("\(root.lastPathComponent): "
                         + (names.isEmpty ? "(пусто)" : names.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    /// Первый файл с префиксом; предпочитает int8-квантование (порт findFile()
    /// из LocalTranscriber.kt).
    static func findFile(in directory: URL, prefix: String) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let candidates = contents.filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && ($0.pathExtension == "onnx" || $0.pathExtension == "ort")
        }
        return candidates.first { $0.lastPathComponent.contains("int8") } ?? candidates.first
    }
}
