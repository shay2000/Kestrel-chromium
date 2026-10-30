import Foundation
#if canImport(PDFKit) && canImport(Vision)
import PDFKit
import Vision
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

/// The bundled Fluent file-type mark selected for an attachment's filename.
/// These names match the corresponding imagesets in the asset catalogue.
enum AttachmentFileMark: String, Equatable, Sendable {
    case word = "AttachmentWord"
    case excel = "AttachmentExcel"
    case powerpoint = "AttachmentPowerPoint"
    case pdf = "AttachmentPDF"
    case image = "AttachmentImage"
    case text = "AttachmentText"
    case generic = "AttachmentGeneric"

    static func forFileExtension(_ fileExtension: String) -> Self {
        switch fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() {
        case "doc", "docm", "docx", "dot", "dotm", "dotx":
            return .word
        case "csv", "tsv", "xls", "xlsb", "xlsm", "xlsx", "xlt", "xltm", "xltx":
            return .excel
        case "pot", "potm", "potx", "pps", "ppsm", "ppsx", "ppt", "pptm", "pptx", "sldm", "sldx":
            return .powerpoint
        case "pdf":
            return .pdf
        case "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return .image
        case "bash", "c", "cjs", "cfg", "conf", "cpp", "cs", "css", "env", "go", "h", "hpp",
             "htm", "html", "ini", "java", "js", "json", "jsonl", "jsx", "kt", "log", "md",
             "markdown", "mjs", "php", "plist", "py", "rb", "rs", "rtf", "sh", "sql", "swift",
             "tex", "text", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh":
            return .text
        default:
            return .generic
        }
    }
}

/// A piece of context the user attaches to the new tab search bar before
/// sending.
///
/// Dia lets you drop files and other tabs into the search field so a question
/// can be asked *against* them. This is the same idea, kept deliberately small:
/// a short label for the source chip and structured request-only context. Text
/// is read locally and sent to the selected provider only with the user's
/// request; it never becomes part of the visible transcript message.
struct NewTabAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case tab

        var symbolName: String {
            switch self {
            case .file: return "doc.text"
            case .tab: return "square.on.square"
            }
        }

        var displayName: String {
            switch self {
            case .file: return "File"
            case .tab: return "Tab"
            }
        }
    }

    /// What the attachment actually carries.
    ///
    /// Text is read locally and becomes bounded provider context. Bytes are handed to the
    /// provider untouched, because a model that can read an image or a PDF
    /// should be given the real thing rather than a local guess at its contents.
    enum Content: Equatable, Sendable {
        case text(String)
        case binary(Data, mimeType: String)
    }

    let id: UUID
    let kind: Kind
    let label: String
    /// Where the material came from, for its provider-context heading.
    let origin: String
    let content: Content

    /// A file attachment's icon is derived from its full original filename;
    /// the visible label may be shortened to fit the chip.
    var fileMark: AttachmentFileMark? {
        guard kind == .file else { return nil }
        return .forFileExtension(URL(fileURLWithPath: origin).pathExtension)
    }

    init(id: UUID = UUID(), kind: Kind, label: String, origin: String, content: Content) {
        self.id = id
        self.kind = kind
        self.label = label
        self.origin = origin
        self.content = content
    }

    init(id: UUID = UUID(), kind: Kind, label: String, origin: String, text: String) {
        self.init(id: id, kind: kind, label: label, origin: origin, content: .text(text))
    }

    /// The locally read text, when this attachment is text.
    var textValue: String? {
        if case .text(let value) = content { return value }
        return nil
    }

    var isBinary: Bool {
        if case .binary = content { return true }
        return false
    }
}

#if canImport(SwiftUI)
/// A compact pointer with rounded tips, shared by both Agent mode controls.
struct AgentModePointer: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 3.3, y: 2.4))
            path.addQuadCurve(to: CGPoint(x: 2.4, y: 3.3), control: CGPoint(x: 1.8, y: 1.8))
            path.addLine(to: CGPoint(x: 5.7, y: 11.1))
            path.addQuadCurve(to: CGPoint(x: 6.8, y: 11.0), control: CGPoint(x: 6.3, y: 12.4))
            path.addLine(to: CGPoint(x: 7.6, y: 8.2))
            path.addQuadCurve(to: CGPoint(x: 8.2, y: 7.6), control: CGPoint(x: 7.7, y: 7.7))
            path.addLine(to: CGPoint(x: 11.0, y: 6.8))
            path.addQuadCurve(to: CGPoint(x: 11.1, y: 5.7), control: CGPoint(x: 12.4, y: 6.3))
            path.closeSubpath()
        }
        .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

