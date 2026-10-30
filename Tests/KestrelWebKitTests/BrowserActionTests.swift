import XCTest

@testable import KestrelWebKit

final class BrowserActionTests: XCTestCase {
    func testUnknownRadioLabelsRetainReviewOnProductPages() {
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.invalid/products/phone")
        for label in ["Yes", "Agree", "Enable marketing", "Share details", "Unknown option"] {
            XCTAssertEqual(AgentAutoPolicy.decision(.selectOption(label), context: context), .review)
        }
    }

    func testProfileFillNeverAutoApprovesAndCannotCarryModelValuesOrTokens() throws {
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"fill_profile","rationale":"Preview"}"#), .fillProfile(nil))
        let action = BrowserAction.fillProfile(UUID())
        XCTAssertTrue(action.requiresApproval)
        XCTAssertFalse(action.isEligibleForSafeBrowsingAutoApproval)
        XCTAssertEqual(AgentAutoPolicy.decision(action, context: .init(tabID: UUID(), pageURL: "https://example.invalid/checkout")), .review)
        for key in ["values", "selector", "script", "id", "token", "value"] {
            XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonObject: ["action": "fill_profile", key: "anything"]))
        }
    }

    func testAutoModeStopsPurchaseAndReviewsAmbiguousControls() throws {
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://www.apple.com/uk/shop/buy-iphone/iphone-18-pro")
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("Burgundy"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Add to Bag"), context: context), .allow)
        XCTAssertTrue(AgentAutoPolicy.isBasketAddition("Add [APPLE iPhone 17 - 256 GB, Black] to basket"))
        XCTAssertFalse(AgentAutoPolicy.isBasketAddition("Add insurance to basket and pay now"))
        XCTAssertEqual(AgentAutoPolicy.decision(.clickReferencedControl(reference: "c1_2", label: "Add [APPLE iPhone 17 - 256 GB, Black] to basket"), context: context), .allow)

        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Continue"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Select colour Blue"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("512GB"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("512GB monthly payment"), context: context), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickReferencedControl(reference: "c1_2", label: "Select hard_drive_capacity 512GB"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Select colour Blue and pay now"), context: context), .stop)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Select storage monthly"), context: context), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Select colour Blue"), context: nil), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("AppleCare cover"), context: context), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("No AppleCare coverage"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("No AppleCare coverage with monthly payment"), context: context), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("No AppleCare coverage"), context: nil), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Checkout"), context: context), .stop)
        XCTAssertEqual(AgentAutoPolicy.decision(.openURL("https://example.com/checkout"), context: context), .stop)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickText("Send"), context: context), .review)
        XCTAssertEqual(AgentAutoPolicy.decision(.selectOption("Burgundy"), context: nil), .review)
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"select_option","query":"Burgundy"}"#), .selectOption("Burgundy"))
        XCTAssertTrue(BrowserAction.selectOption("Burgundy").requiresApproval)
        XCTAssertFalse(BrowserAction.selectOption("Burgundy").isEligibleForSafeBrowsingAutoApproval)
    }

    func testCapturedControlReferencesRequireBoundedIDAndExactLabel() throws {
        let action = try BrowserActionDecoder.decode(jsonString: #"{"action":"click_text","query":"View product","control":"c12_3"}"#)
        XCTAssertEqual(action, .clickReferencedControl(reference: "c12_3", label: "View product"))
        XCTAssertTrue(action.requiresApproval)
        XCTAssertFalse(action.isEligibleForSafeBrowsingAutoApproval)
        for reference in ["button:nth-child(2)", "c1_2;alert(1)", "c1_9999", "", "#checkout"] {
            XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonObject: ["action": "click_text", "query": "View product", "control": reference]))
        }
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.invalid/products/phone")
        XCTAssertEqual(AgentAutoPolicy.decision(.clickReferencedControl(reference: "c1_2", label: "Checkout"), context: context), .stop)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickReferencedControl(reference: "c1_2", label: "Add to basket"), context: context), .allow)
        XCTAssertEqual(AgentAutoPolicy.decision(.clickReferencedControl(reference: "c1_2", label: "Continue without cover"), context: context), .allow)
    }

    #if canImport(WebKit)
    func testVisibleTextCaptureDoesNotFallBackToHiddenDOMContent() {
        XCTAssertTrue(BrowserScripts.visibleText.contains("body.innerText"))
        XCTAssertFalse(BrowserScripts.visibleText.contains("textContent"))
    }

    func testSearchPageScriptIsFixedAndConstrainedToSafeSearchForms() {
        let injectedQuery = #"iPhone"); document.body.remove(); //"#
        let script = BrowserScripts.searchPage(query: injectedQuery, token: UUID())
        XCTAssertFalse(script.contains(injectedQuery))
        XCTAssertTrue(script.contains("formmethod"))
        XCTAssertTrue(script.contains("location.origin"))
        XCTAssertTrue(script.contains("window.location.assign"))
        XCTAssertTrue(BrowserScripts.searchPageTarget(token: UUID()).contains("scrollIntoView"))
        XCTAssertTrue(BrowserScripts.searchPageTarget(token: UUID()).contains("viewportWidth"))
    }

    #endif

    func testDecodesOpenURL() throws {
        let json = #"{"action":"open_url","url":"https://example.com","rationale":"go"}"#
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .openURL("https://example.com"))
    }

    func testDecodesSimpleActions() throws {
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"go_back"}"#), .goBack)
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"go_forward"}"#), .goForward)
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"reload"}"#), .reload)
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: #"{"action":"stop"}"#), .stop)
    }

    func testDecodesFindText() throws {
        let json = #"{"name":"find_text","query":"kestrel"}"#
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .findText("kestrel"))
    }

    func testDecodesClickText() throws {
        let json = #"{"action":"click_text","query":"Sign in"}"#
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .clickText("Sign in"))
    }

    func testDecodesClickTextFromTextKey() throws {
        let json = #"{"name":"click_text","text":"Accept all"}"#
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .clickText("Accept all"))
    }

    func testClickTextNeedsAQuery() {
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"click_text"}"#))
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"click_text","query":""}"#))
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"click_text","text":"   "}"#))
    }

    func testOverlongClickTextQueryIsRejected() {
        let query = String(repeating: "a", count: BrowserActionDecoder.maximumQueryLength + 1)
        let json = "{\"action\":\"click_text\",\"query\":\"\(query)\"}"
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: json))
    }

    func testClickTextAtTheQueryLimitIsAccepted() throws {
        let query = String(repeating: "a", count: BrowserActionDecoder.maximumQueryLength)
        let json = "{\"action\":\"click_text\",\"query\":\"\(query)\"}"
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .clickText(query))
    }

    func testClickTextTrimsSurroundingWhitespace() throws {
        let json = #"{"action":"click_text","query":"  Sign in  "}"#
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .clickText("Sign in"))
    }

    func testClickTextIsNeverReadOnlyAndAlwaysNeedsApproval() {
        let action = BrowserAction.clickText("Sign in")
        XCTAssertFalse(action.isReadOnly)
        XCTAssertTrue(action.requiresApproval)
        XCTAssertEqual(action.kind, .clickText)
    }

    func testSearchPageDecodesWithAnApprovalGate() throws {
        let action = try BrowserActionDecoder.decode(
            jsonString: #"{"action":"search_page","query":"iPhone"}"#
        )
        XCTAssertEqual(action, .searchPage("iPhone"))
        XCTAssertTrue(action.requiresApproval)
        XCTAssertFalse(action.isReadOnly)
        XCTAssertEqual(action.summary, "Search this site for “iPhone”")
    }

    func testSearchPageRejectsMissingBlankAndOverlongQueries() {
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"search_page"}"#))
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"search_page","query":"  "}"#))
        let query = String(repeating: "x", count: BrowserActionDecoder.maximumQueryLength + 1)
        let json = try! JSONSerialization.data(withJSONObject: ["action": "search_page", "query": query])
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: String(decoding: json, as: UTF8.self)))
    }

    func testReadActionsClampLimit() throws {
        let json = #"{"action":"read_page_text","maxCharacters":999999}"#
        guard case .readPageText(let limit) = try BrowserActionDecoder.decode(jsonString: json) else {
            return XCTFail("Expected a read action")
        }
        XCTAssertEqual(limit, PageContextBuilder.maximumCharacterLimit)
    }

    func testUnknownActionIsRejected() {
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"run_script","code":"alert(1)"}"#))
    }

    func testNonHTTPOpenIsRejected() {
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: #"{"action":"open_url","url":"file:///etc/passwd"}"#))
    }

    func testOverlongFindQueryIsRejected() {
        let query = String(repeating: "a", count: BrowserActionDecoder.maximumQueryLength + 1)
        let json = "{\"action\":\"find_text\",\"query\":\"\(query)\"}"
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: json))
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try BrowserActionDecoder.decode(jsonString: "not json at all"))
    }

    func testApprovalClassification() {
        XCTAssertTrue(BrowserAction.openURL("https://example.com").requiresApproval)
        XCTAssertTrue(BrowserAction.findText("x").requiresApproval)
        XCTAssertTrue(BrowserAction.goBack.requiresApproval)
        XCTAssertFalse(BrowserAction.readPageText(maxCharacters: 100).requiresApproval)
        XCTAssertFalse(BrowserAction.readSelectedText(maxCharacters: 100).requiresApproval)
        XCTAssertTrue(BrowserAction.readPageText(maxCharacters: 100).isReadOnly)
    }

    func testSafeBrowsingAutoApprovalNeverIncludesGenericClicks() {
        let safeActions: [BrowserAction] = [
            .openURL("https://example.com"), .goBack, .goForward, .reload, .stop,
            .findText("results"), .searchPage("results")
        ]
        XCTAssertTrue(safeActions.allSatisfy(\.isEligibleForSafeBrowsingAutoApproval))
        XCTAssertFalse(BrowserAction.clickText("Add to basket").isEligibleForSafeBrowsingAutoApproval)
        XCTAssertFalse(BrowserAction.readPageText(maxCharacters: 100).isEligibleForSafeBrowsingAutoApproval)
    }

    func testCandidateExtraction() {
        let reply = "I will look that up. {\"action\":\"read_page_text\",\"maxCharacters\":500}"
        XCTAssertEqual(
            BrowserActionDecoder.candidateActionJSON(in: reply),
            #"{"action":"read_page_text","maxCharacters":500}"#
        )
        XCTAssertNil(BrowserActionDecoder.candidateActionJSON(in: "No action here."))
    }

    func testOperatorReplyHidesMachineReadableActionButKeepsNaturalLanguage() {
        let reply = "I'll open the repository now. {\"action\":\"open_url\",\"url\":\"https://github.com/shay2000\",\"rationale\":\"Find the repository\"}"
        XCTAssertEqual(BrowserActionDecoder.visibleAssistantText(from: reply), "I'll open the repository now.")
        XCTAssertNil(BrowserActionDecoder.visibleAssistantText(from: #"{"action":"open_url","url":"https://example.com"}"#))
    }

    func testOperatorReplyWithoutActionRemainsVisible() {
        XCTAssertEqual(
            BrowserActionDecoder.visibleAssistantText(from: "The page is open; I found the repository."),
            "The page is open; I found the repository."
        )
    }

    func testDecodedCandidateRoundTrips() throws {
        let reply = "Let me open that for you. {\"action\":\"open_url\",\"url\":\"example.org\",\"rationale\":\"it is relevant\"}"
        let candidate = try XCTUnwrap(BrowserActionDecoder.candidateActionJSON(in: reply))
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: candidate), .openURL("example.org"))
    }

    func testTaggedToolCallDecodesThroughTheExistingActionAllowList() throws {
        let reply = """
        I'll open the iPhone shop page. <tool_call>open_url <arg_key>action</arg_key><arg_value>open_url</arg_value> <arg_key>url</arg_key><arg_value>https://www.apple.com/uk/shop/buy-iphone/iphone-18-pro</arg_value> <arg_key>rationale</arg_key><arg_value>Open the product page so you can choose a colour.</arg_value></tool_call>
        """
        let candidate = try XCTUnwrap(BrowserActionDecoder.candidateActionJSON(in: reply))
        XCTAssertEqual(
            try BrowserActionDecoder.decode(jsonString: candidate),
            .openURL("https://www.apple.com/uk/shop/buy-iphone/iphone-18-pro")
        )
        XCTAssertEqual(BrowserActionDecoder.visibleAssistantText(from: reply), "I'll open the iPhone shop page.")
    }

    func testTaggedToolCallRejectsUnknownDuplicateOrMultipleFields() {
        let unknown = #"<tool_call>open_url <arg_key>url</arg_key><arg_value>https://example.com</arg_value> <arg_key>shell</arg_key><arg_value>whoami</arg_value></tool_call>"#
        let duplicate = #"<tool_call>open_url <arg_key>url</arg_key><arg_value>https://example.com</arg_value> <arg_key>url</arg_key><arg_value>https://example.org</arg_value></tool_call>"#
        let multiple = #"<tool_call>go_back</tool_call><tool_call>go_forward</tool_call>"#
        XCTAssertNil(BrowserActionDecoder.candidateActionJSON(in: unknown))
        XCTAssertNil(BrowserActionDecoder.candidateActionJSON(in: duplicate))
        XCTAssertNil(BrowserActionDecoder.candidateActionJSON(in: multiple))
    }

    func testMalformedTaggedCallIsHiddenFromVisibleOperatorText() {
        let reply = "I'll navigate now. <tool_call>open_url <arg_key>url</arg_key><arg_value>file:///etc/passwd</arg_value></tool_call>"
        XCTAssertThrowsError(
            try BrowserActionDecoder.decode(
                jsonString: try XCTUnwrap(BrowserActionDecoder.candidateActionJSON(in: reply))
            )
        )
        XCTAssertEqual(BrowserActionDecoder.visibleAssistantText(from: reply), "I'll navigate now.")
    }
}
