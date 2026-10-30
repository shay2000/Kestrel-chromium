import XCTest
#if canImport(PDFKit)
import PDFKit
import CoreText
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

@testable import KestrelWebKit

final class NewTabAttachmentTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private func write(_ contents: String, name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

#if canImport(PDFKit)
    func testPDFTextFallbackExtractsTextAndKeepsHostedOriginal() throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 200)
        let string = NSAttributedString(string: "Synthetic cover letter for testing", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.endPDFPage()
        context.closePDF()
        let original = AIRequestAttachment(label: "test.pdf", origin: "test.pdf", content: .binary(bytes as Data, mimeType: "application/pdf"))
        let extracted = try NewTabAttachmentBuilder.readableAttachments([original], provider: .workBuddyCLI)
        guard case .text(let text) = extracted[0].content else { return XCTFail("Expected extracted text") }
        XCTAssertTrue(text.contains("Synthetic cover letter for testing"))
        XCTAssertTrue(text.contains("embedded images, diagrams and layout are not supplied"))
        XCTAssertNil(AIRequestAttachment.blocker(extracted, provider: .workBuddyCLI))
        XCTAssertEqual(try NewTabAttachmentBuilder.readableAttachments([original], provider: .openRouter), [original])
        XCTAssertThrowsError(try NewTabAttachmentBuilder.pdfText(data: Data("broken".utf8), name: "test.pdf", limit: 1000))
    }
