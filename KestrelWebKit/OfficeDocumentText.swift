import Foundation

#if canImport(Compression)
import Compression
#endif

/// Minimal reader for the ZIP container the Microsoft Office formats use.
///
/// `.docx`, `.xlsx` and `.pptx` are ZIP archives of XML. Kestrel is not trying
/// to be a general unzip tool: it reads the central directory, pulls out the
/// handful of parts it needs, and bounds everything it inflates. Nothing is
/// written to disk.
enum ZipArchiveError: LocalizedError, Equatable {
    case notAnArchive
    case missingPart(String)
    case unsupportedCompression(UInt16)
    case partTooLarge(String)
    case damagedArchive

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "That file is not a readable Office document."
        case .missingPart(let name):
            return "That Office document is missing its \(name) part."
        case .unsupportedCompression(let method):
            return "That Office document uses a compression method Kestrel cannot read (\(method))."
        case .partTooLarge(let name):
            return "The \(name) part of that Office document is too large to read."
        case .damagedArchive:
            return "That Office document appears to be damaged."
        }
    }
}

struct ZipArchive {
    struct Entry: Equatable {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    static let storedMethod: UInt16 = 0
    static let deflatedMethod: UInt16 = 8

    /// The largest single entry Kestrel will inflate. A document part far larger
    /// than this is not something anyone wants pasted into a chat request.
    static let maximumEntryBytes = 24 * 1_048_576
    /// The largest number of entries Kestrel will consider.
    static let maximumEntries = 4_096