enum ComposerAccessoryPalette {
    static let lavender = Color(red: 0.53, green: 0.43, blue: 0.72)
    static let lavenderInk = Color(red: 0.43, green: 0.34, blue: 0.62)

    static func accessoryForeground(isActive: Bool, isDark: Bool) -> Color {
        guard isDark else { return isActive ? lavenderInk : .secondary }
        return isActive
            ? Color(red: 0.82, green: 0.75, blue: 0.98)
            : Color.white.opacity(0.9)
    }

    /// Shared, opaque surface used by the New Tab composer and its suggestion
    /// panel so the dropdown feels like it belongs to the same raised control.
    static func composerSurface(isDark: Bool) -> LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color(red: 0.19, green: 0.18, blue: 0.22), Color(red: 0.16, green: 0.15, blue: 0.19)]
                : [Color(red: 0.999, green: 0.997, blue: 1.0), Color(red: 0.976, green: 0.963, blue: 0.994)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func composerSurfaceEdge(isDark: Bool) -> Color {
        lavender.opacity(isDark ? 0.24 : 0.19)
    }
}

/// Keeps file and tab marks on the same fixed footprint in both composer trays.
struct NewTabAttachmentThumbnail: View {
    let attachment: NewTabAttachment

    var body: some View {
        mark
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    private var mark: Image {
        if let fileMark = attachment.fileMark {
#if SWIFT_PACKAGE
            return Image(fileMark.rawValue, bundle: KestrelAssets.bundle)
#else
            return Image(fileMark.rawValue)
#endif
        }
        return Image(systemName: attachment.kind.symbolName)
    }
}

enum ComposerAccessoryShape {
    case capsule
    case circle
}

/// A quietly raised, almost-white lavender surface for secondary composer
/// actions. Active controls deepen the tint slightly; disabled controls keep
/// their shape but lose most of the lift.
struct ComposerAccessorySurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var isActive = false
    var shape: ComposerAccessoryShape = .capsule

    private var dark: Bool { colorScheme == .dark }
    private var tintOpacity: Double {
        guard isEnabled else { return dark ? 0.12 : 0.035 }
        return isActive ? (dark ? 0.30 : 0.22) : (dark ? 0.26 : 0.115)
    }

