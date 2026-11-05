import AppKit
import ApplicationServices
import Foundation

typealias ActionProbe = ChromeWebStoreAcceptance

@main @MainActor
struct NativeExtensionActionProbe {
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
    static func main() async {
        do {
            ActionProbe.app=URL(fileURLWithPath:CommandLine.arguments[1]);ActionProbe.output=URL(fileURLWithPath:CommandLine.arguments[2])
            try FileManager.default.createDirectory(at:ActionProbe.output,withIntermediateDirectories:true)
            ActionProbe.additionalLaunchArguments=["--kestrel-extension-toolbar-probe"]
            ActionProbe.allowsNativeToolbarHeight=true
            try await ActionProbe.launch();await ActionProbe.widenRunnerWindow()
            let item=ActionProbe.items[0]
            try await ActionProbe.install(id:item.id,slug:item.slug,name:item.name)
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
                return label.trimmingCharacters(in:.whitespaces).hasPrefix("Extensions") && bounds.midX>=body.minX && bounds.midX<=body.maxX && bounds.midY>=body.minY-70 && bounds.midY<body.minY+60
            }
            guard candidates.count==1 else{throw StoreProbeError(message:"Expected one native Chromium Extensions button, found \(candidates.count)")}
            let menuResult=AXUIElementPerformAction(candidates[0],kAXPressAction as CFString)
            ActionProbe.record("native_extensions_menu_pressed",["result":menuResult.rawValue])
            await ActionProbe.pause(1)
            describeButtons("menu-open");try preview("native-action-menu")
            try ActionProbe.dumpAX("native-action-menu.json")
            let actions=ActionProbe.axNodes().filter { node in
                let label=text(node,"AXDescription")+" "+text(node,"AXTitle")
                return text(node,"AXRole")=="AXButton" && label.localizedCaseInsensitiveContains("Google Translate") && !label.localizedCaseInsensitiveContains("pin") && !label.localizedCaseInsensitiveContains("more")
            }
            guard actions.count==1 else{throw StoreProbeError(message:"Expected one Translate menu action, found \(actions.count)")}
            let actionResult=AXUIElementPerformAction(actions[0],kAXPressAction as CFString)
            ActionProbe.record("native_translate_action_pressed",["result":actionResult.rawValue])
            await ActionProbe.pause(2)
            describeButtons("popup-open");try preview("native-action-popup")
            try ActionProbe.dumpAX("native-action-popup.json")
            let targets=try await ActionProbe.targets()
            ActionProbe.record("native_popup_targets",["targets":targets.map{["id":$0["id"] ?? "","type":$0["type"] ?? "","url":$0["url"] ?? "","title":$0["title"] ?? ""]}])
            try ActionProbe.save("result.json",["probeCompleted":true,"menuPress":menuResult.rawValue,"actionPress":actionResult.rawValue])
        } catch {
            try? preview("failure");try? ActionProbe.dumpAX("failure.json")
            fputs("Native action probe failed: \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
}
