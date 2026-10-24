import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var titleTimer: Timer?
    private var askedNotificationPermission = false

    /// 보기 메뉴의 "작업 완료 알림" 켜짐 여부
    private var notifyOnDone: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnDone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnDone") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMenu()
        UNUserNotificationCenter.current().delegate = self
        restore()
        NSApp.activate(ignoringOtherApps: true)

        // 실행 중인 프로그램(claude 등)이 바뀌면 이름표에 반영
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.termWindows.forEach { $0.refreshTitles() }
        }
        titleTimer?.tolerance = 0.5
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let w = current, w.isKeyWindow { w.focusedPane?.acknowledge() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = termWindows.flatMap(\.panes).filter(\.isBusy)
        guard !busy.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "실행 중인 터미널이 있어요"
        a.informativeText = busy.map(\.displayName).joined(separator: ", ") + " 을(를) 종료하고 나갈까요?"
        a.addButton(withTitle: "종료")
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        save()
        termWindows.flatMap(\.panes).forEach { $0.stop() }
    }

    // MARK: 창/탭 관리

    /// 탭 순서대로 정렬된 창 목록.
    private var termWindows: [TermWindow] {
        var result: [TermWindow] = []
        for w in NSApp.windows.compactMap({ $0 as? TermWindow }) where w.isVisible || w.isMiniaturized {
            let group = (w.tabGroup?.windows ?? [w]).compactMap { $0 as? TermWindow }
            for g in group where !result.contains(g) { result.append(g) }
        }
        return result
    }

    private var current: TermWindow? {
        (NSApp.keyWindow as? TermWindow) ?? (NSApp.mainWindow as? TermWindow) ?? termWindows.first
    }

    private func makeWindow(_ layout: SavedNode?, adopting pane: PaneView? = nil) -> TermWindow {
        let w = TermWindow(layout: layout, adopting: pane)
        w.onChange = { [weak self] in self?.save() }
        w.onAgentState = { [weak self] pane in self?.agentStateChanged(pane) }
        w.onNewTab = { [weak self, weak w] pane in
            guard let self else { return }
            let tab = self.makeWindow(nil, adopting: pane)
            if let w, w.isVisible { w.addTabbedWindow(tab, ordered: .above) } else { tab.center() }
            tab.makeKeyAndOrderFront(nil)
            tab.focus(pane)
            self.save()
        }
        return w
    }

    private func restore() {
        guard let state = StateStore.load(), !state.tabs.isEmpty else {
            let w = makeWindow(nil)
            w.center()
            w.makeKeyAndOrderFront(nil)
            return
        }
        var windows: [TermWindow] = []
        for tab in state.tabs {
            let w = makeWindow(tab)
            if let last = windows.last {
                last.addTabbedWindow(w, ordered: .above)
            } else {
                if let f = state.frame { w.setFrame(from: f) } else { w.center() }
                w.makeKeyAndOrderFront(nil)
            }
            windows.append(w)
        }
        windows[min(max(state.selectedTab, 0), windows.count - 1)].makeKeyAndOrderFront(nil)
    }

    private func save() {
        let ws = termWindows
        guard !ws.isEmpty else { return StateStore.save(nil) }
        let sel = current.flatMap { ws.firstIndex(of: $0) } ?? 0
        StateStore.save(SavedState(tabs: ws.map { $0.snapshot() }, selectedTab: sel, frame: ws.first?.frameDescriptor))
    }

    // MARK: 작업 완료 알림

    private func agentStateChanged(_ pane: PaneView) {
        let waiting = termWindows.flatMap(\.panes).filter { $0.agentState == .attention }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil

        guard pane.agentState == .attention, notifyOnDone, !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        postNotification(for: pane)
    }

    private func postNotification(for pane: PaneView) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = "\(pane.displayName) 작업이 끝났어요"
            content.body = pane.attentionMessage ?? "확인하거나 다음 지시를 입력해 주세요."
            content.sound = .default
            content.userInfo = ["pane": pane.id.uuidString]
            center.add(UNNotificationRequest(identifier: pane.id.uuidString, content: content, trigger: nil))
        }
        if askedNotificationPermission { return send() }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.askedNotificationPermission = true
                if granted { send() }
            }
        }
    }

    /// 알림을 누르면 그 터미널로 이동.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["pane"] as? String
        DispatchQueue.main.async {
            for w in self.termWindows {
                if let p = w.panes.first(where: { $0.id.uuidString == id }) {
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    w.focus(p)
                    break
                }
            }
            completionHandler()
        }
    }

    @objc func toggleNotifyOnDone(_ sender: NSMenuItem) {
        notifyOnDone.toggle()
        sender.state = notifyOnDone ? .on : .off
    }

    @objc func newWindowForTab(_ sender: Any?) {
        let cwd = current?.focusedPane?.currentDirectory()
        let w = makeWindow(.pane(name: nil, cwd: cwd))
        if let cur = current {
            cur.addTabbedWindow(w, ordered: .above)
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        save()
    }

    @objc func splitRight(_ sender: Any?) { current?.split(vertical: true) }
    @objc func splitDown(_ sender: Any?) { current?.split(vertical: false) }
    @objc func closePane(_ sender: Any?) { current?.closeFocusedPane() }
    @objc func closeTab(_ sender: Any?) { current?.performClose(nil) }
    @objc func nextPane(_ sender: Any?) { current?.focusNext(1) }
    @objc func previousPane(_ sender: Any?) { current?.focusNext(-1) }
    @objc func renamePane(_ sender: Any?) {
        if let w = current, let p = w.focusedPane { w.rename(p) }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let w = current else { return }
        let tabs = w.tabGroup?.windows ?? [w]
        let i = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(i) { tabs[i].makeKeyAndOrderFront(nil) }
    }

    @objc func biggerFont(_ sender: Any?) { setFontSize(Theme.fontSize + 1) }
    @objc func smallerFont(_ sender: Any?) { setFontSize(Theme.fontSize - 1) }
    @objc func resetFont(_ sender: Any?) { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        Theme.fontSize = min(max(size, 9), 32)
        termWindows.forEach { $0.applyFont() }
    }

    // MARK: 메뉴

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        _ = submenu("TermHub", [
            item("TermHub 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("TermHub 가리기", #selector(NSApplication.hide(_:)), "h"),
            item("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("TermHub 종료", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = submenu("터미널", [
            item("새 탭", #selector(newWindowForTab(_:)), "t", target: self),
            .separator(),
            item("오른쪽으로 나누기", #selector(splitRight(_:)), "d", target: self),
            item("아래로 나누기", #selector(splitDown(_:)), "d", [.command, .shift], target: self),
            .separator(),
            item("이름 바꾸기…", #selector(renamePane(_:)), "r", [.command, .shift], target: self),
            .separator(),
            item("패널 닫기", #selector(closePane(_:)), "w", target: self),
            item("탭 닫기", #selector(closeTab(_:)), "w", [.command, .shift], target: self),
        ])

        _ = submenu("편집", [
            item("복사", #selector(NSText.copy(_:)), "c"),
            item("붙여넣기", #selector(NSText.paste(_:)), "v"),
            item("전체 선택", #selector(NSText.selectAll(_:)), "a"),
        ])

        _ = submenu("보기", [
            item("글자 크게", #selector(biggerFont(_:)), "=", target: self),
            item("글자 작게", #selector(smallerFont(_:)), "-", target: self),
            item("기본 크기", #selector(resetFont(_:)), "0", target: self),
            .separator(),
            {
                let i = item("작업 완료 알림", #selector(toggleNotifyOnDone(_:)), target: self)
                i.state = notifyOnDone ? .on : .off
                return i
            }(),
            .separator(),
            item("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        var tabItems: [NSMenuItem] = [
            item("다음 패널", #selector(nextPane(_:)), "]", target: self),
            item("이전 패널", #selector(previousPane(_:)), "[", target: self),
            .separator(),
            item("다음 탭", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
            item("이전 탭", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "마지막 탭" : "\(n)번 탭", #selector(selectTabByNumber(_:)), "\(n)", target: self)
            i.tag = n
            tabItems.append(i)
        }
        tabItems += [.separator(), item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m")]
        NSApp.windowsMenu = submenu("윈도우", tabItems)

        return main
    }
}