    private var fill: LinearGradient {
        let base = dark ? Color(white: 0.28) : Color.white
        let lower = dark
            ? Color(red: 0.30, green: 0.27, blue: 0.35)
            : Color(red: 0.985, green: 0.976, blue: 1.0)
        let active = dark
            ? Color(red: 0.34, green: 0.30, blue: 0.41)
            : Color(red: 0.95, green: 0.925, blue: 0.99)
        return LinearGradient(
            colors: [base, isActive && isEnabled ? active : lower],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func body(content: Content) -> some View {
        content
            .background {
                if shape == .circle {
                    Circle().fill(fill)
                } else {
                    Capsule().fill(fill)
                }
            }
            .overlay { outline }
            .overlay(alignment: .top) { highlight }
            .shadow(
                color: ComposerAccessoryPalette.lavender.opacity(isEnabled ? (dark ? 0.025 : 0.11) : 0.025),
                radius: isEnabled ? 4 : 1,
                x: 0,
                y: isEnabled ? 2 : 0.5
            )
            .shadow(
                color: Color.black.opacity(isEnabled ? (dark ? 0.14 : 0.028) : 0.01),
                radius: 1.5,
                x: 0,
                y: 1
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.18), value: isEnabled)
    }

    @ViewBuilder
    private var outline: some View {
        let line = ComposerAccessoryPalette.lavender.opacity(tintOpacity)
        if shape == .circle {
            Circle().strokeBorder(line, lineWidth: 0.8)
        } else {
            Capsule().strokeBorder(line, lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var highlight: some View {
        let line = Color.white.opacity(dark ? 0.13 : 0.82)
        if shape == .circle {
            Circle().strokeBorder(line, lineWidth: 0.7)
        } else {
            Capsule().strokeBorder(line, lineWidth: 0.7)
        }
    }
}

/// A light, lifted document tile shared by the New Tab and Assistant trays.
/// Its warm white fill and quiet lavender edge avoid looking selected while
/// echoing the curved, raised New Tab composer surface.
struct AttachmentChipSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let dark = colorScheme == .dark
        let lavender = ComposerAccessoryPalette.lavender

        content
            .background {
                shape.fill(
                    LinearGradient(
                        colors: dark
                            ? [Color(white: 0.27), Color(red: 0.29, green: 0.26, blue: 0.34)]
                            : [Color.white, Color(red: 0.986, green: 0.977, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    dark ? lavender.opacity(0.28) : lavender.opacity(0.18),
                    lineWidth: 0.85
                )
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        dark ? Color.white.opacity(0.12) : Color.white.opacity(0.88),
                        lineWidth: 0.7
                    )
                    .padding(0.8)
                    .allowsHitTesting(false)
            }
            .shadow(color: lavender.opacity(dark ? 0.025 : 0.12), radius: dark ? 3 : 5, x: 0, y: 2)
            .shadow(color: Color.black.opacity(dark ? 0.17 : 0.035), radius: 2, x: 0, y: 1)
            .contentShape(shape)
    }
}
#endif

enum NewTabAttachmentError: LocalizedError, Equatable {
    case tooMany(limit: Int)
    case unsupportedFileType(String)
    case unreadableFile(String)
    case emptyFile(String)
    case noPageText(String)
    case fileTooLarge(name: String, limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooMany(let limit):
            return "You can attach up to \(limit) items at once."
        case .unsupportedFileType(let name):
            return "“\(name)” is a file type Kestrel cannot attach. Try an image (PNG, JPEG, GIF, WebP, HEIC), a PDF, a Word, Excel or PowerPoint document, or a text file such as .txt, .md, .csv or .json."
        case .unreadableFile(let name):
            return "Kestrel could not read “\(name)”."
        case .emptyFile(let name):
            return "“\(name)” has no readable text in it."
        case .noPageText(let title):
            return "“\(title)” has no page text yet. Open it once, then try again."
        case .fileTooLarge(let name, let limit):
            let megabytes = Double(limit) / 1_048_576
            return "“\(name)” is larger than the \(String(format: "%.0f", megabytes)) MB Kestrel will send."
        }
    }
}

/// A conservative per-model attachment allowance. Context sizes come from a
/// provider catalogue where possible; unknown routes deliberately get smaller
/// defaults instead of inheriting the six-file ceiling.
struct AttachmentCapacity: Equatable, Sendable {
    let maximumFiles: Int
    let maximumTextCharacters: Int

    static func forModel(provider: AIProviderKind, contextWindow: Int?) -> Self {
        // Foundation Models currently exposes a 4k session window. Instructions,
        // transcript and answer all share it, so local requests get the smallest
        // file and text allowance.
        if provider == .appleLocalModel {
            return Self(maximumFiles: 1, maximumTextCharacters: 1_800)
        }

        if let contextWindow, contextWindow > 0 {
            switch contextWindow {
            case 128_000...:
                return Self(maximumFiles: 6, maximumTextCharacters: 12_000)
            case 32_000..<128_000:
                return Self(maximumFiles: 4, maximumTextCharacters: 8_000)
            case 8_000..<32_000:
                return Self(maximumFiles: 2, maximumTextCharacters: 4_000)
            default:
                return Self(maximumFiles: 1, maximumTextCharacters: 1_800)
            }
        }

        switch provider {
        case .workBuddyCLI, .openRouter, .codexCLI:
            return Self(maximumFiles: 4, maximumTextCharacters: 8_000)
        case .kiloCLI:
            return Self(maximumFiles: 3, maximumTextCharacters: 6_000)
        case .mistral, .googleGemini, .groq, .deepSeek, .xAI, .customOpenAI:
            return Self(maximumFiles: 3, maximumTextCharacters: 6_000)
        case .appleLocalModel:
            return Self(maximumFiles: 1, maximumTextCharacters: 1_800)
        }
    }
}

/// Reads attachments and turns them into the prompt that carries them.
///
/// The budgets here are the point of the type: an attachment is user-chosen
/// content of unknown size, and an unbounded one would quietly blow up the
/// request. Each item is clipped, and the set as a whole is clipped again.
enum NewTabAttachmentBuilder {
    static let maximumAttachments = 6
    static let maximumCharactersPerAttachment = 4_000
    static let maximumTotalCharacters = 12_000
    /// A single binary attachment's ceiling. Kept well under the request sizes
    /// hosted providers accept, so one large scan cannot make every later
    /// request fail with an opaque server error.
    static let maximumBinaryBytes = 8 * 1_048_576

    /// Used when the user attaches material but types no question of their own.
    static let defaultQuestion = "Summarise the attached context."

    /// Extensions Kestrel reads locally as plain text.
    static let readableTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "yml",
        "yaml", "xml", "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx",
        "jsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp",
        "hpp", "cs", "php", "sh", "zsh", "bash", "toml", "ini", "cfg", "conf",
        "env", "log", "sql", "rtf", "plist", "tex"
    ]

    /// Extensions passed through to the provider as raw bytes.
    ///
    /// Kept to formats a hosted chat endpoint actually accepts as content parts:
    /// the common image types, and PDF. Anything else is refused with an
    /// explanation rather than sent as bytes the far end will reject.
    static let passThroughTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
        "heif": "image/heif",
        "bmp": "image/bmp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "pdf": "application/pdf"
    ]

    static func isReadableFile(_ url: URL) -> Bool {
        readableTextExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPassThroughFile(_ url: URL) -> Bool {
        passThroughTypes[url.pathExtension.lowercased()] != nil
    }

    /// Word, Excel and PowerPoint documents, read by extracting their text.
    static func isOfficeFile(_ url: URL) -> Bool {
        OfficeDocumentText.supports(url)
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        isReadableFile(url) || isPassThroughFile(url) || isOfficeFile(url)
    }

    /// A chip label short enough to sit in a row of chips.
    static func label(forFileAt url: URL, limit: Int = 26) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Untitled" }
        guard name.count > limit else { return name }
        return String(name.prefix(max(1, limit - 1))) + "…"
    }

    /// Reads one file into an attachment.
    ///
    /// Text keeps its line breaks — unlike page snapshots, which are collapsed —
    /// because code and tables lose their meaning without them. Images and PDFs
    /// are carried as bytes for a provider that can read them.
    static func attachment(
        forFileAt url: URL,
        existingCount: Int = 0
    ) throws -> NewTabAttachment {
        guard existingCount < maximumAttachments else {
            throw NewTabAttachmentError.tooMany(limit: maximumAttachments)
        }
        let name = url.lastPathComponent.isEmpty ? "Untitled" : url.lastPathComponent
        let label = label(forFileAt: url)

        if let mimeType = passThroughTypes[url.pathExtension.lowercased()] {
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw NewTabAttachmentError.unreadableFile(name)
            }
            guard !data.isEmpty else {
                throw NewTabAttachmentError.emptyFile(name)
            }
            guard data.count <= maximumBinaryBytes else {
                throw NewTabAttachmentError.fileTooLarge(name: name, limit: maximumBinaryBytes)
            }
            return NewTabAttachment(
                kind: .file,
                label: label,
                origin: name,
                content: .binary(data, mimeType: mimeType)
            )
        }

        guard isReadableFile(url) else {
            guard isOfficeFile(url) else {
                throw NewTabAttachmentError.unsupportedFileType(name)
            }
            // Office documents are ZIP archives of XML, which no chat endpoint
            // reads directly. Extract the text here so the document works with
            // every provider rather than only a hosted one.
            let extracted = try OfficeDocumentText.text(at: url)
            return NewTabAttachment(
                kind: .file,
                label: label,
                origin: name,
                content: .text(clipped(extracted, limit: maximumCharactersPerAttachment))
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw NewTabAttachmentError.unreadableFile(name)
        }

        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NewTabAttachmentError.emptyFile(name)
        }

        return NewTabAttachment(
            kind: .file,
            label: label,
            origin: name,
            content: .text(clipped(trimmed, limit: maximumCharactersPerAttachment))
        )
    }

