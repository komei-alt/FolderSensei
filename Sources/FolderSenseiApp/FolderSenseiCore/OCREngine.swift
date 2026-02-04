import Foundation
import Vision
import AppKit
import PDFKit
import CoreImage

// MARK: - OCR エンジン (Vision.framework)

/// 画像・PDF からテキストを高精度に抽出する
public final class OCREngine {

    /// OCR の結果
    public struct Result: Sendable {
        /// 抽出されたテキスト全文
        public let text: String
        /// 各認識ブロックの信頼度 (0.0〜1.0)
        public let observations: [(text: String, confidence: Float)]
        /// 平均信頼度
        public var averageConfidence: Float {
            guard !observations.isEmpty else { return 0 }
            return observations.map(\.confidence).reduce(0, +) / Float(observations.count)
        }
    }

    /// OCR 設定
    public struct Configuration: Sendable {
        /// 認識対象の言語 (優先順)
        public var languages: [String]
        /// 最低信頼度 (これ以下の結果は除外)
        public var minimumConfidence: Float
        /// 低品質画像の前処理を有効化
        public var enablePreprocessing: Bool

        public init(
            languages: [String] = ["ja", "en"],
            minimumConfidence: Float = 0.3,
            enablePreprocessing: Bool = true
        ) {
            self.languages = languages
            self.minimumConfidence = minimumConfidence
            self.enablePreprocessing = enablePreprocessing
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// ファイルURLからテキストを抽出
    public func extractText(from fileURL: URL) async throws -> Result {
        let ext = fileURL.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try await extractFromPDF(url: fileURL)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "webp":
            return try await extractFromImage(url: fileURL)
        case "txt", "md", "csv", "json", "xml", "html":
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            return Result(text: text, observations: [(text, 1.0)])
        default:
            return Result(text: "", observations: [])
        }
    }

    // MARK: - 画像 OCR

    private func extractFromImage(url: URL) async throws -> Result {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageLoadFailed(url)
        }

        // 1st pass: そのまま OCR
        var result = try await performOCR(on: cgImage)

        // 2nd pass: 信頼度が低ければ前処理してリトライ
        if configuration.enablePreprocessing && result.averageConfidence < 0.5 {
            if let enhanced = preprocessImage(cgImage) {
                let retryResult = try await performOCR(on: enhanced)
                if retryResult.averageConfidence > result.averageConfidence {
                    result = retryResult
                }
            }
        }

        return result
    }

    // MARK: - PDF OCR

    private func extractFromPDF(url: URL) async throws -> Result {
        guard let document = PDFDocument(url: url) else {
            throw OCRError.pdfLoadFailed(url)
        }

        var allText = ""
        var allObservations: [(String, Float)] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            // まずテキストレイヤーを試す
            if let pageText = page.string, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                allText += pageText + "\n"
                allObservations.append((pageText, 1.0))
            } else {
                // テキストレイヤーがない → ページを画像化して OCR
                let pageRect = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0 // 高解像度化で OCR 精度向上
                let width = Int(pageRect.width * scale)
                let height = Int(pageRect.height * scale)

                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                ) else { continue }

                context.scaleBy(x: scale, y: scale)

                // 白背景で描画
                context.setFillColor(.white)
                context.fill(CGRect(origin: .zero, size: pageRect.size))

                // PDF ページを描画
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                page.draw(with: .mediaBox, to: context)
                NSGraphicsContext.restoreGraphicsState()

                if let cgImage = context.makeImage() {
                    let ocrResult = try await performOCR(on: cgImage)
                    allText += ocrResult.text + "\n"
                    allObservations.append(contentsOf: ocrResult.observations)
                }
            }
        }

        return Result(text: allText, observations: allObservations)
    }

    // MARK: - Vision OCR 実行

    private func performOCR(on image: CGImage) async throws -> Result {
        let config = self.configuration
        return try await withCheckedThrowingContinuation { continuation in
            // Vision の同期処理をバックグラウンドスレッドで実行
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: Result(text: "", observations: []))
                        return
                    }

                    let minConf = config.minimumConfidence
                    var texts: [(String, Float)] = []

                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let confidence = candidate.confidence
                        if confidence >= minConf {
                            texts.append((candidate.string, confidence))
                        }
                    }

                    let fullText = texts.map(\.0).joined(separator: "\n")
                    continuation.resume(returning: Result(text: fullText, observations: texts))
                }

                request.recognitionLevel = .accurate
                request.recognitionLanguages = config.languages
                request.usesLanguageCorrection = true

                if #available(macOS 14.0, *) {
                    request.revision = VNRecognizeTextRequestRevision3
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 画像前処理 (OCR精度向上)

    /// CIFilter を使用してスキャン画像の品質を改善
    private func preprocessImage(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext()

        var processed = ciImage

        // 1. コントラスト強化
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(1.2, forKey: kCIInputContrastKey)    // コントラスト強化
            filter.setValue(0.05, forKey: kCIInputBrightnessKey) // 若干明るく
            if let output = filter.outputImage {
                processed = output
            }
        }

        // 2. シャープネス強化
        if let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(0.5, forKey: kCIInputSharpnessKey)
            if let output = filter.outputImage {
                processed = output
            }
        }

        // 3. ノイズ除去
        if let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(0.02, forKey: "inputNoiseLevel")
            filter.setValue(0.4, forKey: "inputSharpness")
            if let output = filter.outputImage {
                processed = output
            }
        }

        return context.createCGImage(processed, from: processed.extent)
    }
}

// MARK: - Errors

public enum OCRError: LocalizedError {
    case imageLoadFailed(URL)
    case pdfLoadFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url): return "画像の読み込みに失敗: \(url.lastPathComponent)"
        case .pdfLoadFailed(let url): return "PDFの読み込みに失敗: \(url.lastPathComponent)"
        }
    }
}
