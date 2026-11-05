import AppKit
import ApplicationServices
import Foundation
import Vision

typealias ActionProbe = ChromeWebStoreAcceptance

@main @MainActor
struct NativeExtensionActionAcceptance {
    static func text(_ node: AXUIElement, _ attribute: String) -> String {
        String(describing: ActionProbe.ax(node,attribute) ?? "" as CFString)
    }
    static func rect(_ node: AXUIElement) -> CGRect? {
        guard let p=ActionProbe.ax(node,"AXPosition"),let s=ActionProbe.ax(node,"AXSize") else{return nil}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else{return nil}
        return CGRect(origin:point,size:size)
    }
    static func preview(_ name:String) throws {
        try ActionProbe.capture(name)
        if let tiff=NSImage(contentsOf:ActionProbe.output.appendingPathComponent(name+".png"))?.tiffRepresentation,
           let bitmap=NSBitmapImageRep(data:tiff),let jpeg=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.5]) {
            print("KESTREL_ACTION_PROBE_IMAGE \(name) \(jpeg.base64EncodedString())");fflush(stdout)
        }
    }
    static func describeButtons(_ stage:String) {
        let all=ActionProbe.axNodes()
        let rows=all.filter{["AXButton","AXToolbar","AXMenuButton","AXPopUpButton"].contains(text($0,"AXRole")) || text($0,"AXDescription").localizedCaseInsensitiveContains("extensions")}.map{node in
            ["role":text(node,"AXRole"),"label":text(node,"AXDescription"),"title":text(node,"AXTitle"),"identifier":text(node,"AXIdentifier"),"help":text(node,"AXHelp"),"bounds":rect(node).map(NSStringFromRect) ?? ""]
        }
        ActionProbe.record("native_action_nodes",["stage":stage,"nodes":rows,"roleCounts":Dictionary(grouping:all,by:{text($0,"AXRole")}).mapValues(\.count)])
    }
    static func click(_ label: String, role: String = "AXButton") async throws {
        let nodes=ActionProbe.axNodes().filter { text($0,"AXRole")==role && [text($0,"AXDescription"),text($0,"AXTitle")].contains(label) }
        let unique=Dictionary(grouping:nodes,by:{rect($0).map(NSStringFromRect) ?? "missing"}).values.compactMap(\.first)
        guard unique.count==1,let bounds=rect(unique[0]) else { throw StoreProbeError(message:"Expected one Kestrel control: \(label), found \(unique.count)") }
        for kind in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:CGPoint(x:bounds.midX,y:bounds.midY),mouseButton:.left)
            event?.flags=[];event?.post(tap:.cghidEventTap);await ActionProbe.pause(0.04)
        }
    }
    static func extensionOptionsPoint() async throws -> CGPoint {
        let url = ActionProbe.output.appendingPathComponent("visible-extension-options.png")
        for _ in 0..<10 {
            try ActionProbe.command("/usr/sbin/screencapture", ["-x", url.path])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(url: url).perform([request])
            let matches = try (request.results ?? []).compactMap { observation -> CGRect? in
                guard let text = observation.topCandidates(1).first,
                      let range = text.string.range(of: "Extension Options") else { return nil }
                return try text.boundingBox(for: range)?.boundingBox
            }
            if matches.count == 1, let box = matches.first {
                let screen = CGDisplayBounds(CGMainDisplayID())
                return CGPoint(x: screen.width * box.midX, y: screen.height * (1 - box.midY))
            }
            await ActionProbe.pause(0.3)
        }
        throw StoreProbeError(message: "The genuine extension popup never visibly rendered its options link")
    }
    static func key(_ code:CGKeyCode,_ flags:CGEventFlags=[]) {
        for down in [true,false] {let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down);event?.flags=flags;event?.post(tap:.cghidEventTap)}
    }
    static func menuAction(_ title: String, item: String) async throws {
        let app=AXUIElementCreateApplication(ActionProbe.testedPID!)
        guard let raw=ActionProbe.ax(app,"AXMenuBar") else {throw StoreProbeError(message:"Missing Kestrel menu bar")}
        let bar=unsafeBitCast(raw,to:AXUIElement.self)
        guard let menu=(ActionProbe.ax(bar,"AXChildren") as? [AXUIElement])?.first(where:{text($0,"AXTitle")==title}) else {throw StoreProbeError(message:"Missing Kestrel \(title) menu")}
        _=AXUIElementPerformAction(menu,kAXPressAction as CFString)
        await ActionProbe.pause(0.3)
        var pending=ActionProbe.ax(menu,"AXChildren") as? [AXUIElement] ?? []
        var found:[AXUIElement]=[]
        while !pending.isEmpty && found.count<10 {
            let node=pending.removeFirst()
            if text(node,"AXRole")=="AXMenuItem",text(node,"AXTitle")==item {found.append(node)}
            pending += ActionProbe.ax(node,"AXChildren") as? [AXUIElement] ?? []
        }
        guard found.count==1 else {throw StoreProbeError(message:"Missing installed action in Kestrel's menu bar")}
        _=AXUIElementPerformAction(found[0],kAXPressAction as CFString)
        await ActionProbe.pause(1)
    }
    static func settingsSidebar(_ enabled: Bool) async throws {
        key(43,.maskCommand);await ActionProbe.pause(0.8)
        let rows=try ActionProbe.capture("native-settings-navigation")
        guard let row=rows.filter({($0.text=="Extensions" || $0.text.hasSuffix(" Extensions")) && $0.box.maxY<0.94}).min(by:{$0.box.minX<$1.box.minX}) else {throw StoreProbeError(message:"No Extensions settings category")}
        let screen=CGDisplayBounds(CGMainDisplayID())
        let point=CGPoint(x:screen.width*row.box.midX,y:screen.height*(1-row.box.midY))
        for kind in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:point,mouseButton:.left)
            event?.flags=[];event?.post(tap:.cghidEventTap)
        }
        await ActionProbe.pause(0.4)
        describeButtons("placement-settings")
        try await click("Show extensions beside Chats",role:"AXCheckBox")
        await ActionProbe.pause(0.3)
        try preview(enabled ? "native-settings-sidebar-on" : "native-settings-sidebar-off")
        let app=AXUIElementCreateApplication(ActionProbe.testedPID!)
        guard let raw=ActionProbe.ax(app,"AXFocusedWindow"),let close=ActionProbe.ax(unsafeBitCast(raw,to:AXUIElement.self),"AXCloseButton") else {throw StoreProbeError(message:"Cannot close Kestrel Settings")}
        _=AXUIElementPerformAction(unsafeBitCast(close,to:AXUIElement.self),kAXPressAction as CFString)
        await ActionProbe.pause(0.4)
        let visible=ActionProbe.axNodes().contains {text($0,"AXDescription")=="Open Google Translate extension"}
        guard visible==enabled else {throw StoreProbeError(message:"Sidebar placement did not follow the visible Settings control")}
    }
    static func main() async {
        do {
            ActionProbe.app=URL(fileURLWithPath:CommandLine.arguments[1]);ActionProbe.output=URL(fileURLWithPath:CommandLine.arguments[2])
            try FileManager.default.createDirectory(at:ActionProbe.output,withIntermediateDirectories:true)
            ActionProbe.capturesNativeOutput=true
            ActionProbe.forcesRendererAccessibility=false
            let defaults=UserDefaults(suiteName:"com.shayprasad.Kestrel")!
            defaults.set(try JSONSerialization.data(withJSONObject:["menuBarVisible":true,"allowsUnpackedImports":false,"toolbarActionsVisible":true,"sidebarActionsVisible":true,"sidebarActionIDs":["aapbdbdomjkkjkaonfhkkikfgjllcleb"]]),forKey:"kestrel.extensions.settings.v1")
            defaults.synchronize()
            try await ActionProbe.launch();await ActionProbe.widenRunnerWindow()
            let item=ActionProbe.items[0]
            if try ActionProbe.installedManifest(id: item.id) == nil {
                try await ActionProbe.install(id:item.id,slug:item.slug,name:item.name)
            }
            let page=try await ActionProbe.open("https://example.com/")
            await ActionProbe.pause(2)
            let app=AXUIElementCreateApplication(ActionProbe.testedPID!)
            if let raw=ActionProbe.ax(app,"AXMainWindow") {
                let owner=unsafeBitCast(raw,to:AXUIElement.self)
                var size=CGSize(width:1000,height:700),point=CGPoint(x:30,y:55)
                if let value=AXValueCreate(.cgSize,&size) {_=AXUIElementSetAttributeValue(owner,"AXSize" as CFString,value)}
                if let value=AXValueCreate(.cgPoint,&point) {_=AXUIElementSetAttributeValue(owner,"AXPosition" as CFString,value)}
                await ActionProbe.pause(0.5)
            }
            let body=try await ActionProbe.nativePageBounds(page)
            ActionProbe.record("native_action_geometry",["body":NSStringFromRect(body)])
            try await ActionProbe.nativePageClick(page,x:body.width/2,y:body.height/2)
            await ActionProbe.pause(0.5)
            describeButtons("before-menu")
            try preview("native-action-before")
            let candidates=ActionProbe.axNodes().filter { node in
                guard ["AXButton","AXMenuButton","AXPopUpButton"].contains(text(node,"AXRole")),let bounds=rect(node) else{return false}
                let label=text(node,"AXDescription")+" "+text(node,"AXTitle")
                return label.trimmingCharacters(in:.whitespaces).hasPrefix("Show extensions") && bounds.midX>=body.minX && bounds.midX<=body.maxX && bounds.midY>=body.minY-70 && bounds.midY<body.minY+60
            }
            guard candidates.count==1 else{throw StoreProbeError(message:"Expected one native Chromium Extensions button, found \(candidates.count)")}
            guard let button = rect(candidates[0]) else { throw StoreProbeError(message:"Missing Kestrel extension control bounds") }
            for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource:nil, mouseType:kind, mouseCursorPosition:CGPoint(x:button.midX,y:button.midY),mouseButton:.left)?.post(tap:.cghidEventTap)
                await ActionProbe.pause(0.04)
            }
            let menuResult=AXError.success
            ActionProbe.record("native_extensions_menu_pressed",["result":menuResult.rawValue])
            await ActionProbe.pause(1)
            describeButtons("menu-open");try preview("native-action-menu")
            try ActionProbe.dumpAX("native-action-menu.json")
            if ActionProbe.axNodes().contains(where: { text($0, "AXDescription") == "Pin Google Translate" }) {
                try await click("Pin Google Translate")
            }
            await ActionProbe.pause(3)
            let pins=ActionProbe.axNodes().filter {text($0,"AXDescription")=="Open Google Translate toolbar extension"}
            guard !pins.isEmpty else {throw StoreProbeError(message:"Pinning did not expose the extension in Kestrel's own toolbar")}
            let actionNodes=ActionProbe.axNodes().filter { node in
                return text(node,"AXRole")=="AXButton" && [text(node,"AXDescription"),text(node,"AXTitle")].contains("Google Translate")
            }
            let actions = Dictionary(grouping: actionNodes, by: { rect($0).map(NSStringFromRect) ?? "missing" }).values.compactMap(\.first)
            guard actions.count==1 else{throw StoreProbeError(message:"Expected one Translate menu action, found \(actions.count)")}
            let actionResult=AXUIElementPerformAction(actions[0],kAXPressAction as CFString)
            ActionProbe.record("native_translate_action_pressed",["result":actionResult.rawValue])
            await ActionProbe.pause(2)
            describeButtons("popup-open");try preview("native-action-popup")
            try ActionProbe.dumpAX("native-action-popup.json")
            let targets=try await ActionProbe.targets()
            ActionProbe.record("native_popup_targets",["targets":targets.map{["id":$0["id"] ?? "","type":$0["type"] ?? "","url":$0["url"] ?? "","title":$0["title"] ?? ""]}])
            guard let popup=targets.first(where:{ ($0["url"] as? String)?.hasSuffix("/popup.html") == true && ($0["type"] as? String)=="page" }) else { throw StoreProbeError(message:"Native action did not create its extension popup") }
            for _ in 0..<15 {
                let state=try await ActionProbe.evaluate(popup,"({ready:document.readyState,text:document.body?.innerText||'',runtime:chrome.runtime?.id||''})") as? [String:Any] ?? [:]
                ActionProbe.record("genuine_popup_state",state)
                if (state["text"] as? String)?.isEmpty == false { break }
                await ActionProbe.pause(1)
            }
            let context=try await ActionProbe.cdp(popup,"Runtime.evaluate",["expression":"(async()=>({extensionID:chrome.runtime.id,tabs:(await chrome.tabs.query({active:true,currentWindow:true})).map(t=>({id:t.id,url:t.url})),text:document.body.innerText}))()","returnByValue":true,"awaitPromise":true])
            ActionProbe.record("genuine_popup_context",context)
            guard let popupState=(context["result"] as? [String:Any])?["value"] as? [String:Any],
                  popupState["extensionID"] as? String == item.id,
                  let activeTabs=popupState["tabs"] as? [[String:Any]],activeTabs.count==1,
                  activeTabs[0]["url"] as? String == "https://example.com/" else {throw StoreProbeError(message:"The genuine popup did not retain the selected Kestrel tab")}
            _ = try await extensionOptionsPoint()
            describeButtons("popup-settled");try preview("native-action-popup-settled")
            try ActionProbe.dumpAX("native-action-popup-settled.json")
            key(53);await ActionProbe.pause(0.5)
            try await click("Open Google Translate extension")
            await ActionProbe.pause(2)
            let optionsPoint = try await extensionOptionsPoint()
            describeButtons("sidebar-action");try preview("native-sidebar-action-popup")
            for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource:nil, mouseType:kind, mouseCursorPosition:optionsPoint, mouseButton:.left)
                event?.flags=[]; event?.post(tap:.cghidEventTap); await ActionProbe.pause(0.04)
            }
            _ = try await ActionProbe.target(matching:"chrome-extension://\(item.id)/options.html")
            try await ActionProbe.inspectWindowSurfaces(stage:"genuine-extension-options")
            let profile=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.shayprasad.Kestrel/CefSwift/Default")
            for filename in ["Preferences","Secure Preferences"] {
                if let data=try? Data(contentsOf:profile.appendingPathComponent(filename)),
                   let prefs=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                   let extensions=(prefs["extensions"] as? [String:Any])?["settings"] as? [String:Any],
                   let entry=extensions[item.id] as? [String:Any] {
                    var metadata:[String:Any]=["file":filename]
                    for key in ["path","state","disable_reasons"] {metadata[key]=entry[key]}
                    metadata["name"]=(entry["manifest"] as? [String:Any])?["name"]
                    ActionProbe.record("own_extension_profile_metadata",metadata)
                }
            }
            _ = try await ActionProbe.open("https://example.com/")
            await ActionProbe.pause(1)
            key(53);await ActionProbe.pause(0.3)
            try await menuAction("Extensions",item:"Google Translate")
            let menuPopup = try await ActionProbe.target(matching: "chrome-extension://\(item.id)/popup.html")
            let menuContext = try await ActionProbe.evaluate(menuPopup, "chrome.runtime.id")
            guard menuContext as? String == item.id else { throw StoreProbeError(message: "Kestrel's menu command did not open the real extension action") }
            _ = try await extensionOptionsPoint()
            try preview("native-macos-menu-action")
            key(53);await ActionProbe.pause(0.3)
            try await settingsSidebar(false)
            try await settingsSidebar(true)
            NSRunningApplication(processIdentifier:ActionProbe.testedPID!)?.terminate()
            await ActionProbe.pause(2)
            ActionProbe.forcesRendererAccessibility=false
            try await ActionProbe.launch()
            let cold=try await ActionProbe.open("https://example.org/")
            await ActionProbe.pause(1)
            let coldBody=try await ActionProbe.nativePageBounds(cold)
            let point=CGPoint(x:coldBody.maxX+button.midX-body.maxX,y:coldBody.minY+button.midY-body.minY)
            for kind in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
                let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:point,mouseButton:.left)
                event?.flags=[];event?.post(tap:.cghidEventTap);await ActionProbe.pause(0.04)
            }
            await ActionProbe.pause(1)
            try preview("native-cold-extension-menu")
            let coldOCR=try String(contentsOf:ActionProbe.output.appendingPathComponent("native-cold-extension-menu.ocr.txt"),encoding:.utf8)
            guard coldOCR.contains("Google Translate"),coldOCR.contains("Extensions") else {throw StoreProbeError(message:"The native action menu failed without forced accessibility or external AX inspection")}
            try await click("Google Translate")
            await ActionProbe.pause(1)
            let coldPopup = try await ActionProbe.target(matching: "chrome-extension://\(item.id)/popup.html")
            let coldContext = try await ActionProbe.cdp(coldPopup, "Runtime.evaluate", ["expression":"(async()=>({extensionID:chrome.runtime.id,tabs:(await chrome.tabs.query({active:true,currentWindow:true})).map(t=>({url:t.url}))}))()", "returnByValue":true, "awaitPromise":true])
            ActionProbe.record("genuine_cold_popup_context", coldContext)
            guard let state = (coldContext["result"] as? [String:Any])?["value"] as? [String:Any],
                  state["extensionID"] as? String == item.id,
                  let tabs = state["tabs"] as? [[String:Any]], tabs.count == 1,
                  tabs[0]["url"] as? String == "https://example.org/" else { throw StoreProbeError(message: "Cold extension action lost the selected Kestrel tab") }
            _ = try await extensionOptionsPoint()
            try preview("native-cold-extension-popup")
            try await ActionProbe.inspectWindowSurfaces(stage:"cold-native-actions")
            guard let running = NSRunningApplication(processIdentifier: ActionProbe.testedPID!), running.terminate() else {
                throw StoreProbeError(message: "Could not quit Kestrel with the extension popup open")
            }
            for _ in 0..<30 where !running.isTerminated { await ActionProbe.pause(0.2) }
            guard running.isTerminated else { throw StoreProbeError(message: "Kestrel did not finish quitting with the popup open") }
            await ActionProbe.pause(2)
            guard !ActionProbe.collectCrashReports() else {throw StoreProbeError(message:"The native action flow crashed")}
            try ActionProbe.save("result.json",["passed":true,"menuPress":menuResult.rawValue,"actionPress":actionResult.rawValue,"freshLaunchWithoutForcedAccessibility":true,"quitWithPopupPassed":true])
            print("Genuine native extension actions, placement settings, cold restart and popup quit passed inside Kestrel.")
        } catch {
            try? preview("failure");try? ActionProbe.dumpAX("failure.json")
            key(36);await ActionProbe.pause(0.4)
            if let current=try? await ActionProbe.targets().first(where:{$0["type"] as? String == "page" && ($0["url"] as? String)?.hasPrefix("https://example.") == true}) {
                _ = try? await ActionProbe.cdp(current,"Page.navigate",["url":"chrome://version/"])
                await ActionProbe.pause(1)
                let state=try? await ActionProbe.evaluate(current,"({force:document.getElementById('command_line')?.innerText.includes('force-renderer-accessibility'),profile:document.getElementById('profile_path')?.innerText})")
                ActionProbe.record("cold_startup_diagnostic",["state":state ?? NSNull()])
                _ = try? await ActionProbe.cdp(current,"Page.navigate",["url":"chrome://extensions/"])
                await ActionProbe.pause(1)
                let extensions=try? await ActionProbe.cdp(current,"Runtime.evaluate",["expression":"new Promise(resolve=>chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},items=>resolve(items.map(i=>({id:i.id,name:i.name,state:i.state,disableReasons:i.disableReasons})))))","returnByValue":true,"awaitPromise":true])
                ActionProbe.record("cold_extensions_diagnostic",extensions ?? [:])
            }
            await ActionProbe.pause(5)
            _ = ActionProbe.collectCrashReports()
            ActionProbe.collectLifecycleLog()
            if let stderr=try? String(contentsOf:ActionProbe.output.appendingPathComponent("native-app.stderr.log"),encoding:.utf8) { print("KESTREL_NATIVE_STDERR "+String(stderr.suffix(80000))) }
            let capture = Process(); let pipe=Pipe()
            capture.executableURL=URL(fileURLWithPath:"/usr/bin/log")
            capture.arguments=["show","--last","5m","--style","compact","--predicate","process == 'Kestrel'"]
            capture.standardOutput=pipe; capture.standardError=pipe
            try? capture.run()
            let diagnostics=pipe.fileHandleForReading.readDataToEndOfFile();capture.waitUntilExit()
            print("KESTREL_NATIVE_APP_DIAGNOSTICS "+String((String(data:diagnostics,encoding:.utf8) ?? "").suffix(50000)))
            fputs("Native extension action acceptance failed: \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
}
