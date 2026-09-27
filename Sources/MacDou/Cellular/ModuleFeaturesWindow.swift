import AppKit
import Combine

private final class FeatureWindowBackground: NSView {
    override func draw(_ dirtyRect:NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

enum USBNetworkMode {
    static let names = ["0 · RmNet / QMI", "1 · ECM（Mac 当前推荐）", "2 · MBIM", "3 · RNDIS（不推荐 EG25）"]
    static let warning = "这会修改模块的持久 USB 模式并重启模块，当前 4G 网络会断开。\n\nMac 当前只实测 ECM；RmNet/MBIM/RNDIS 可能无法联网。Windows 需匹配网卡及 AT 串口驱动；随附 ECM 驱动不覆盖其他模式。RNDIS 的 USB 接口可能变化，App 可能无法再找到 AT 控制口。\n\n请先准备其他网络和恢复用的 AT 工具。若切换后控制口不可用，需要在装好对应驱动的电脑上恢复 ECM（AT+QCFG=\"usbnet\",1 后重启）。本操作不会安装驱动或修改 Mac 的网络配置。"
}

private final class SMSInboxRow: NSTableCellView {
    let sender = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sender.font = .systemFont(ofSize: 13, weight: .semibold)
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        for label in [sender, date, preview] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            sender.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            sender.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sender.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            date.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            date.trailingAnchor.constraint(equalTo: sender.trailingAnchor),
            date.topAnchor.constraint(equalTo: sender.bottomAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: sender.trailingAnchor),
            preview.topAnchor.constraint(equalTo: date.bottomAnchor, constant: 2)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ message: SMSMessage) {
        sender.stringValue = message.sender
        date.stringValue = message.timestamp
        preview.stringValue = message.body.replacingOccurrences(of: "\n", with: " ")
        setAccessibilityLabel("\(message.sender)，\(message.timestamp)，\(preview.stringValue)")
    }
}

@MainActor
final class ModuleFeaturesWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    let model: GuardModel
    let appIcon: NSImageView
    let tabs = NSTabView()
    let current = NSTextField(labelWithString: "当前模式：尚未读取")
    let mode = NSPopUpButton()
    let ready = NSButton(checkboxWithTitle: "我已准备目标驱动、备用网络和恢复方式", target: nil, action: nil)
    let apply = NSButton(title: "应用模式并重启模块…", target: nil, action: nil)
    let refresh = NSButton(title: "读取当前模式", target: nil, action: nil)
    let modeStatus = NSTextField(wrappingLabelWithString: "")
    let storage = NSPopUpButton()
    let allowRead = NSButton(checkboxWithTitle: "保留未读失败时，允许模块标记已读", target: nil, action: nil)
    let automatic = NSButton(checkboxWithTitle: "此窗口打开时每 15 秒刷新", target: nil, action: nil)
    let read = NSButton(title: "刷新短信", target: nil, action: nil)
    let clear = NSButton(title: "清空显示", target: nil, action: nil)
    let smsStatus = NSTextField(wrappingLabelWithString: "")
    let messageCount = NSTextField(labelWithString: "收件箱 · 0 条")
    let messageList = NSTableView()
    let sender = NSTextField(labelWithString: "选择左侧短信查看")
    let messageDate = NSTextField(labelWithString: "")
    let body = NSTextView()
    private var displayedMessages: [SMSMessage] = []
    private var pendingSMSLoad = false
    private let smsRequest: (String, Bool) -> Void
    private var subscription: AnyCancellable?
    private var timer: Timer?
    init(model: GuardModel, applicationIcon: NSImage? = nil, smsRequest: ((String, Bool) -> Void)? = nil) {
        self.model = model; appIcon = AppBranding.imageView(image: applicationIcon)
        self.smsRequest = smsRequest ?? { storage, permitted in
            Task { await model.refreshSMS(storage:storage,allowMarkRead:permitted) }
        }
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:660,height:652),
            styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "MacDou · 4G 模块功能"; window.minSize = NSSize(width:620,height:632)
        window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self; window.center()
        let root = FeatureWindowBackground(); window.contentView = root
        let title = NSTextField(labelWithString: "MacDou · 4G 模块"); title.font = .systemFont(ofSize: 20, weight: .semibold)
        let heading = NSStackView(views: [appIcon, title]); heading.spacing = 12; heading.alignment = .centerY
        heading.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(heading)
        NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:24), heading.topAnchor.constraint(equalTo:root.topAnchor,constant:16)])
        tabs.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(tabs)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16), tabs.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16), tabs.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:12), tabs.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-16)])
        let modePage = page("网卡模式"), smsPage = page("短信")
        let modeStack = stack(in:modePage)
        current.font = .systemFont(ofSize:17,weight:.semibold)
        mode.addItems(withTitles:USBNetworkMode.names)
        for v in [current, mode, refresh] as [NSView] { modeStack.addArrangedSubview(v) }
        let warning = NSTextField(wrappingLabelWithString:USBNetworkMode.warning)
        warning.font = .systemFont(ofSize:12); modeStack.addArrangedSubview(warning)
        warning.widthAnchor.constraint(equalTo:modeStack.widthAnchor).isActive = true
        modeStack.addArrangedSubview(ready); modeStack.addArrangedSubview(apply); modeStack.addArrangedSubview(modeStatus)
        modeStatus.widthAnchor.constraint(equalTo:modeStack.widthAnchor).isActive = true
        modeStatus.font = .systemFont(ofSize:12)
        refresh.target = self; refresh.action = #selector(refreshModes)
        apply.target = self; apply.action = #selector(applyMode)
        ready.target = self; ready.action = #selector(render)
        mode.target = self; mode.action = #selector(render)

        let smsStack = stack(in:smsPage)
        let privacy = NSTextField(wrappingLabelWithString:"打开短信页后自动读取，切换 ME/SM 也会自动加载。默认尝试保留未读；若固件不支持，勾选下方许可后自动重试。短信仅在内存中显示，关闭窗口或睡眠后清空；不会发送或删除。")
        privacy.font = .systemFont(ofSize:12); smsStack.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo:smsStack.widthAnchor).isActive = true
        storage.addItems(withTitles:["模块存储 ME", "SIM 卡存储 SM"])
        storage.target = self; storage.action = #selector(storageChanged)
        let actions = NSStackView(views:[storage,read,clear]); actions.spacing = 8
        smsStack.addArrangedSubview(actions)
        smsStack.addArrangedSubview(allowRead); smsStack.addArrangedSubview(automatic)
        smsStack.addArrangedSubview(smsStatus)
        smsStatus.font = .systemFont(ofSize:12); smsStatus.widthAnchor.constraint(equalTo:smsStack.widthAnchor).isActive = true
        read.target = self; read.action = #selector(readMessages)
        clear.target = self; clear.action = #selector(clearDisplay)
        clear.toolTip = "只清空本窗口显示，不删除模块或 SIM 卡中的短信。"
        allowRead.target = self; allowRead.action = #selector(permissionChanged)
        allowRead.toolTip = "默认保留未读。固件不支持时勾选此项会自动重试；定时刷新也会使用此许可。"
        automatic.toolTip = "仅窗口打开且停留在短信页时刷新；关闭窗口会停止，并清空屏幕上的短信。"

        let inbox = NSView(); inbox.translatesAutoresizingMaskIntoConstraints = false
        smsStack.addArrangedSubview(inbox)
        let listPanel = NSView(), detailPanel = NSView()
        for panel in [listPanel, detailPanel] { panel.translatesAutoresizingMaskIntoConstraints = false; inbox.addSubview(panel) }
        NSLayoutConstraint.activate([
            inbox.widthAnchor.constraint(equalTo:smsStack.widthAnchor),
            inbox.heightAnchor.constraint(greaterThanOrEqualToConstant:240),
            smsStack.bottomAnchor.constraint(equalTo:smsPage.bottomAnchor,constant:-16),
            listPanel.leadingAnchor.constraint(equalTo:inbox.leadingAnchor),
            listPanel.topAnchor.constraint(equalTo:inbox.topAnchor),
            listPanel.bottomAnchor.constraint(equalTo:inbox.bottomAnchor),
            listPanel.widthAnchor.constraint(equalToConstant:216),
            detailPanel.leadingAnchor.constraint(equalTo:listPanel.trailingAnchor,constant:12),
            detailPanel.trailingAnchor.constraint(equalTo:inbox.trailingAnchor),
            detailPanel.topAnchor.constraint(equalTo:inbox.topAnchor),
            detailPanel.bottomAnchor.constraint(equalTo:inbox.bottomAnchor)
        ])
        messageCount.font = .systemFont(ofSize:12, weight:.semibold)
        messageCount.translatesAutoresizingMaskIntoConstraints = false; listPanel.addSubview(messageCount)
        let listScroll = NSScrollView(); listScroll.hasVerticalScroller = true; listScroll.borderType = .bezelBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false; listPanel.addSubview(listScroll)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("sms")); column.title = "短信"
        messageList.addTableColumn(column); messageList.headerView = nil
        messageList.rowHeight = 58; messageList.intercellSpacing = NSSize(width:0,height:1)
        messageList.allowsMultipleSelection = false; messageList.dataSource = self; messageList.delegate = self
        messageList.setAccessibilityLabel("收到的短信列表")
        listScroll.documentView = messageList
        NSLayoutConstraint.activate([
            messageCount.leadingAnchor.constraint(equalTo:listPanel.leadingAnchor),
            messageCount.topAnchor.constraint(equalTo:listPanel.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo:listPanel.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo:listPanel.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo:messageCount.bottomAnchor,constant:6),
            listScroll.bottomAnchor.constraint(equalTo:listPanel.bottomAnchor)
        ])
        sender.font = .systemFont(ofSize:15,weight:.semibold)
        messageDate.font = .systemFont(ofSize:11); messageDate.textColor = .secondaryLabelColor
        for label in [sender,messageDate] { label.translatesAutoresizingMaskIntoConstraints = false; detailPanel.addSubview(label) }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false; detailPanel.addSubview(scroll)
        body.isEditable = false; body.isSelectable = true; body.isRichText = false; body.font = .systemFont(ofSize:14)
        body.textContainerInset = NSSize(width:12,height:12); body.autoresizingMask = [.width]
        body.frame = NSRect(x:0,y:0,width:350,height:240)
        body.minSize = .zero; body.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        body.isVerticallyResizable = true; body.isHorizontallyResizable = false
        body.textContainer?.widthTracksTextView = true
        body.setAccessibilityLabel("选中短信的正文")
        scroll.documentView = body
        NSLayoutConstraint.activate([
            sender.leadingAnchor.constraint(equalTo:detailPanel.leadingAnchor),
            sender.trailingAnchor.constraint(equalTo:detailPanel.trailingAnchor),
            sender.topAnchor.constraint(equalTo:detailPanel.topAnchor),
            messageDate.leadingAnchor.constraint(equalTo:sender.leadingAnchor),
            messageDate.trailingAnchor.constraint(equalTo:sender.trailingAnchor),
            messageDate.topAnchor.constraint(equalTo:sender.bottomAnchor,constant:4),
            scroll.leadingAnchor.constraint(equalTo:detailPanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo:detailPanel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo:messageDate.bottomAnchor,constant:8),
            scroll.bottomAnchor.constraint(equalTo:detailPanel.bottomAnchor)
        ])
        tabs.delegate = self
        subscription = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
        render()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func page(_ label:String) -> NSView {
        let item = NSTabViewItem(identifier:label); item.label = label; item.view = NSView(); tabs.addTabViewItem(item); return item.view!
    }
    private func stack(in view:NSView) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:16)])
        return stack
    }
    func open(tab:Int) {
        let wasVisible = window?.isVisible == true
        let wasSelected = tabs.selectedTabViewItem === tabs.tabViewItem(at:tab)
        if !wasSelected { tabs.selectTabViewItem(at:tab) }
        showWindow(nil); NSApp.activate(ignoringOtherApps:true)
        if tab == 0 { refreshModes() }
        if tab == 1 && (!wasVisible || wasSelected) { readMessages() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true, self.tabs.indexOfTabViewItem(self.tabs.selectedTabViewItem!) == 1, self.automatic.state == .on else { return }
                self.readMessages()
            }
        }
    }
    func tabView(_ tabView:NSTabView,didSelect tabViewItem:NSTabViewItem?) {
        guard let tabViewItem, window?.isVisible == true, tabView.indexOfTabViewItem(tabViewItem) == 1 else { return }
        readMessages()
    }
    func windowWillClose(_ notification:Notification) { timer?.invalidate(); pendingSMSLoad = false; automatic.state = .off; allowRead.state = .off; model.clearMessages(); render() }
    @objc func render() {
        let info = model.modeInfo
        current.stringValue = "当前模式：" + (info?.usbnet.flatMap { (0...3).contains($0) ? USBNetworkMode.names[$0] : nil } ?? "尚未读取")
        modeStatus.stringValue = model.featureStatus
        refresh.isEnabled = model.canUseFeatures
        apply.isEnabled = model.canUseFeatures && ready.state == .on && info?.usbnet != nil && info?.usbnet != mode.indexOfSelectedItem && ((info?.supportedModes ?? 0) & (1 << mode.indexOfSelectedItem)) != 0
        read.isEnabled = model.canUseFeatures; storage.isEnabled = !model.featureBusy
        allowRead.isEnabled = !model.featureBusy
        smsStatus.stringValue = model.smsStatus
        clear.isEnabled = !model.messages.isEmpty
        if displayedMessages != model.messages {
            let selected = displayedMessages.indices.contains(messageList.selectedRow) ? displayedMessages[messageList.selectedRow] : nil
            displayedMessages = model.messages
            messageList.reloadData()
            if !displayedMessages.isEmpty {
                let row = selected.flatMap { previous in
                    displayedMessages.firstIndex { $0.index == previous.index && $0.sender == previous.sender && $0.timestamp == previous.timestamp }
                } ?? 0
                messageList.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            } else { messageList.deselectAll(nil) }
        }
        messageCount.stringValue = "收件箱 · \(model.messages.count) 条"
        updateSelectedMessage()
        if pendingSMSLoad, model.canUseFeatures, window?.isVisible == true,
           let selected = tabs.selectedTabViewItem, tabs.indexOfTabViewItem(selected) == 1 {
            pendingSMSLoad = false
            DispatchQueue.main.async { [weak self] in self?.readMessages() }
        }
    }
    @objc func refreshModes() {
        Task { await model.refreshModeInfo(); if let value = model.modeInfo?.usbnet, (0...3).contains(value) { mode.selectItem(at:value) }; render() }
    }
    @objc func applyMode() {
        guard apply.isEnabled, let expected = model.modeInfo?.usbnet else { return }
        let target = mode.indexOfSelectedItem, alert = NSAlert()
        alert.messageText = "切换为 \(USBNetworkMode.names[target])？"
        alert.informativeText = USBNetworkMode.warning
        alert.alertStyle = .warning; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"切换并重启模块")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
        alert.window.initialFirstResponder = alert.buttons[0]
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        ready.state = .off; automatic.state = .off
        Task { await model.applyMode(target,expected:expected) }
    }
    @objc func storageChanged() { model.clearMessages(); render(); readMessages() }
    @objc func clearDisplay() { pendingSMSLoad = false; model.clearMessages(); render() }
    @objc func permissionChanged() { readMessages() }
    @objc func readMessages() {
        guard model.canUseFeatures else {
            pendingSMSLoad = true
            model.smsStatus = "等待 4G 模块可用，随后自动载入短信。"
            return
        }
        pendingSMSLoad = false
        let selected = storage.indexOfSelectedItem == 0 ? "ME" : "SM", permitted = allowRead.state == .on
        smsRequest(selected,permitted)
    }
    func numberOfRows(in tableView:NSTableView) -> Int { displayedMessages.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SMSInboxRow")
        let cell = tableView.makeView(withIdentifier:identifier,owner:self) as? SMSInboxRow ?? SMSInboxRow(frame:.zero)
        cell.identifier = identifier
        cell.show(displayedMessages[row])
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updateSelectedMessage() }
    private func updateSelectedMessage() {
        let row = messageList.selectedRow
        guard displayedMessages.indices.contains(row) else {
            sender.stringValue = "选择左侧短信查看"; messageDate.stringValue = ""
            let text = "打开短信页后自动载入。收到的短信会列在左侧。"
            if body.string != text { body.string = text }
            return
        }
        let message = displayedMessages[row]
        sender.stringValue = message.sender
        messageDate.stringValue = message.timestamp
        if body.string != message.body { body.string = message.body }
    }
}