    /// Builds an attachment from another tab's visible text.
    static func attachment(
        forTabTitle title: String,
        url: String,
        text: String,
        existingCount: Int = 0
    ) throws -> NewTabAttachment {
        guard existingCount < maximumAttachments else {
            throw NewTabAttachmentError.tooMany(limit: maximumAttachments)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NewTabAttachmentError.noPageText(title)
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = url.isEmpty ? (name.isEmpty ? "Untitled tab" : name)
                                 : (name.isEmpty ? url : "\(name) — \(url)")
        return NewTabAttachment(
            kind: .tab,
            label: clipped(name.isEmpty ? url : name, limit: 26),
            origin: origin,
            content: .text(clipped(trimmed, limit: maximumCharactersPerAttachment))
        )
    }

    /// Hands bounded attachment data to the provider layer. File contents stay
    /// in this request and are never pasted into the visible user message.
    static func requestAttachments(
        from attachments: [NewTabAttachment],
        maximumTotalCharacters: Int = Self.maximumTotalCharacters
    ) -> [AIRequestAttachment] {
        var remaining = max(
            0,
            min(Self.maximumTotalCharacters, maximumTotalCharacters)
                - AIRequest.attachmentSafetyPreamble.count
        )
        var hasIncludedAttachment = false
        return attachments.compactMap { attachment in
            let origin = clipped(attachment.origin, limit: 512)
            let separatorCount = hasIncludedAttachment ? 2 : 0
            switch attachment.content {
            case .text(let value):
                let heading = "--- \(attachment.kind.displayName): \(origin) ---\n"
                guard remaining >= heading.count + separatorCount else { return nil }
                let allowance = max(0, min(
                    maximumCharactersPerAttachment,
                    remaining - heading.count - separatorCount
                ))
                let bounded = clipped(value, limit: allowance)
                remaining = max(0, remaining - heading.count - separatorCount - bounded.count)
                hasIncludedAttachment = true
                return AIRequestAttachment(
                    label: attachment.label,
                    origin: origin,
                    kind: attachment.kind,
                    content: .text(bounded)
                )
            case .binary(let data, let mimeType):
                let heading = "--- \(attachment.kind.displayName): \(origin) (attached file) ---"
                guard remaining >= heading.count + separatorCount else { return nil }
                remaining -= heading.count + separatorCount
                hasIncludedAttachment = true
                return AIRequestAttachment(
                    label: attachment.label,
                    origin: origin,
                    kind: attachment.kind,
                    content: .binary(data, mimeType: mimeType)
                )
            }
        }
    }

    /// Text-only providers receive a local PDF extraction rather than unusable
    /// raw bytes. Hosted PDF support retains the original document and visuals.
    /// Called off the main actor; no temporary files or network requests.
    static func readableAttachments(
        _ attachments: [AIRequestAttachment], provider: AIProviderKind,
        maximumTotalCharacters: Int = Self.maximumTotalCharacters,
        pdfExtractor: ((Data, String, Int) throws -> String)? = nil
    ) throws -> [AIRequestAttachment] {
        guard provider != .openRouter, !attachments.isEmpty else { return attachments }
        let limit = max(0, min(Self.maximumTotalCharacters, maximumTotalCharacters))
        func isPDF(_ attachment: AIRequestAttachment) -> Bool {
            if case .binary(_, let mime) = attachment.content { return mime == "application/pdf" }
            return false
        }
        let headings = attachments.map { attachment -> String in
            if attachment.isBinary && !isPDF(attachment) {
                return "--- \(attachment.kind.displayName): \(attachment.origin) (attached file) ---"
            }
            return "--- \(attachment.kind.displayName): \(attachment.origin) ---\n"
        }
        let overhead = AIRequest.attachmentSafetyPreamble.count + headings.reduce(0) { $0 + $1.count }
            + max(0, attachments.count - 1) * 2
        guard overhead <= limit else { throw NewTabAttachmentError.emptyFile("Attachments (text budget exhausted)") }
        var remaining = limit - overhead
        var slots = attachments.filter { !$0.isBinary || isPDF($0) }.count
        let extract = pdfExtractor ?? { try pdfText(data: $0, name: $1, limit: $2) }
        return try attachments.map { attachment in
            var result = attachment
            guard !attachment.isBinary || isPDF(attachment) else { return result }
            let allowance = remaining / max(1, slots)
            let text: String
            if case .binary(let data, _) = attachment.content {
                guard allowance > 200 else { throw NewTabAttachmentError.emptyFile(attachment.origin + " (attachment text budget exhausted)") }
                text = try extract(data, attachment.origin, allowance)
            } else if case .text(let value) = attachment.content { text = value }
            else { text = "" }
            let bounded = clipped(text, limit: allowance)
            result.content = .text(bounded)
            remaining -= bounded.count
            slots -= 1
            return result
        }
    }

    static func pdfText(data: Data, name: String, limit: Int) throws -> String {
#if canImport(PDFKit) && canImport(Vision)
        guard data.count <= maximumBinaryBytes, let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount > 0 else { throw NewTabAttachmentError.unreadableFile(name) }
        let notice = "[PDF extracted locally. Text only: embedded images, diagrams and layout are not supplied. OCR may contain errors.]\n"
        var output = notice
        var foundText = false
        let pageLimit = min(document.pageCount, 20)
        for index in 0..<pageLimit {
            guard output.count < limit - 100, let page = document.page(at: index) else { break }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Scans have no selectable text. Bound rasterisation and OCR to the
            // first eight pages and 1400 pixels, with no external OCR service.
            if text.isEmpty, index < 8 {
                let bounds = page.bounds(for: .mediaBox)
                if bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite {
                    let scale = min(1, 1400 / max(bounds.width, bounds.height))
                    let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    var rect = CGRect(origin: .zero, size: image.size)
                    if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        try VNImageRequestHandler(cgImage: cgImage).perform([request])
                        text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    }
                }
            }
            guard !text.isEmpty else {
                output += "\n[Page \(index + 1): no readable text; visual content unavailable.]\n"
                continue
            }
            foundText = true
            output += "\n--- Page \(index + 1) ---\n" + clipped(text, limit: max(0, limit - output.count - 100))
        }
        guard foundText else { throw NewTabAttachmentError.emptyFile(name + " (PDF has no extractable text; use a model that accepts the original PDF for visual content)") }
        if document.pageCount > pageLimit || output.count >= limit - 100 {
            output += "\n[Partial document: page or text limit reached.]"
        }
        return clipped(output, limit: limit)
#else
        throw NewTabAttachmentError.unreadableFile(name + " (local PDF extraction requires macOS)")
#endif
    }

