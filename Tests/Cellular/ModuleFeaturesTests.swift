import AppKit

@main enum ModuleFeaturesTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let model = GuardModel(startMonitoring:false)
        defer { model.shutdown() }
        var info = ModemSnapshot(); info.usbnet = 1; info.supportedModes = 15; model.modeInfo = info
        model.featureStatus = "已读取。选择模式不会立即生效，应用前还需确认。"
        var smsRequests: [(String,Bool)] = []
        let controller = ModuleFeaturesWindow(model:model,smsRequest:{ smsRequests.append(($0,$1)) })
        controller.window!.makeKeyAndOrderFront(nil)
        controller.mode.selectItem(at:2); controller.render()
        precondition(!controller.apply.isEnabled)
        controller.ready.state = .on; controller.render(); precondition(controller.apply.isEnabled)
        model.featureBusy = true; controller.render(); precondition(!controller.apply.isEnabled && !controller.read.isEnabled)
        model.featureBusy = false; controller.mode.selectItem(at:1); controller.render(); precondition(!controller.apply.isEnabled)
        controller.ready.state = .off
        controller.open(tab:1)
        precondition(smsRequests.count == 1 && smsRequests[0].0 == "ME" && !smsRequests[0].1,
                     "Opening the SMS tab must load the default inbox once without a click")
        model.messages = [
            .init(index:1,sender:"测试发件人",timestamp:"2026-09-19 10:23:45 +08:00",body:"这是一条本地生成的界面测试短信，并非真实短信。\n中文、数字 123456、长内容和多行显示。"),
            .init(index:2,sender:"服务通知",timestamp:"2026-09-18 18:07:00 +08:00",body:"第二条模拟消息，用于验证列表选择。")
        ]
        model.smsStatus = "ME 已用 2/23 · 收件 2 条 · 测试数据"
        controller.render()
        precondition(controller.messageList.numberOfRows == 2 && controller.messageList.selectedRow == 0)
        precondition(controller.sender.stringValue == "测试发件人" && controller.body.string.contains("123456"))
        controller.messageList.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        precondition(controller.sender.stringValue == "服务通知" && controller.body.string.contains("第二条模拟消息"))
        controller.messageList.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let root = controller.window!.contentView!
        for tab in 0...1 {
            controller.tabs.selectTabViewItem(at:tab)
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            precondition(!root.hasAmbiguousLayout)
            let page = controller.tabs.tabViewItem(at:tab).view!
            func check(_ view:NSView) {
                for child in view.subviews {
                    if child is NSScrollView { continue }
                    let frame = child.convert(child.bounds,to:root)
                    precondition(frame.minX >= -1 && frame.maxX <= root.bounds.maxX+1 && frame.minY >= -1 && frame.maxY <= root.bounds.maxY+1,"Clipped control \(type(of:child)) \(frame)")
                    check(child)
                }
            }
            check(page)
            let pdf = root.dataWithPDF(inside:root.bounds)
            if let image = NSImage(data:pdf), let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) {
                try png.write(to:URL(fileURLWithPath:"\(CommandLine.arguments[1])/features-\(tab).png"))
            }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            capture.arguments = ["-x","-l",String(controller.window!.windowNumber),"\(CommandLine.arguments[1])/features-\(tab)-screen.png"]
            try? capture.run(); capture.waitUntilExit()
        }
        controller.clear.performClick(nil)
        precondition(controller.messageList.numberOfRows == 0 && !controller.body.string.contains("123456"))
        precondition(controller.messageCount.stringValue.contains("0 条") && !controller.clear.isEnabled)
        model.messages = [.init(index:3,sender:"切换测试",timestamp:"2026-09-19",body:"不应留在另一存储区")]
        controller.render(); controller.storage.selectItem(at:1); controller.storageChanged()
        precondition(controller.messageList.numberOfRows == 0 && !controller.body.string.contains("不应留在另一存储区"))
        precondition(smsRequests.last?.0 == "SM" && smsRequests.last?.1 == false,
                     "Changing storage must load the selected inbox automatically")
        controller.allowRead.state = .on; controller.permissionChanged()
        precondition(smsRequests.last?.0 == "SM" && smsRequests.last?.1 == true,
                     "Changing the unread permission must retry automatically")
        model.messages = [.init(index:4,sender:"关闭测试",timestamp:"2026-09-19",body:"关闭后应清空")]
        controller.render(); controller.window!.close()
        precondition(model.messages.isEmpty && !controller.body.string.contains("关闭后应清空"))
        precondition(controller.automatic.state == .off && controller.allowRead.state == .off)
        let previousRequests = smsRequests.count
        model.featureBusy = true; controller.open(tab:1)
        precondition(smsRequests.count == previousRequests && model.smsStatus.contains("等待"))
        model.featureBusy = false; controller.render()
        RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        precondition(smsRequests.count == previousRequests+1 && smsRequests.last?.0 == "SM" && smsRequests.last?.1 == false,
                     "Reopening must load automatically after the module becomes available")
        controller.window!.close()
        print("PASS: mode confirmation gating, same-mode prevention, busy exclusion, automatic SMS loading and permission retry, inbox selection and clearing, both native tab layouts; no USB writes.")
    }
}