#endif


    func testPDFConversionSharesActualBudgetWithLaterTextAndHeadings() throws {
        let pdf = AIRequestAttachment(label: "report.pdf", origin: "report.pdf", content: .binary(Data([1]), mimeType: "application/pdf"))
        let text = AIRequestAttachment(label: "requirements.txt", origin: "requirements.txt", content: .text(String(repeating: "Requirement ", count: 500)))
        for inputs in [[pdf, text], [text, pdf], [pdf, pdf, text]] {
            let converted = try NewTabAttachmentBuilder.readableAttachments(inputs, provider: .workBuddyCLI,
                maximumTotalCharacters: 2_000, pdfExtractor: { _, _, limit in String(repeating: "PDF evidence ", count: limit) })
            let request = AIRequest(messages: [], model: "small-model", attachments: converted)
            XCTAssertLessThanOrEqual(request.attachmentContext?.count ?? 0, 2_000)
            XCTAssertEqual(converted.count, inputs.count)
            XCTAssertTrue(converted.allSatisfy { if case .text(let body) = $0.content { return !body.isEmpty }; return false })
        }
    }

    // MARK: - Prompt composition

    /// The visible user message stays exactly what was typed when nothing is
    /// attached, so ordinary searching is untouched.
    func testPromptWithoutAttachmentsIsThePlainQuery() {
        XCTAssertEqual(
            NewTabAttachmentBuilder.question("  best coffee in London  ", attachments: []),
            "best coffee in London"
        )
    }

    /// Source contents stay out of the visible bubble and travel in the request.
    func testQuestionAndAttachmentContextStaySeparate() {
        let attachment = NewTabAttachment(
            kind: .file,
            label: "notes.md",
            origin: "notes.md",
            text: "Line one.\nLine two."
        )
        let question = NewTabAttachmentBuilder.question("Summarise this", attachments: [attachment])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: question)],
            model: "test/model",
            attachments: NewTabAttachmentBuilder.requestAttachments(from: [attachment])
        )
        XCTAssertEqual(question, "Summarise this")
        XCTAssertFalse(question.contains("Line one"))
        XCTAssertTrue(request.attachmentContext?.contains("--- File: notes.md ---") == true)
        XCTAssertTrue(request.attachmentContext?.contains("Line one.\nLine two.") == true)
    }

    /// Attaching without typing anything still has to produce a usable request.
    func testPromptWithAttachmentsButNoQuestionStillAsksSomething() {
        let attachment = NewTabAttachment(kind: .tab, label: "Example", origin: "Example", text: "Body")
        let question = NewTabAttachmentBuilder.question("   ", attachments: [attachment])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: question)],
            model: "test/model",
            attachments: NewTabAttachmentBuilder.requestAttachments(from: [attachment])
        )
        XCTAssertEqual(question, "Summarise the attached context.")
        XCTAssertTrue(request.attachmentContext?.contains("--- Tab: Example ---") == true)
    }

    func testPromptLabelsTabsWithTheirAddress() {
        let attachment = NewTabAttachment(
            kind: .tab,
            label: "Docs",
            origin: "Docs — https://example.com/docs",
            text: "Body"
        )
        let requestAttachments = NewTabAttachmentBuilder.requestAttachments(from: [attachment])
        let context = AIRequest(messages: [], model: "test/model", attachments: requestAttachments).attachmentContext
        XCTAssertEqual(NewTabAttachmentBuilder.question("What does this say?", attachments: [attachment]), "What does this say?")
        XCTAssertTrue(context?.contains("--- Tab: Docs — https://example.com/docs ---") == true)
    }

    /// The whole point of the builder: user-chosen content is of unknown size, so
    /// the total must be capped even when every item is under its own limit.
    func testPromptTotalBudgetIsCapped() throws {
        let attachments = (0..<6).map { index in
            NewTabAttachment(
                kind: .file,
                label: "file-\(index).txt",
                origin: "file-\(index).txt",
                text: String(repeating: "x", count: NewTabAttachmentBuilder.maximumCharactersPerAttachment)
            )
        }
        let bounded = NewTabAttachmentBuilder.requestAttachments(from: attachments)
        let context = try XCTUnwrap(AIRequest(messages: [], model: "test/model", attachments: bounded).attachmentContext)
        XCTAssertLessThanOrEqual(context.count, NewTabAttachmentBuilder.maximumTotalCharacters)
        XCTAssertTrue(context.contains("--- File: file-0.txt ---"))
    }

    func testPromptHonoursAProviderSpecificTextBudget() {
        let attachment = NewTabAttachment(
            kind: .file,
            label: "notes.txt",
            origin: "notes.txt",
            text: String(repeating: "x", count: 4_000)
        )
        let bounded = NewTabAttachmentBuilder.requestAttachments(
            from: [attachment],
            maximumTotalCharacters: 1_800
        )
        let context = AIRequest(messages: [], model: "test/model", attachments: bounded).attachmentContext ?? ""
        XCTAssertTrue(context.contains("…"))
        XCTAssertLessThanOrEqual(context.count, 1_800)
    }

    func testAttachmentCapacityScalesWithProviderContext() {
        let apple = AttachmentCapacity.forModel(provider: .appleLocalModel, contextWindow: 4_096)
        let compact = AttachmentCapacity.forModel(provider: .groq, contextWindow: 16_384)
        let mid = AttachmentCapacity.forModel(provider: .groq, contextWindow: 65_536)
        let large = AttachmentCapacity.forModel(provider: .openRouter, contextWindow: 1_000_000)
        let unknownCodex = AttachmentCapacity.forModel(provider: .codexCLI, contextWindow: nil)

        XCTAssertEqual(apple.maximumFiles, 1)
        XCTAssertEqual(apple.maximumTextCharacters, 1_800)
        XCTAssertEqual(compact.maximumFiles, 2)
        XCTAssertEqual(mid.maximumFiles, 4)
        XCTAssertEqual(large.maximumFiles, NewTabAttachmentBuilder.maximumAttachments)
        XCTAssertEqual(large.maximumTextCharacters, NewTabAttachmentBuilder.maximumTotalCharacters)
        XCTAssertEqual(unknownCodex.maximumFiles, 4)
    }

    // MARK: - Clipping

    func testClippedKeepsShortTextUntouched() {
        XCTAssertEqual(NewTabAttachmentBuilder.clipped("short", limit: 100), "short")
    }

    /// Unlike page snapshots, file text keeps its line breaks — code and tables
    /// lose their meaning without them.
    func testClippedPreservesLineBreaks() {
        let text = "func a() {}\nfunc b() {}\n"
        XCTAssertEqual(NewTabAttachmentBuilder.clipped(text, limit: 100), text)
    }

    func testClippedMarksTruncation() {
        let clipped = NewTabAttachmentBuilder.clipped(String(repeating: "y", count: 50), limit: 10)
        XCTAssertEqual(clipped.count, 10)
        XCTAssertTrue(clipped.hasSuffix("…"), clipped)
    }

    func testClippedWithZeroLimitIsEmpty() {
        XCTAssertEqual(NewTabAttachmentBuilder.clipped("anything", limit: 0), "")
    }

    // MARK: - Labels

    func testFileTypeMarksFollowTheOriginalFileExtension() {
        XCTAssertEqual(AttachmentFileMark.forFileExtension(".PPTX"), .powerpoint)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("xlsx"), .excel)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("docm"), .word)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("pdf"), .pdf)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("heic"), .image)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("md"), .text)
        XCTAssertEqual(AttachmentFileMark.forFileExtension("unknown"), .generic)

        let presentation = NewTabAttachment(
            kind: .file,
            label: "quarterly…",
            origin: "quarterly presentation.pptx",
            text: "Slides"
        )
        XCTAssertEqual(presentation.fileMark, .powerpoint)

        let tab = NewTabAttachment(kind: .tab, label: "Docs", origin: "Docs — https://example.com", text: "Body")
        XCTAssertNil(tab.fileMark)
    }

    func testShortFileNameIsUsedAsTheChipLabel() {
        XCTAssertEqual(
            NewTabAttachmentBuilder.label(forFileAt: URL(fileURLWithPath: "/tmp/notes.md")),
            "notes.md"
        )
    }

    func testLongFileNameIsTruncatedForTheChip() {
        let name = String(repeating: "a", count: 60) + ".txt"
        let label = NewTabAttachmentBuilder.label(forFileAt: URL(fileURLWithPath: "/tmp/\(name)"), limit: 20)
        XCTAssertEqual(label.count, 20)
        XCTAssertTrue(label.hasSuffix("…"), label)
    }

    // MARK: - Reading files

    func testReadsATextFile() throws {
        let url = try write("Hello\nWorld", name: "greeting.txt")
        let attachment = try NewTabAttachmentBuilder.attachment(forFileAt: url)
        XCTAssertEqual(attachment.kind, .file)
        XCTAssertEqual(attachment.label, "greeting.txt")
        XCTAssertEqual(attachment.origin, "greeting.txt")
        XCTAssertEqual(attachment.textValue, "Hello\nWorld")
        XCTAssertFalse(attachment.isBinary)
    }

    /// A binary or unknown file is refused with an explanation rather than
    /// attached as a silent empty string.
    func testRefusesAnUnsupportedFileType() throws {
        let url = try write("binary-ish", name: "archive.zip")
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.unsupportedFileType(let name) = error else {
                return XCTFail("Expected an unsupported-file-type error, got \(error)")
            }
            XCTAssertEqual(name, "archive.zip")
        }
    }

    func testRefusesAFileWithNoReadableText() throws {
        let url = try write("   \n\n  ", name: "blank.txt")
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.emptyFile(let name) = error else {
                return XCTFail("Expected an empty-file error, got \(error)")
            }
            XCTAssertEqual(name, "blank.txt")
        }
    }

    func testRefusesAMissingFile() {
        let url = temporaryDirectory.appendingPathComponent("absent.txt")
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.unreadableFile = error else {
                return XCTFail("Expected an unreadable-file error, got \(error)")
            }
        }
    }

    func testRefusesMoreThanTheAttachmentLimit() throws {
        let url = try write("text", name: "extra.txt")
        XCTAssertThrowsError(
            try NewTabAttachmentBuilder.attachment(
                forFileAt: url,
                existingCount: NewTabAttachmentBuilder.maximumAttachments
            )
        ) { error in
            guard case NewTabAttachmentError.tooMany = error else {
                return XCTFail("Expected a too-many error, got \(error)")
            }
        }
    }

    func testLongFileIsClippedOnRead() throws {
        let url = try write(String(repeating: "z", count: NewTabAttachmentBuilder.maximumCharactersPerAttachment * 3), name: "big.txt")
        let attachment = try NewTabAttachmentBuilder.attachment(forFileAt: url)
        XCTAssertEqual(attachment.textValue?.count, NewTabAttachmentBuilder.maximumCharactersPerAttachment)
        XCTAssertTrue(attachment.textValue?.hasSuffix("…") == true)
    }

    func testTextFileMatrix() {
        XCTAssertTrue(NewTabAttachmentBuilder.isReadableFile(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(NewTabAttachmentBuilder.isReadableFile(URL(fileURLWithPath: "/tmp/a.JSON")))
        XCTAssertTrue(NewTabAttachmentBuilder.isReadableFile(URL(fileURLWithPath: "/tmp/a.swift")))
        XCTAssertFalse(NewTabAttachmentBuilder.isReadableFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(NewTabAttachmentBuilder.isReadableFile(URL(fileURLWithPath: "/tmp/a")))
    }

    // MARK: - Files handed to the provider as bytes

    /// An image is not decoded locally: the bytes go to a provider that can
    /// actually look at them.
    func testReadsAnImageAsBinaryWithItsMimeType() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = temporaryDirectory.appendingPathComponent("shot.png")
        try bytes.write(to: url)

        let attachment = try NewTabAttachmentBuilder.attachment(forFileAt: url)
        XCTAssertTrue(attachment.isBinary)
        XCTAssertNil(attachment.textValue)
        XCTAssertEqual(attachment.label, "shot.png")
        guard case .binary(let data, let mimeType) = attachment.content else {
            return XCTFail("Expected a binary payload")
        }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(mimeType, "image/png")
    }

    func testReadsAPDFAsBinary() throws {
        let url = temporaryDirectory.appendingPathComponent("report.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: url)

        let attachment = try NewTabAttachmentBuilder.attachment(forFileAt: url)
        guard case .binary(_, let mimeType) = attachment.content else {
            return XCTFail("Expected a binary payload")
        }
        XCTAssertEqual(mimeType, "application/pdf")
    }

    func testPassThroughMatrix() {
        XCTAssertTrue(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.JPEG")))
        XCTAssertTrue(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.heic")))
        XCTAssertTrue(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertFalse(NewTabAttachmentBuilder.isPassThroughFile(URL(fileURLWithPath: "/tmp/a.docx")))
    }

    /// A file Kestrel cannot attach at all is still refused, and the message
    /// says what would work instead.
    func testRefusesAFileTypeThatIsNeitherTextNorPassThrough() throws {
        let url = try write("not really audio", name: "song.mp3")
        XCTAssertFalse(NewTabAttachmentBuilder.isSupportedFile(url))
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.unsupportedFileType(let name) = error else {
                return XCTFail("Expected an unsupported-file-type error, got \(error)")
            }
            XCTAssertEqual(name, "song.mp3")
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("PDF"), message)
        }
    }

    func testRefusesAnEmptyImage() throws {
        let url = temporaryDirectory.appendingPathComponent("empty.png")
        try Data().write(to: url)
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.emptyFile = error else {
                return XCTFail("Expected an empty-file error, got \(error)")
            }
        }
    }

    /// One large scan must not be allowed to make every later request fail with
    /// an opaque server error.
    func testRefusesAnOversizedImage() throws {
        let url = temporaryDirectory.appendingPathComponent("huge.png")
        try Data(repeating: 0x41, count: NewTabAttachmentBuilder.maximumBinaryBytes + 1).write(to: url)
        XCTAssertThrowsError(try NewTabAttachmentBuilder.attachment(forFileAt: url)) { error in
            guard case NewTabAttachmentError.fileTooLarge(let name, let limit) = error else {
                return XCTFail("Expected a file-too-large error, got \(error)")
            }
            XCTAssertEqual(name, "huge.png")
            XCTAssertEqual(limit, NewTabAttachmentBuilder.maximumBinaryBytes)
        }
    }

    func testOversizedErrorNamesTheLimitInMegabytes() {
        let error = NewTabAttachmentError.fileTooLarge(name: "huge.png", limit: 8 * 1_048_576)
        XCTAssertEqual(error.errorDescription, "“huge.png” is larger than the 8 MB Kestrel will send.")
    }

    // MARK: - Prompt text versus bytes

    /// A binary attachment contributes no prompt text, so an image with no typed
    /// question still has to produce a usable, named request.
    func testPromptNamesBinaryAttachmentsWithoutInliningThem() {
        let image = NewTabAttachment(
            kind: .file,
            label: "shot.png",
            origin: "shot.png",
            content: .binary(Data([0x01, 0x02]), mimeType: "image/png")
        )
        let question = NewTabAttachmentBuilder.question("", attachments: [image])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: question)],
            model: "test/model",
            attachments: NewTabAttachmentBuilder.requestAttachments(from: [image])
        )
        XCTAssertEqual(question, NewTabAttachmentBuilder.defaultQuestion)
        XCTAssertTrue(request.attachmentContext?.contains("shot.png") == true)
        XCTAssertFalse(request.attachmentContext?.contains("AQI=") == true)
    }

    func testPromptKeepsTheTypedQuestionWhenOnlyBinaryIsAttached() {
        let image = NewTabAttachment(
            kind: .file,
            label: "shot.png",
            origin: "shot.png",
            content: .binary(Data([0x01]), mimeType: "image/png")
        )
        let question = NewTabAttachmentBuilder.question("What is in this picture?", attachments: [image])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: question)],
            model: "test/model",
            attachments: NewTabAttachmentBuilder.requestAttachments(from: [image])
        )
        XCTAssertEqual(question, "What is in this picture?")
        XCTAssertTrue(request.attachmentContext?.contains("shot.png") == true)
    }

    /// Text and bytes can travel together without changing the visible user
    /// message; both remain structured request context.
    func testPromptHandlesMixedAttachments() {
        let notes = NewTabAttachment(kind: .file, label: "notes.md", origin: "notes.md", text: "Line one.")
        let image = NewTabAttachment(
            kind: .file,
            label: "shot.png",
            origin: "shot.png",
            content: .binary(Data([0x01]), mimeType: "image/png")
        )
        let question = NewTabAttachmentBuilder.question("Compare these", attachments: [notes, image])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: question)],
            model: "test/model",
            attachments: NewTabAttachmentBuilder.requestAttachments(from: [notes, image])
        )
        XCTAssertEqual(question, "Compare these")
        XCTAssertTrue(request.attachmentContext?.contains("--- File: notes.md ---") == true)
        XCTAssertTrue(request.attachmentContext?.contains("Line one.") == true)
        XCTAssertTrue(request.attachmentContext?.contains("shot.png") == true)
    }

    func testRequestAttachmentsCarryBothShapes() {
        let notes = NewTabAttachment(kind: .file, label: "notes.md", origin: "notes.md", text: "Body")
        let image = NewTabAttachment(
            kind: .file,
            label: "shot.png",
            origin: "shot.png",
            content: .binary(Data([0x09]), mimeType: "image/png")
        )
        let request = NewTabAttachmentBuilder.requestAttachments(from: [notes, image])
        XCTAssertEqual(request.count, 2)
        XCTAssertEqual(request[0].content, .text("Body"))
        XCTAssertEqual(request[1].content, .binary(Data([0x09]), mimeType: "image/png"))
        XCTAssertFalse(request[0].isBinary)
        XCTAssertTrue(request[1].isBinary)
        XCTAssertTrue(request[1].isImage)
    }

    func testErrorsListTheFileTypesThatWork() {
        let error = NewTabAttachmentError.unsupportedFileType("letter.docx")
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("image"), message)
        XCTAssertTrue(message.contains("PDF"), message)
    }

    // MARK: - What the open panel offers

    #if canImport(UniformTypeIdentifiers)
    /// The picker must offer the concrete formats Kestrel reads. Offering a file
    /// and then refusing it is a worse experience than not offering it at all.
    func testOpenPanelOffersEveryPassThroughAndOfficeType() {
        let identifiers = Set(NewTabAttachmentBuilder.selectableContentTypes().map(\.identifier))

        for fileExtension in NewTabAttachmentBuilder.passThroughTypes.keys {
            guard let type = UTType(filenameExtension: fileExtension) else {
                return XCTFail("No system type for .\(fileExtension)")
            }
            XCTAssertTrue(identifiers.contains(type.identifier), ".\(fileExtension) was not offered")
        }
        for fileExtension in OfficeDocumentText.supportedExtensions {
            guard let type = UTType(filenameExtension: fileExtension) else {
                return XCTFail("No system type for .\(fileExtension)")
            }
            XCTAssertTrue(identifiers.contains(type.identifier), ".\(fileExtension) was not offered")
        }
    }

    /// Every extension the reader accepts must be in the file picker's allowlist.
    /// Some extensions resolve to dynamic types that do not conform to a generic
    /// text family on the running macOS version.
    func testOpenPanelOffersEveryReadableTextExtension() {
        let identifiers = Set(NewTabAttachmentBuilder.selectableContentTypes().map(\.identifier))

        for fileExtension in NewTabAttachmentBuilder.readableTextExtensions {
            guard let type = UTType(filenameExtension: fileExtension) else {
                return XCTFail("No system type for .\(fileExtension)")
            }
            XCTAssertTrue(identifiers.contains(type.identifier), ".\(fileExtension) would not be selectable")
        }
    }

    func testOpenPanelOffersNoDuplicates() {
        let identifiers = NewTabAttachmentBuilder.selectableContentTypes().map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertFalse(identifiers.isEmpty)
    }
    #endif

    // MARK: - Tabs

    func testBuildsATabAttachmentWithItsTitleAndAddress() throws {
        let attachment = try NewTabAttachmentBuilder.attachment(
            forTabTitle: "Example Domain",
            url: "https://example.com",
            text: "This domain is for use in examples."
        )
        XCTAssertEqual(attachment.kind, .tab)
        XCTAssertEqual(attachment.label, "Example Domain")
        XCTAssertEqual(attachment.origin, "Example Domain — https://example.com")
    }

    /// A tab that has not loaded yet has nothing to contribute, and saying so is
    /// better than attaching an empty block.
    func testRefusesATabWithNoText() {
        XCTAssertThrowsError(
            try NewTabAttachmentBuilder.attachment(forTabTitle: "New Tab", url: "", text: "  ")
        ) { error in
            guard case NewTabAttachmentError.noPageText(let title) = error else {
                return XCTFail("Expected a no-page-text error, got \(error)")
            }
            XCTAssertEqual(title, "New Tab")
        }
    }

    func testTabWithoutATitleFallsBackToItsAddress() throws {
        let attachment = try NewTabAttachmentBuilder.attachment(
            forTabTitle: "",
            url: "https://example.com",
            text: "Body"
        )
        XCTAssertEqual(attachment.label, "https://example.com")
    }

    // MARK: - Errors read like sentences

    func testEveryErrorExplainsItself() {
        let errors: [NewTabAttachmentError] = [
            .tooMany(limit: 6),
            .unsupportedFileType("photo.png"),
            .unreadableFile("notes.md"),
            .emptyFile("blank.txt"),
            .noPageText("New Tab"),
            .fileTooLarge(name: "huge.png", limit: 8 * 1_048_576)
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) had no description")
            XCTAssertTrue(description.hasSuffix("."), "\(error) did not read as a sentence: \(description)")
        }
    }
}
