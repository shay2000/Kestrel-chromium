import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Vision

typealias AuditProbe = ChromeWebStoreAcceptance

@main @MainActor
struct ExtensionPasskeyAudit {
    static func text(_ node: AXUIElement, _ attribute: String) -> String {
        String(describing: AuditProbe.ax(node, attribute) ?? "" as CFString)
    }
    static func rect(_ node: AXUIElement) -> CGRect? {
        guard let p=AuditProbe.ax(node,"AXPosition"),let s=AuditProbe.ax(node,"AXSize") else{return nil}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else{return nil}
        return CGRect(origin:point,size:size)
    }
    static func click(_ point: CGPoint) {
        for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
            let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
            event?.flags=[];event?.post(tap:.cghidEventTap)
        }
    }
    static func escape() {
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:down)
            event?.flags=[];event?.post(tap:.cghidEventTap)
        }
    }
    static func preview(_ name: String) {
        guard let source=NSImage(contentsOf:AuditProbe.output.appendingPathComponent(name+".png"))?.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return}
        let width=min(source.width,1280),height=source.height*width/source.width
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return}
        context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        if let frame=context.makeImage(),let jpeg=NSBitmapImageRep(cgImage:frame).representation(using:.jpeg,properties:[.compressionFactor:0.6]) {
            print("KESTREL_AUDIT_IMAGE \(name) \(jpeg.base64EncodedString())");fflush(stdout)
        }
    }
    static func toolbar(_ page: [String:Any]) async throws -> [String:Any] {
        let body=try await AuditProbe.nativePageBounds(page)
        let header=CGRect(x:body.minX,y:body.minY-40,width:body.width,height:40)
        let buttons=AuditProbe.axNodes().filter { text($0,"AXRole")=="AXButton" && rect($0).map{header.contains(CGPoint(x:$0.midX,y:$0.midY))} == true }
            .map { ["label":text($0,"AXDescription"),"title":text($0,"AXTitle")] }
        let visible=buttons.contains { row in row.values.contains{ $0.localizedCaseInsensitiveContains("Google Translate") || $0.localizedCaseInsensitiveContains("Extensions") } }
        AuditProbe.record("extension_toolbar_audit",["installedGoogleTranslate":try AuditProbe.installedManifest(id:AuditProbe.items[0].id) != nil,"extensionActionVisible":visible,"header":NSStringFromRect(header),"buttons":buttons])
        try AuditProbe.capture("installed-extension-toolbar");preview("installed-extension-toolbar")
        let app=AXUIElementCreateApplication(AuditProbe.testedPID!)
        var menuLabels:[String]=[]
        if let raw=AuditProbe.ax(app,"AXMenuBar") {
            let bar=unsafeBitCast(raw,to:AXUIElement.self)
            let children=AuditProbe.ax(bar,"AXChildren") as? [AXUIElement] ?? []
            menuLabels=children.map{text($0,"AXTitle")}
            if let item=children.first(where:{text($0,"AXTitle")=="Extensions"}),let bounds=rect(item) {
                click(CGPoint(x:bounds.midX,y:bounds.midY));await AuditProbe.pause(0.5)
                let lines=try AuditProbe.capture("extensions-system-menu")
                AuditProbe.record("extension_system_menu",["menuLabels":menuLabels,"visibleText":lines.map(\.text)])
                preview("extensions-system-menu");escape();await AuditProbe.pause(0.3)
            }
        }
        return ["extensionActionVisible":visible,"buttons":buttons,"systemMenuLabels":menuLabels]
    }
    static func nativeRequest(_ page:[String:Any],kind:String) async throws -> [String:Any] {
        _=try? await AuditProbe.evaluate(page,"cancelAuditRequest();true")
        escape();await AuditProbe.pause(0.3)
        let label=["known":"Phone sign-in (random credential)","discoverable":"Phone sign-in (discoverable)","create":"Create on another device"][kind]!
        guard try await AuditProbe.clickPageButton(page,label:label) else{throw StoreProbeError(message:"Missing native request control: "+kind)}
        var qrVisible=false,uiText="",powerClicked=false
        for attempt in 0..<4 {
            await AuditProbe.pause(2)
            let name="qr-\(kind)-\(attempt)"
            let lines=try AuditProbe.capture(name)
            uiText=lines.map(\.text).joined(separator:"\n")
            if uiText.localizedCaseInsensitiveContains("Bluetooth"),uiText.localizedCaseInsensitiveContains("would like"),let allow=lines.first(where:{$0.text=="Allow"}) {
                AuditProbe.clickScreen(allow.box);AuditProbe.record("runner_bluetooth_permission",["choice":"Allow"]);continue
            }
            let barcodes=VNDetectBarcodesRequest();barcodes.symbologies=[.qr]
            try VNImageRequestHandler(url:AuditProbe.output.appendingPathComponent(name+".png")).perform([barcodes])
            if let payload=(barcodes.results ?? []).compactMap(\.payloadStringValue).first(where:{$0.hasPrefix("FIDO:/")}) {
                qrVisible=true
                AuditProbe.record("native_fido_qr_detected",["kind":kind,"payloadLength":payload.count,"payloadSHA256":SHA256.hash(data:Data(payload.utf8)).map{String(format:"%02x",$0)}.joined(),"virtualAuthenticatorUsed":false])
                preview(name);break
            }
            if !powerClicked,uiText.localizedCaseInsensitiveContains("Bluetooth"),let turnOn=lines.first(where:{$0.text=="Turn on" || $0.text=="Turn on Bluetooth"}) {
                AuditProbe.clickScreen(turnOn.box);powerClicked=true;AuditProbe.record("native_bluetooth_power_requested",["kind":kind]);continue
            }
            if attempt==3 {preview(name)}
        }
        try AuditProbe.dumpAX("qr-\(kind)-ax.json")
        _=try? await AuditProbe.evaluate(page,"cancelAuditRequest();true")
        escape();await AuditProbe.pause(0.5)
        let result:[String:Any]=["kind":kind,"fidoQRVisible":qrVisible,"nativeBluetoothPowerRequested":powerClicked,"visibleText":uiText,"virtualAuthenticatorUsed":false,"physicalCeremonyPassed":false]
        AuditProbe.record("native_qr_audit",result)
        return result
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count==5 else{throw StoreProbeError(message:"usage: audit APP EVIDENCE FIXTURE_URL PHASE")}
            AuditProbe.app=URL(fileURLWithPath:CommandLine.arguments[1]);AuditProbe.output=URL(fileURLWithPath:CommandLine.arguments[2])
            try FileManager.default.createDirectory(at:AuditProbe.output,withIntermediateDirectories:true)
            try await AuditProbe.launch(reuse:true);await AuditProbe.widenRunnerWindow()
            if try AuditProbe.installedManifest(id:AuditProbe.items[0].id)==nil {
                let item=AuditProbe.items[0];try await AuditProbe.install(id:item.id,slug:item.slug,name:item.name)
            }
            let page=try await AuditProbe.open(CommandLine.arguments[3]);await AuditProbe.clearRunnerDialogues()
            var ready=false
            for _ in 0..<40 {
                if (try? await AuditProbe.evaluate(page,"document.readyState==='complete'&&Boolean(document.getElementById('known'))")) as? Bool==true {ready=true;break}
                await AuditProbe.pause(0.25)
            }
            guard ready else{throw StoreProbeError(message:"Passkey audit fixture did not load")}
            let menu=try await toolbar(page)
            var results:[[String:Any]]=[]
            for kind in ["known","discoverable","create"] {results.append(try await nativeRequest(page,kind:kind))}
            try AuditProbe.save("result.json",["auditCompleted":true,"phase":CommandLine.arguments[4],"appVersion":"1.0.1","toolbar":menu,"requests":results,"anyNativeFidoQRVisible":results.contains{($0["fidoQRVisible"] as? Bool)==true},"physicalCeremonyPassed":false])
            print("Published-build extension/QR audit completed; feature results are in result.json, not inferred from process success.")
        } catch {
            try? AuditProbe.capture("failure");preview("failure")
            try? AuditProbe.save("result.json",["auditCompleted":false,"error":error.localizedDescription])
            fputs("Extension/QR audit failed: \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
}