    private let bytes: [UInt8]

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    /// Reads the central directory. Returns an empty list when the file is not a
    /// ZIP archive at all, which is how a mislabelled file is detected.
    func entries() -> [Entry] {
        guard let endOffset = endOfCentralDirectoryOffset() else { return [] }
        let declared = Int(readUInt16(endOffset + 10) ?? 0)
        var cursor = Int(readUInt32(endOffset + 16) ?? 0)
        let total = min(declared, Self.maximumEntries)

        var result: [Entry] = []
        result.reserveCapacity(total)
        for _ in 0..<total {
            guard readUInt32(cursor) == Self.centralFileHeaderSignature else { break }
            let method = readUInt16(cursor + 10) ?? 0
            let compressedSize = Int(readUInt32(cursor + 20) ?? 0)
            let uncompressedSize = Int(readUInt32(cursor + 24) ?? 0)
            let nameLength = Int(readUInt16(cursor + 28) ?? 0)
            let extraLength = Int(readUInt16(cursor + 30) ?? 0)
            let commentLength = Int(readUInt16(cursor + 32) ?? 0)
            let localOffset = Int(readUInt32(cursor + 42) ?? 0)

            guard let name = string(at: cursor + 46, length: nameLength) else { break }
            result.append(
                Entry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    func entry(named name: String) -> Entry? {
        entries().first { $0.name == name }
    }

    /// Inflates one entry.
    ///
    /// Sizes come from the central directory rather than the local header,
    /// because a streamed archive leaves the local sizes at zero.
    func contents(of entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maximumEntryBytes else {
            throw ZipArchiveError.partTooLarge(entry.name)
        }
        guard readUInt32(entry.localHeaderOffset) == Self.localFileHeaderSignature else {
            throw ZipArchiveError.damagedArchive
        }
        let nameLength = Int(readUInt16(entry.localHeaderOffset + 26) ?? 0)
        let extraLength = Int(readUInt16(entry.localHeaderOffset + 28) ?? 0)
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= bytes.count else {
            throw ZipArchiveError.damagedArchive
        }
        let payload = Data(bytes[start..<(start + entry.compressedSize)])

        switch entry.compressionMethod {
        case Self.storedMethod:
            return payload
        case Self.deflatedMethod:
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipArchiveError.damagedArchive
            }
            return inflated
        default:
            throw ZipArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    func text(of entry: Entry) throws -> String {
        let data = try contents(of: entry)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ZipArchiveError.damagedArchive
        }
        return value
    }

    // MARK: - Inflate

    /// Raw DEFLATE, which is what a ZIP entry holds. Apple names this
    /// `COMPRESSION_ZLIB` even though the zlib wrapper is not present.
    static func inflate(_ payload: Data, expectedSize: Int) -> Data? {
        #if canImport(Compression)
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { return nil }
        return output
        #else
        return nil
        #endif
    }

    // MARK: - Byte helpers

    /// The end-of-central-directory record sits at the very end of the file,
    /// before a comment of up to 64 KB.
    private func endOfCentralDirectoryOffset() -> Int? {
        let minimumSize = 22
        guard bytes.count >= minimumSize else { return nil }
        let earliest = max(0, bytes.count - minimumSize - 65_535)
        var offset = bytes.count - minimumSize
        while offset >= earliest {
            if readUInt32(offset) == Self.endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private func readUInt16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func string(at offset: Int, length: Int) -> String? {
        guard length >= 0, offset >= 0, offset + length <= bytes.count else { return nil }
        return String(bytes: bytes[offset..<(offset + length)], encoding: .utf8)
    }
}

/// Pulls readable text out of a Microsoft Office document.
///
/// The alternative would be handing the raw file to the provider, but a chat
/// endpoint cannot read `.docx` or `.xlsx` — OpenRouter's document support
/// covers PDF, not the Office formats. Extracting the text here means these
/// files work with *every* provider Kestrel can talk to, including the local
/// Apple model, instead of only the hosted ones.
enum OfficeDocumentText {
    /// Extensions Kestrel reads by extracting their text locally.
    static let supportedExtensions: Set<String> = ["docx", "xlsx", "pptx", "docm", "xlsm", "pptm"]

    /// The most Kestrel will read from a single Office document.
    static let maximumExtractedCharacters = 60_000

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func text(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw NewTabAttachmentError.unreadableFile(url.lastPathComponent)
        }
        let archive = ZipArchive(data: data)
        guard !archive.entries().isEmpty else {
            throw ZipArchiveError.notAnArchive
        }

        let extracted: String
        switch url.pathExtension.lowercased() {
        case "docx", "docm":
            extracted = try wordProcessingText(archive)
        case "xlsx", "xlsm":
            extracted = try spreadsheetText(archive)
        case "pptx", "pptm":
            extracted = try presentationText(archive)
        default:
            throw ZipArchiveError.notAnArchive
        }

        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NewTabAttachmentError.emptyFile(url.lastPathComponent)
        }
        return String(trimmed.prefix(maximumExtractedCharacters))
    }

    // MARK: - Word

    private static func wordProcessingText(_ archive: ZipArchive) throws -> String {
        guard let body = archive.entry(named: "word/document.xml") else {
            throw ZipArchiveError.missingPart("word/document.xml")
        }
        let xml = try archive.text(of: body)
        // Paragraph and line breaks become real newlines; everything else is
        // markup the reader does not want.
        var text = xml
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
            .replacingOccurrences(of: "<w:br />", with: "\n")
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
        text = stripTags(text)
        return tidy(text)
    }

    // MARK: - Excel

    private static func spreadsheetText(_ archive: ZipArchive) throws -> String {
        let sharedStrings = try sharedStrings(archive)
        let sheetEntries = archive.entries()
            .filter { $0.name.hasPrefix("xl/worksheets/") && $0.name.hasSuffix(".xml") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !sheetEntries.isEmpty else {
            throw ZipArchiveError.missingPart("xl/worksheets")
        }

        var lines: [String] = []
        for sheet in sheetEntries {
            let xml = try archive.text(of: sheet)
            if sheetEntries.count > 1 {
                lines.append("# \(sheet.name.split(separator: "/").last.map(String.init) ?? sheet.name)")
            }
            lines.append(contentsOf: rows(in: xml, sharedStrings: sharedStrings))
        }
        return lines.joined(separator: "\n")
    }

    private static func sharedStrings(_ archive: ZipArchive) throws -> [String] {
        guard let entry = archive.entry(named: "xl/sharedStrings.xml") else { return [] }
        let xml = try archive.text(of: entry)
        return xml
            .components(separatedBy: "</si>")
            .dropLast()
            .map { stripTags($0) }
    }

    /// One line per row, cells separated by tabs. Formula cells carry their
    /// cached value, which is what a reader would see.
    private static func rows(in xml: String, sharedStrings: [String]) -> [String] {
        var lines: [String] = []
        for row in xml.components(separatedBy: "<row").dropFirst() {
            let rowBody = row.components(separatedBy: "</row>").first ?? row
            var cells: [String] = []
            for cell in rowBody.components(separatedBy: "<c ").dropFirst() {
                let isShared = cell.contains("t=\"s\"")
                let rawValue = value(of: "v", in: cell) ?? value(of: "t", in: cell) ?? ""
                if isShared, let index = Int(rawValue), sharedStrings.indices.contains(index) {
                    cells.append(sharedStrings[index])
                } else {
                    cells.append(decodeEntities(rawValue))
                }
            }
            let line = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>") ?? xml.range(of: "<\(tag) ") else { return nil }
        guard let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    // MARK: - PowerPoint

    private static func presentationText(_ archive: ZipArchive) throws -> String {
        let slides = archive.entries()
            .filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !slides.isEmpty else {
            throw ZipArchiveError.missingPart("ppt/slides")
        }

        var lines: [String] = []
        for (index, slide) in slides.enumerated() {
            let xml = try archive.text(of: slide)
            let body = xml
                .replacingOccurrences(of: "</a:p>", with: "\n")
            let text = tidy(stripTags(body))
            guard !text.isEmpty else { continue }
            lines.append("# Slide \(index + 1)")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared text tidy-up

    /// Drops every element, keeping only the character data between them.
    static func stripTags(_ xml: String) -> String {
        var output = ""
        var insideTag = false
        for character in xml {
            switch character {
            case "<":
                insideTag = true
            case ">":
                insideTag = false
            default:
                if !insideTag { output.append(character) }
            }
        }
        return decodeEntities(output)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Collapses the runs of blank lines that markup leaves behind, without
    /// touching the single newlines that carry the document's structure.
    ///
    /// Leading and trailing blank lines are dropped as well: a document's
    /// markup almost always ends with a paragraph mark, and keeping the blank
    /// line it produces would put dead space at the end of every attachment.
    static func tidy(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { lines, line in
                if line.isEmpty, lines.last?.isEmpty != false { return }
                lines.append(line)
            }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
