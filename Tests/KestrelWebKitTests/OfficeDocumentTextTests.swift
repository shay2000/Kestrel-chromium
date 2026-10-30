import XCTest

#if canImport(Compression)
import Compression
#endif

@testable import KestrelWebKit

/// Builds real ZIP archives in memory, so the reader is exercised against the
/// actual container format rather than a stub. Both storage methods are
/// available because a real Office document uses both.
private enum ZipWriter {
    struct Member {
        let name: String
        let contents: String
        let deflated: Bool
    }

    static func archive(_ members: [Member]) -> Data {
        var output = Data()
        var centralDirectory = Data()

        for member in members {
            let nameBytes = Array(member.name.utf8)
            let raw = Data(member.contents.utf8)
            let payload: Data
            let method: UInt16
            if member.deflated, let compressed = deflate(raw) {
                payload = compressed
                method = 8
            } else {
                payload = raw
                method = 0
            }

            let localOffset = output.count
            output.append(uint32: 0x0403_4B50)
            output.append(uint16: 20)
            output.append(uint16: 0)
            output.append(uint16: method)
            output.append(uint16: 0)
            output.append(uint16: 0)
            output.append(uint32: 0)
            output.append(uint32: UInt32(payload.count))
            output.append(uint32: UInt32(raw.count))
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)
            output.append(contentsOf: nameBytes)
            output.append(payload)

            centralDirectory.append(uint32: 0x0201_4B50)
            centralDirectory.append(uint16: 20)
            centralDirectory.append(uint16: 20)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: method)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint32: 0)
            centralDirectory.append(uint32: UInt32(payload.count))
            centralDirectory.append(uint32: UInt32(raw.count))
            centralDirectory.append(uint16: UInt16(nameBytes.count))
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint32: 0)
            centralDirectory.append(uint32: UInt32(localOffset))
            centralDirectory.append(contentsOf: nameBytes)
        }

        let centralOffset = output.count
        output.append(centralDirectory)
        output.append(uint32: 0x0605_4B50)
        output.append(uint16: 0)
        output.append(uint16: 0)
        output.append(uint16: UInt16(members.count))
        output.append(uint16: UInt16(members.count))
        output.append(uint32: UInt32(centralDirectory.count))
        output.append(uint32: UInt32(centralOffset))
        output.append(uint16: 0)
        return output
    }

    /// Raw DEFLATE, matching what a ZIP entry holds.
    private static func deflate(_ data: Data) -> Data? {
        #if canImport(Compression)
        let capacity = max(64, data.count * 2 + 64)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
        #else
        return nil
        #endif
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

final class OfficeDocumentTextTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Word

    private func wordDocumentXML(_ paragraphs: [String]) -> String {
        let body = paragraphs
            .map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }
            .joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body></w:document>
        """
    }

    func testReadsWordParagraphsAsLines() throws {
        let archive = ZipWriter.archive([
            .init(name: "[Content_Types].xml", contents: "<Types/>", deflated: false),
            .init(
                name: "word/document.xml",
                contents: wordDocumentXML(["First paragraph.", "Second paragraph.", "Third."]),
                deflated: true
            )
        ])
        let url = try write(archive, name: "notes.docx")

        let text = try OfficeDocumentText.text(at: url)
        XCTAssertEqual(text, "First paragraph.\nSecond paragraph.\nThird.")
    }

    /// Markup is not text: none of the element names may survive.
    func testWordTextContainsNoMarkup() throws {
        let archive = ZipWriter.archive([
            .init(name: "word/document.xml", contents: wordDocumentXML(["Hello"]), deflated: false)
        ])
        let url = try write(archive, name: "hello.docx")

        let text = try OfficeDocumentText.text(at: url)
        XCTAssertEqual(text, "Hello")
        XCTAssertFalse(text.contains("w:"), text)
    }

    func testDecodesXmlEntities() throws {
        let archive = ZipWriter.archive([
            .init(
                name: "word/document.xml",
                contents: wordDocumentXML(["Fish &amp; chips &lt;today&gt;"]),
                deflated: false
            )
        ])
        let url = try write(archive, name: "entities.docx")
        XCTAssertEqual(try OfficeDocumentText.text(at: url), "Fish & chips <today>")
    }

    func testWordDocumentWithoutBodyIsReported() throws {
        let archive = ZipWriter.archive([
            .init(name: "docProps/core.xml", contents: "<x/>", deflated: false)
        ])
        let url = try write(archive, name: "broken.docx")
        XCTAssertThrowsError(try OfficeDocumentText.text(at: url)) { error in
            guard case ZipArchiveError.missingPart(let part) = error else {
                return XCTFail("Expected a missing-part error, got \(error)")
            }
            XCTAssertEqual(part, "word/document.xml")
        }
    }

    // MARK: - Excel

    func testReadsSpreadsheetRowsAndResolvesSharedStrings() throws {
        let shared = """
        <?xml version="1.0"?>
        <sst><si><t>Name</t></si><si><t>Ada</t></si><si><t>Grace</t></si></sst>
        """
        let sheet = """
        <?xml version="1.0"?>
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c></row>
        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>36</v></c></row>
        <row r="3"><c r="A3" t="s"><v>2</v></c><c r="B3"><v>45</v></c></row>
        </sheetData></worksheet>
        """
        let archive = ZipWriter.archive([
            .init(name: "xl/sharedStrings.xml", contents: shared, deflated: true),
            .init(name: "xl/worksheets/sheet1.xml", contents: sheet, deflated: true)
        ])
        let url = try write(archive, name: "people.xlsx")

        let text = try OfficeDocumentText.text(at: url)
        XCTAssertEqual(text, "Name\nAda\t36\nGrace\t45")
    }

    func testSpreadsheetWithoutSheetsIsReported() throws {
        let archive = ZipWriter.archive([
            .init(name: "xl/sharedStrings.xml", contents: "<sst/>", deflated: false)
        ])
        let url = try write(archive, name: "empty.xlsx")
        XCTAssertThrowsError(try OfficeDocumentText.text(at: url)) { error in
            guard case ZipArchiveError.missingPart = error else {
                return XCTFail("Expected a missing-part error, got \(error)")
            }
        }
    }

    // MARK: - PowerPoint

    func testReadsSlidesInOrder() throws {
        func slide(_ value: String) -> String {
            """
            <?xml version="1.0"?>
            <p:sld><p:cSld><p:spTree><a:p><a:r><a:t>\(value)</a:t></a:r></a:p></p:spTree></p:cSld></p:sld>
            """
        }
        let archive = ZipWriter.archive([
            .init(name: "ppt/slides/slide1.xml", contents: slide("Opening"), deflated: true),
            .init(name: "ppt/slides/slide2.xml", contents: slide("Second idea"), deflated: false),
            .init(name: "ppt/slides/slide10.xml", contents: slide("Tenth idea"), deflated: true)
        ])
        let url = try write(archive, name: "deck.pptx")

        let text = try OfficeDocumentText.text(at: url)
        XCTAssertTrue(text.contains("# Slide 1\nOpening"), text)
        XCTAssertTrue(text.contains("# Slide 2\nSecond idea"), text)
        // Numeric ordering, not lexical: slide 10 comes after slide 2.
        XCTAssertTrue(text.range(of: "Second idea")!.lowerBound < text.range(of: "Tenth idea")!.lowerBound, text)
    }

    // MARK: - Container handling

    func testRejectsAFileThatIsNotAZipArchive() throws {
        let url = try write(Data("just some text, not a document".utf8), name: "fake.docx")
        XCTAssertThrowsError(try OfficeDocumentText.text(at: url)) { error in
            guard case ZipArchiveError.notAnArchive = error else {
                return XCTFail("Expected a not-an-archive error, got \(error)")
            }
        }
    }

    func testReadsStoredEntries() throws {
        let archive = ZipWriter.archive([
            .init(name: "a.txt", contents: "stored payload", deflated: false)
        ])
        let zip = ZipArchive(data: archive)
        let entries = zip.entries()
        XCTAssertEqual(entries.map(\.name), ["a.txt"])
        XCTAssertEqual(entries[0].compressionMethod, 0)
        XCTAssertEqual(try zip.text(of: entries[0]), "stored payload")
    }

    func testReadsDeflatedEntries() throws {
        #if canImport(Compression)
        let archive = ZipWriter.archive([
            .init(name: "a.txt", contents: "stored payload", deflated: false),
            .init(name: "b.txt", contents: "deflated payload", deflated: true)
        ])
        let zip = ZipArchive(data: archive)
        let entries = zip.entries()
        XCTAssertEqual(entries.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(entries[1].compressionMethod, 8)
        XCTAssertEqual(try zip.text(of: entries[1]), "deflated payload")
        #else
        throw XCTSkip("Real DEFLATE fixtures require Apple's Compression framework")
        #endif
    }

    func testOfficeExtensionMatrix() {
        XCTAssertTrue(OfficeDocumentText.supports(URL(fileURLWithPath: "/tmp/a.docx")))
        XCTAssertTrue(OfficeDocumentText.supports(URL(fileURLWithPath: "/tmp/a.XLSX")))
        XCTAssertTrue(OfficeDocumentText.supports(URL(fileURLWithPath: "/tmp/a.pptx")))
        XCTAssertFalse(OfficeDocumentText.supports(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(OfficeDocumentText.supports(URL(fileURLWithPath: "/tmp/a.rtf")))
    }

    // MARK: - Wiring into attachments

    func testOfficeDocumentBecomesATextAttachment() throws {
        let archive = ZipWriter.archive([
            .init(name: "word/document.xml", contents: wordDocumentXML(["Quarterly report."]), deflated: true)
        ])
        let url = try write(archive, name: "report.docx")

        let attachment = try NewTabAttachmentBuilder.attachment(forFileAt: url)
        XCTAssertFalse(attachment.isBinary)
        XCTAssertEqual(attachment.textValue, "Quarterly report.")
        XCTAssertEqual(attachment.label, "report.docx")
    }

    /// An Office document is read locally, so it must not be blocked for a
    /// provider that cannot read binary attachments.
    func testOfficeAttachmentIsAllowedForEveryProvider() throws {
        let attachment = NewTabAttachment(kind: .file, label: "r.docx", origin: "r.docx", text: "Body")
        let request = NewTabAttachmentBuilder.requestAttachments(from: [attachment])
        for kind in AIProviderKind.allCases {
            XCTAssertNil(AIRequestAttachment.blocker(request, provider: kind), "\(kind) should accept it")
        }
    }

    func testOfficeDocumentWithNoTextIsRefused() throws {
        let archive = ZipWriter.archive([
            .init(name: "word/document.xml", contents: wordDocumentXML(["", "   "]), deflated: true)
        ])
        let url = try write(archive, name: "blank.docx")
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.emptyFile = error else {
                return XCTFail("Expected an empty-file error, got \(error)")
            }
        }
    }

    func testUnsupportedFileErrorMentionsOfficeFormats() {
        let message = NewTabAttachmentError.unsupportedFileType("archive.zip").errorDescription ?? ""
        XCTAssertTrue(message.contains("Word"), message)
        XCTAssertTrue(message.contains("Excel"), message)
    }

    // MARK: - Text tidy-up

    func testTidyCollapsesBlankRunsButKeepsStructure() {
        let messy = "Title\n\n\n\nBody line one\nBody line two\n\n\n"
        XCTAssertEqual(OfficeDocumentText.tidy(messy), "Title\n\nBody line one\nBody line two")
    }

    func testStripTagsKeepsCharacterDataOnly() {
        XCTAssertEqual(OfficeDocumentText.stripTags("<a>x</a><b>y</b>"), "xy")
        XCTAssertEqual(OfficeDocumentText.stripTags("no markup"), "no markup")
    }
}
