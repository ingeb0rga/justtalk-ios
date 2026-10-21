//
//  ModelStore.swift
//  JustTalk
//
//  Порт ModelDownloader.isInstalled и detectModelConfig (ветка Qwen3)
//  из Android JustTalk (LocalTranscriber.kt / ModelDownloader.kt).
//

import Foundation

/// Найденный комплект файлов модели Qwen3-ASR.
struct Qwen3ModelFiles {
    let directory: URL
    let convFrontend: URL
    let encoder: URL
    let decoder: URL
    let tokenizer: URL
}

enum ModelStatus {
    /// Модель не найдена ни в одном из каталогов поиска.
    case notFound
    /// Каталог есть, но файлы обрезаны/неполны — грузить нельзя.
    case corrupted(reasons: [String])
    /// Модель найдена и прошла проверку размеров.
    case ready(Qwen3ModelFiles)
}

/// Вариант модели в каталоге загрузчика (этап 7).
/// Все варианты качаются поштучно с HuggingFace — архивов и bzip2 нет.
struct ModelVariant: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// Имя каталога внутри Documents/models/.
    let directoryName: String
    /// HuggingFace repo: https://huggingface.co/<repo>/resolve/main/<file>.
    let hfRepo: String
    let sizeLabel: String
    let recommended: Bool

    nonisolated static let catalog: [ModelVariant] = [
        ModelVariant(
            id: "qwen3-0.6b", displayName: "Qwen3-ASR 0.6B",
            directoryName: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            hfRepo: "ilmina/qwen3-asr-0.6b-sherpa-onnx",
            sizeLabel: "≈0,8 ГБ", recommended: true
        ),
        ModelVariant(
            id: "qwen3-1.7b", displayName: "Qwen3-ASR 1.7B",
            directoryName: "sherpa-onnx-qwen3-asr-1.7B-int8",
            hfRepo: "ilmina/qwen3-asr-1.7b-sherpa-onnx",
            sizeLabel: "≈2,3 ГБ", recommended: false
        ),
    ]

    /// Файлы комплекта относительно каталога модели.
    nonisolated static let modelFiles = [
        "conv_frontend.onnx",
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "tokenizer/merges.txt",
        "tokenizer/vocab.json",
        "tokenizer/tokenizer_config.json",
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
    func probeQwen3() -> (status: ModelStatus, files: Qwen3ModelFiles?) {
        var best: (reasons: [String], files: Qwen3ModelFiles?) = (["нет каталога"], nil)

        for root in searchRoots {
            if let files = findQwen3(below: root, depth: 0) {
                let reasons = validate(files)
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
    private func findQwen3(below directory: URL, depth: Int) -> Qwen3ModelFiles? {
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
        guard let files = Self.detectQwen3Files(in: dir) else {
            return .corrupted(reasons: ["нет комплекта файлов"])
        }
        let reasons = validate(files)
        return reasons.isEmpty ? .ready(files) : .corrupted(reasons: reasons)
    }

    /// Обнаружение Qwen3 по составу файлов: `conv_frontend*` + `encoder*` +
    /// `decoder*` + каталог `tokenizer/` (без tokens.txt в корне).
    nonisolated static func detectQwen3Files(in directory: URL) -> Qwen3ModelFiles? {
        guard let convFrontend = Self.findFile(in: directory, prefix: "conv_frontend") else { return nil }
        guard let encoder = Self.findFile(in: directory, prefix: "encoder") else { return nil }
        guard let decoder = Self.findFile(in: directory, prefix: "decoder") else { return nil }
        let tokenizer = directory.appendingPathComponent("tokenizer", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tokenizer.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return Qwen3ModelFiles(
            directory: directory,
            convFrontend: convFrontend,
            encoder: encoder,
            decoder: decoder,
            tokenizer: tokenizer
        )
    }

    /// Проверка минимальных размеров — обрезанный onnx проходит «по наличию»,
    /// но валит процесс нативно (Ort::Exception / SIGABRT на Android).
    func validate(_ files: Qwen3ModelFiles) -> [String] {
        var reasons: [String] = []
        func check(_ url: URL, minMb: Int) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < minMb * 1024 * 1024 {
                reasons.append("\(url.lastPathComponent): \(size / 1024 / 1024) МБ < \(minMb) МБ")
            }
        }
        check(files.convFrontend, minMb: 20)
        check(files.encoder, minMb: 50)
        check(files.decoder, minMb: 200)
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