    /// Returns only the user's question. An attachment by itself still needs a
    /// useful prompt, but its contents stay in the structured source payload.
    static func question(_ query: String, attachments: [NewTabAttachment]) -> String {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.isEmpty, !attachments.isEmpty else { return question }
        return defaultQuestion
    }

    /// Clips while preserving line breaks, marking the cut so the model knows
    /// the material is partial.
    static func clipped(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[text.startIndex..<end]) + "…"
    }

    #if canImport(UniformTypeIdentifiers)
    /// The types the open panel offers.
    ///
    /// Built from the same policy the reader applies, so the picker can never
    /// offer a file Kestrel would then refuse — the user finds out what is
    /// supported by what they can select, not by an error after the fact.
    ///
    /// The exact image, PDF, Office and supported text extensions are listed.
    /// Some text extensions resolve to dynamic Uniform Type Identifiers on this
    /// Mac and do not conform to a generic text family, so offering only a
    /// family silently hides files the reader can handle.
    static func selectableContentTypes() -> [UTType] {
        var types: [UTType] = []

        for fileExtension in passThroughTypes.keys.sorted() {
            if let type = UTType(filenameExtension: fileExtension) {
                types.append(type)
            }
        }
        for fileExtension in (OfficeDocumentText.supportedExtensions.union(readableTextExtensions)).sorted() {
            if let type = UTType(filenameExtension: fileExtension) {
                types.append(type)
            }
        }

        // De-duplicate: several extensions map onto the same type, and a
        // repeated type in an open panel produces a duplicated filter entry.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }
    #endif
}
