import AppKit

final class SplitView: NSSplitView {
    override var dividerThickness: CGFloat { 2 }
    override var dividerColor: NSColor { Theme.divider }
}

/// 탭 하나 = 창 하나. 맥 기본 탭 기능으로 여러 창을 한 창에 탭으로 합친다.
/// 창 안은 NSSplitView를 중첩해서 화면을 나눈다.
final class TermWindow: NSWindow, NSWindowDelegate, PaneViewDelegate {
    var onChange: (() -> Void)?
    /// 패널을 떼어내 새 탭으로 만들 때 (AppDelegate가 창을 만든다)
    var onNewTab: ((PaneView) -> Void)?
    /// 패널의 작업 상태가 바뀔 때 (알림, 독 배지)
    var onAgentState: ((PaneView) -> Void)?

    private let root = NSView()
    private(set) var focusedPane: PaneView?

    init(layout: SavedNode?, adopting pane: PaneView? = nil) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        tabbingMode = .preferred
        tabbingIdentifier = "TermHub"
        isRestorable = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Theme.background
        minSize = NSSize(width: 400, height: 250)
        delegate = self
        contentView = root

        if let pane {
            pane.delegate = self
            setRoot(pane)
        } else {
            setRoot(build(layout ?? .pane(name: nil, cwd: nil)))
        }
        if let layout { DispatchQueue.main.async { self.applyRatios(layout, to: self.rootChild) } }
        focus(panes.first)
        updateTitle()
    }

    // MARK: 트리 구성

    private var rootChild: NSView? { root.subviews.first }

    private func setRoot(_ view: NSView) {
        root.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    private func build(_ node: SavedNode) -> NSView {
        switch node {
        case let .pane(name, cwd):
            return makePane(name: name, cwd: cwd)
        case let .split(vertical, _, children):
            let split = makeSplit(vertical: vertical)
            for c in children { split.addArrangedSubview(build(c)) }
            return split
        }
    }

    private func makePane(name: String? = nil, cwd: String?) -> PaneView {
        let p = PaneView(name: name, cwd: cwd)
        p.delegate = self
        p.start()
        return p
    }

    private func makeSplit(vertical: Bool) -> SplitView {
        let s = SplitView()
        s.isVertical = vertical
        s.dividerStyle = .thin
        return s
    }

    var panes: [PaneView] {
        func collect(_ v: NSView?) -> [PaneView] {
            if let p = v as? PaneView { return [p] }
            if let s = v as? NSSplitView { return s.arrangedSubviews.flatMap(collect) }
            return []
        }
        return collect(rootChild)
    }

    func snapshot() -> SavedNode {
        func snap(_ v: NSView) -> SavedNode {
            if let p = v as? PaneView {
                return .pane(name: p.customName, cwd: p.currentDirectory())
            }
            let s = v as! NSSplitView
            let sizes = s.arrangedSubviews.map { Double(s.isVertical ? $0.frame.width : $0.frame.height) }
            let total = max(sizes.reduce(0, +), 1)
            return .split(vertical: s.isVertical, ratios: sizes.map { $0 / total }, children: s.arrangedSubviews.map(snap))
        }
        return rootChild.map(snap) ?? .pane(name: nil, cwd: nil)
    }

    private func applyRatios(_ node: SavedNode, to view: NSView?) {
        guard case let .split(_, ratios, children) = node, let s = view as? NSSplitView,
              ratios.count == s.arrangedSubviews.count else { return }
        layoutIfNeededRecursively()
        setPositions(s, ratios: ratios)
        for (c, v) in zip(children, s.arrangedSubviews) { applyRatios(c, to: v) }
    }

    private func equalize(_ s: NSSplitView) {
        let n = s.arrangedSubviews.count
        layoutIfNeededRecursively()
        setPositions(s, ratios: Array(repeating: 1.0 / Double(n), count: n))
    }

    private func setPositions(_ s: NSSplitView, ratios: [Double]) {
        let total = (s.isVertical ? s.bounds.width : s.bounds.height) - s.dividerThickness * CGFloat(ratios.count - 1)
        var pos: CGFloat = 0
        for i in 0..<(ratios.count - 1) {
            pos += CGFloat(ratios[i]) * total
            s.setPosition(pos + s.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
        s.layoutSubtreeIfNeeded()
    }

    private func layoutIfNeededRecursively() {
        root.layoutSubtreeIfNeeded()
    }

    // MARK: 화면 나누기 / 닫기

    func split(vertical: Bool) {
        guard let current = focusedPane ?? panes.first else { return }
        let newPane = makePane(cwd: current.currentDirectory())

        if let parent = current.superview as? NSSplitView, parent.isVertical == vertical {
            let idx = parent.arrangedSubviews.firstIndex(of: current)!
            parent.insertArrangedSubview(newPane, at: idx + 1)
            equalize(parent)
        } else {
            let split = makeSplit(vertical: vertical)
            replace(current, with: split)
            split.addArrangedSubview(current)
            split.addArrangedSubview(newPane)
            equalize(split)
        }
        focus(newPane)
        onChange?()
    }

    private func replace(_ old: NSView, with new: NSView) {
        if let parent = old.superview as? NSSplitView {
            let idx = parent.arrangedSubviews.firstIndex(of: old)!
            let sizes = parent.arrangedSubviews.map { parent.isVertical ? $0.frame.width : $0.frame.height }
            new.frame = old.frame
            old.removeFromSuperview()
            parent.insertArrangedSubview(new, at: idx)
            let total = max(sizes.reduce(0, +), 1)
            setPositions(parent, ratios: sizes.map { Double($0 / total) })
        } else {
            old.removeFromSuperview()
            setRoot(new)
        }
    }

    func closePane(_ pane: PaneView, confirm: Bool = true) {
        if confirm, pane.isBusy, !ask("“\(pane.displayName)” 실행 중이에요. 닫을까요?") { return }
        pane.stop()
        detach(pane)
    }

    /// 트리에서 패널을 빼낸다 (프로세스는 그대로). 마지막 패널이면 탭을 닫는다.
    func detach(_ pane: PaneView) {
        let all = panes
        guard all.count > 1 else {
            pane.removeFromSuperview()
            close()
            return
        }
        let idx = all.firstIndex(of: pane) ?? 0
        removeFromTree(pane)
        let rest = panes
        if focusedPane === pane || focusedPane == nil {
            focusedPane = nil
            focus(rest[min(idx, rest.count - 1)])
        }
        updateTitle()
        onChange?()
    }

    private func removeFromTree(_ view: NSView) {
        guard let parent = view.superview as? NSSplitView else {
            view.removeFromSuperview()
            return
        }
        view.removeFromSuperview()
        if parent.arrangedSubviews.count == 1 {
            let only = parent.arrangedSubviews[0]
            only.removeFromSuperview()
            replace(parent, with: only)
        } else {
            equalize(parent)
        }
    }

    // MARK: 패널 옮기기

    /// `pane`을 `target`의 `edge` 쪽에 끼워 넣는다. 다른 탭에서 온 패널도 받는다.
    func insert(_ pane: PaneView, at target: PaneView, edge: DropEdge) {
        let vertical = edge == .left || edge == .right
        let after = edge == .right || edge == .bottom
        pane.delegate = self
        if let parent = target.superview as? NSSplitView, parent.isVertical == vertical {
            let idx = parent.arrangedSubviews.firstIndex(of: target)!
            parent.insertArrangedSubview(pane, at: after ? idx + 1 : idx)
            equalize(parent)
        } else {
            let split = makeSplit(vertical: vertical)
            replace(target, with: split)
            split.addArrangedSubview(after ? target : pane)
            split.addArrangedSubview(after ? pane : target)
            equalize(split)
        }
    }

    /// 다른 탭으로 보낼 때: 오른쪽 끝에 붙인다.
    func append(_ pane: PaneView) {
        pane.delegate = self
        if let s = rootChild as? NSSplitView, s.isVertical {
            s.addArrangedSubview(pane)
            equalize(s)
        } else if let r = rootChild {
            let split = makeSplit(vertical: true)
            replace(r, with: split)
            split.addArrangedSubview(r)
            split.addArrangedSubview(pane)
            equalize(split)
        } else {
            setRoot(pane)
        }
        afterMove(pane)
    }

    private func afterMove(_ pane: PaneView) {
        makeKeyAndOrderFront(nil)
        focusedPane = nil
        focus(pane)
        updateTitle()
        onChange?()
    }

    /// 두 패널 자리 바꾸기 (같은 탭 안이든 다른 탭이든).
    private func swap(_ a: PaneView, _ b: PaneView) {
        let wa = a.window as? TermWindow, wb = b.window as? TermWindow
        let holderA = NSView(), holderB = NSView()
        Self.replaceAnywhere(a, with: holderA)
        Self.replaceAnywhere(b, with: holderB)
        Self.replaceAnywhere(holderA, with: b)
        Self.replaceAnywhere(holderB, with: a)
        a.delegate = wb
        b.delegate = wa
        if let wa, wa !== wb {
            wa.focusedPane = nil
            wa.focus(b)
            wa.updateTitle()
        }
    }

    private static func replaceAnywhere(_ old: NSView, with new: NSView) {
        if let w = old.window as? TermWindow { w.replace(old, with: new) }
    }

    func moveToNewTab(_ pane: PaneView) {
        guard panes.count > 1 else { return }
        detach(pane)
        onNewTab?(pane)
    }

    func move(_ pane: PaneView, toTab other: TermWindow) {
        guard other !== self else { return }
        detach(pane)
        other.append(pane)
    }

    func closeFocusedPane() {
        if let p = focusedPane ?? panes.first { closePane(p) }
    }

    func focusNext(_ delta: Int) {
        let all = panes
        guard let cur = focusedPane, let i = all.firstIndex(of: cur) else { return }
        focus(all[(i + delta + all.count) % all.count])
    }

    func focus(_ pane: PaneView?) {
        guard let pane else { return }
        makeFirstResponder(pane.terminal)
    }

    func rename(_ pane: PaneView) {
        let alert = NSAlert()
        alert.messageText = "터미널 이름"
        alert.informativeText = "비워두면 실행 중인 프로그램 이름이 표시돼요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pane.customName ?? ""
        field.placeholderString = "예: 클로드"
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: self) { resp in
            if resp == .alertFirstButtonReturn {
                let v = field.stringValue.trimmingCharacters(in: .whitespaces)
                pane.customName = v.isEmpty ? nil : v
                self.onChange?()
            }
            self.focus(pane)
        }
    }

    func refreshTitles() {
        let changed = panes.map { $0.refreshHeader() }.contains(true)
        if changed { updateTitle() }
    }

    private func updateTitle() {
        let names = panes.map(\.displayName).joined(separator: " · ")
        let t = panes.contains { $0.agentState == .attention } ? "● " + names : names
        if title != t { title = t }
    }

    func applyFont() {
        panes.forEach { $0.applyFont() }
    }

    private func ask(_ message: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "닫기")
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: 포커스 추적

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if let v = firstResponder as? NSView {
            var cur: NSView? = v
            while let c = cur, !(c is PaneView) { cur = c.superview }
            if let p = cur as? PaneView {
                if p !== focusedPane {
                    focusedPane = p
                    panes.forEach { $0.isFocused = ($0 === p) }
                }
                if isKeyWindow { p.acknowledge() }
            }
        }
        return ok
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = panes.filter(\.isBusy)
        if busy.isEmpty { return true }
        return ask("이 탭에서 \(busy.map(\.displayName).joined(separator: ", ")) 실행 중이에요. 탭을 닫을까요?")
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.stop() }
        DispatchQueue.main.async { self.onChange?() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let p = focusedPane {
            makeFirstResponder(p.terminal)
            p.acknowledge()
        }
    }

    // MARK: PaneViewDelegate

    func paneDidChangeTitle(_ pane: PaneView) { updateTitle() }

    func paneDidChangeAgentState(_ pane: PaneView) {
        updateTitle()
        onAgentState?(pane)
    }

    func paneIsWatched(_ pane: PaneView) -> Bool {
        NSApp.isActive && isKeyWindow && focusedPane === pane
    }
    func paneDidExit(_ pane: PaneView) {
        guard !pane.stopped, pane.superview != nil, isVisible else { return }
        closePane(pane, confirm: false)
    }
    func paneWantsFocus(_ pane: PaneView) { focus(pane) }
    func paneWantsRename(_ pane: PaneView) { rename(pane) }

    func paneWantsSplit(_ pane: PaneView, vertical: Bool) {
        focusedPane = pane
        split(vertical: vertical)
    }

    func paneWantsClose(_ pane: PaneView) { closePane(pane) }

    func pane(_ target: PaneView, didReceive moved: PaneView, at edge: DropEdge) {
        guard let source = moved.window as? TermWindow, target.window === self else { return }
        if edge == .center {
            swap(moved, target)
            source.onChange?()
            afterMove(moved)
            return
        }
        source.detach(moved)
        insert(moved, at: target, edge: edge)
        afterMove(moved)
    }

    func paneMenu(_ pane: PaneView) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ symbol: String?, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(i)
        }
        add("오른쪽에 터미널 추가", "rectangle.split.2x1") { [weak self] in self?.paneWantsSplit(pane, vertical: true) }
        add("아래에 터미널 추가", "rectangle.split.1x2") { [weak self] in self?.paneWantsSplit(pane, vertical: false) }
        m.addItem(.separator())
        add("이름 바꾸기…", "pencil") { [weak self] in self?.rename(pane) }
        m.addItem(.separator())

        let others = (tabGroup?.windows ?? []).compactMap { $0 as? TermWindow }.filter { $0 !== self }
        let send = NSMenuItem(title: "다른 탭으로 보내기", action: nil, keyEquivalent: "")
        send.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: nil)
        let sub = NSMenu()
        for (i, w) in others.enumerated() {
            sub.addItem(ClosureMenuItem(title: "\(i + 1). \(w.title)") { [weak self] in self?.move(pane, toTab: w) })
        }
        if others.isEmpty {
            let none = NSMenuItem(title: "다른 탭이 없어요", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        send.submenu = sub
        m.addItem(send)
        let tear = ClosureMenuItem(title: "새 탭으로 떼어내기") { [weak self] in self?.moveToNewTab(pane) }
        tear.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
        if panes.count <= 1 { tear.isEnabled = false; tear.action = nil }
        m.addItem(tear)
        m.addItem(.separator())
        add("닫기", "xmark") { [weak self] in self?.closePane(pane) }
        return m
    }
}

/// 클로저로 동작하는 메뉴 항목.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
