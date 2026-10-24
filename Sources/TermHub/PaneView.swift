import AppKit
import SwiftTerm

protocol PaneViewDelegate: AnyObject {
    func paneDidChangeTitle(_ pane: PaneView)
    func paneDidExit(_ pane: PaneView)
    func paneWantsFocus(_ pane: PaneView)
    func paneWantsRename(_ pane: PaneView)
    func paneWantsSplit(_ pane: PaneView, vertical: Bool)
    func paneWantsClose(_ pane: PaneView)
    func paneMenu(_ pane: PaneView) -> NSMenu
    /// 다른 패널(`moved`)을 이 패널의 `edge` 쪽에 놓았을 때.
    func pane(_ target: PaneView, didReceive moved: PaneView, at edge: DropEdge)
    func paneDidChangeAgentState(_ pane: PaneView)
    /// 사용자가 지금 이 패널을 보고 있는지 (앱 활성 + 이 탭 + 포커스)
    func paneIsWatched(_ pane: PaneView) -> Bool
}

/// 에이전트 상태. 출력이 계속 나오면 working, 멈추면 attention(완료/입력 대기).
enum AgentState { case idle, working, attention }

/// 패널을 끌어다 놓을 위치. center는 두 패널 자리 바꾸기.
enum DropEdge { case left, right, top, bottom, center }

extension NSPasteboard.PasteboardType {
    static let termHubPane = NSPasteboard.PasteboardType("com.chogunhwy.termhub.pane")
}

enum Theme {
    static let background = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1)
    static let headerIdle = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    static let headerFocused = NSColor.controlAccentColor.withAlphaComponent(0.85)
    static let headerAttention = NSColor.systemGreen.withAlphaComponent(0.22)
    static let divider = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1)
    static var fontSize: CGFloat = 13
    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
}

/// 터미널 하나 = 위쪽 이름표 + 터미널 화면.
final class PaneView: NSView, LocalProcessTerminalViewDelegate {
    weak var delegate: PaneViewDelegate?

    let terminal: AgentTerminalView
    let id = UUID()
    private let header = PaneHeader()
    private var terminalTitle: String?
    /// 셸 아래에서 실행 중인 프로그램 이름. refreshHeader에서만 새로 조회한다.
    private var childName: String?
    private var titleRefreshPending = false
    private(set) var cwd: String?

    /// 사용자가 직접 붙인 이름. 없으면 실행 중인 프로그램/터미널 제목을 보여준다.
    var customName: String? {
        didSet { refreshHeader(); delegate?.paneDidChangeTitle(self) }
    }

    var isFocused = false {
        didSet { header.focused = isFocused }
    }

    var displayName: String {
        if let n = customName, !n.isEmpty { return n }
        if let child = childName {
            if let t = terminalTitle, !t.isEmpty { return t }
            return child
        }
        return (Shell.path as NSString).lastPathComponent
    }

    init(name: String? = nil, cwd: String? = nil) {
        terminal = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        self.cwd = cwd
        self.customName = name
        super.init(frame: .zero)

        terminal.font = Theme.font
        terminal.nativeBackgroundColor = Theme.background
        terminal.nativeForegroundColor = Theme.foreground
        terminal.caretColor = .systemGray
        terminal.processDelegate = self
        terminal.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.paneWantsFocus(self)
        }
        header.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.delegate?.paneWantsRename(self)
        }
        header.onSplit = { [weak self] vertical in
            guard let self else { return }
            self.delegate?.paneWantsSplit(self, vertical: vertical)
        }
        header.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.paneWantsClose(self)
        }
        header.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.paneMenu(self)
        }
        header.pane = self

        terminal.onOutput = { [weak self] in self?.handleOutput() }
        terminal.onInput = { [weak self] in self?.handleInput() }
        terminal.onBell = { [weak self] in self?.raiseAttention(message: nil) }
        terminal.onNotify = { [weak self] msg in self?.raiseAttention(message: msg) }

        addSubview(header)
        addSubview(terminal)
        addSubview(dropOverlay)
        registerForDraggedTypes([.termHubPane])
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        refreshHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        let shell = Shell.path
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: Shell.environment,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: dir
        )
        cwd = dir
        refreshHeader()
    }

    private(set) var stopped = false

    func stop() {
        guard !stopped else { return }
        stopped = true
        let pid = terminal.process.shellPid
        terminal.process.terminate()
        if pid > 0 { kill(pid, SIGHUP) }
    }

    var isBusy: Bool { Shell.hasRunningChild(terminal.process.shellPid) }

    func currentDirectory() -> String? {
        Shell.cwd(of: terminal.process.shellPid) ?? cwd
    }

    func applyFont() {
        terminal.font = Theme.font
    }

    /// 실행 중인 프로그램 이름은 터미널 제목 변경 없이도 바뀌므로 주기적으로 새로고침한다.
    /// 표시 이름이 바뀌었으면 true.
    @discardableResult
    func refreshHeader() -> Bool {
        let pid = terminal.process?.shellPid ?? 0
        if let d = Shell.cwd(of: pid) { cwd = d }
        childName = Shell.childName(pid)
        let old = header.title
        header.title = displayName
        header.subtitle = cwd.map(Shell.abbreviate) ?? ""
        return header.title != old
    }

    // MARK: 작업 상태 감지

    /// 출력이 이만큼 계속되면 "작업 중"으로 본다 (키 입력에 대한 화면 갱신과 구분)
    static let workingAfter: TimeInterval = 1.5
    /// 출력이 이만큼 멈추면 "끝남"으로 본다
    static let quietAfter: TimeInterval = 3

    private(set) var agentState: AgentState = .idle {
        didSet {
            guard agentState != oldValue else { return }
            header.state = agentState
            delegate?.paneDidChangeAgentState(self)
        }
    }
    /// 마지막 알림 메시지 (벨/OSC 알림에서 온 것)
    private(set) var attentionMessage: String?
    private var lastInput = Date.distantPast
    private var burstStart: Date?
    private var quietTimer: Timer?

    private func handleInput() {
        lastInput = Date()
        if agentState == .attention { agentState = .idle }
    }

    private func handleOutput() {
        let now = Date()
        // 방금 친 글자가 화면에 다시 그려지는 것은 작업이 아님
        guard now.timeIntervalSince(lastInput) > 0.5 else { return }
        // 셸 프롬프트만 떠 있을 때(실행 중인 프로그램 없음)는 무시.
        // 출력마다 프로세스를 조회하지 않도록 refreshHeader에서 저장한 값을 쓴다.
        guard childName != nil else { return }

        if burstStart == nil { burstStart = now }
        if agentState != .working, now.timeIntervalSince(burstStart!) >= Self.workingAfter {
            agentState = .working
        }
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietAfter, repeats: false) { [weak self] _ in
            self?.outputWentQuiet()
        }
    }

    private func outputWentQuiet() {
        burstStart = nil
        guard agentState == .working else { return }
        raiseAttention(message: nil)
    }

    /// 끝났거나 입력을 기다림. 사용자가 이 패널을 보고 있으면 굳이 표시하지 않는다.
    private func raiseAttention(message: String?) {
        quietTimer?.invalidate()
        burstStart = nil
        attentionMessage = message
        if delegate?.paneIsWatched(self) == true {
            agentState = .idle
        } else if agentState == .attention {
            delegate?.paneDidChangeAgentState(self) // 새 메시지
        } else {
            agentState = .attention
        }
    }

    /// 사용자가 패널을 봤으면 완료 표시를 지운다.
    func acknowledge() {
        if agentState == .attention { agentState = .idle }
    }

    // MARK: 드래그로 옮겨 오기

    /// 지금 끌고 있는 패널. 같은 앱 안에서만 쓰므로 붙여넣기판 대신 메모리로 넘긴다.
    static weak var dragging: PaneView?

    private let dropOverlay = DropOverlay()
    private var dropEdge: DropEdge?

    private func edge(for sender: NSDraggingInfo) -> DropEdge? {
        guard let moved = PaneView.dragging, moved !== self else { return nil }
        let p = convert(sender.draggingLocation, from: nil)
        let x = p.x / max(bounds.width, 1)
        let y = isFlipped ? p.y / max(bounds.height, 1) : 1 - p.y / max(bounds.height, 1) // y: 0=위
        if abs(x - 0.5) < 0.2 && abs(y - 0.5) < 0.2 { return .center }
        let d = [(DropEdge.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return d.min { $0.1 < $1.1 }!.0
    }

    private func showDrop(_ e: DropEdge?) {
        dropEdge = e
        guard let e else { dropOverlay.isHidden = true; return }
        var r = bounds
        switch e {
        case .left: r.size.width /= 2
        case .right: r.size.width /= 2; r.origin.x += r.width
        case .top: r.size.height /= 2; if !isFlipped { r.origin.y += r.height }
        case .bottom: r.size.height /= 2; if isFlipped { r.origin.y += r.height }
        case .center: break
        }
        dropOverlay.frame = r.insetBy(dx: 3, dy: 3)
        dropOverlay.label = e == .center ? "자리 바꾸기" : ""
        dropOverlay.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let e = edge(for: sender)
        if e != dropEdge { showDrop(e) }
        return e == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showDrop(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { showDrop(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let e = dropEdge
        showDrop(nil)
        guard let e, let moved = PaneView.dragging, moved !== self else { return false }
        PaneView.dragging = nil
        DispatchQueue.main.async { self.delegate?.pane(self, didReceive: moved, at: e) }
        return true
    }

    /// 끌 때 보여줄 미리보기 이미지.
    func snapshotImage() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard title != terminalTitle else { return }
        terminalTitle = title
        // 스피너처럼 제목을 1초에 여러 번 바꾸는 프로그램이 있어서 0.25초씩 몰아서 반영한다
        guard !titleRefreshPending else { return }
        titleRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.titleRefreshPending = false
            if self.refreshHeader() { self.delegate?.paneDidChangeTitle(self) }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory, let url = URL(string: directory), url.isFileURL {
            cwd = url.path
        } else if let directory {
            cwd = directory
        }
        refreshHeader()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.paneDidExit(self)
        }
    }
}

/// 터미널 위의 이름표. 포커스된 패널은 강조 색으로 표시.
/// 끌어서 패널 옮기기, 우클릭 메뉴, 추가/닫기 버튼.
final class PaneHeader: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onSplit: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    weak var pane: PaneView?

    var title = "" { didSet { if title != oldValue { titleLabel.stringValue = title } } }
    var subtitle = "" { didSet { if subtitle != oldValue { subtitleLabel.stringValue = subtitle } } }
    var focused = false { didSet { updateColors() } }
    var state: AgentState = .idle { didSet { updateState() } }

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private lazy var splitRightButton = button("rectangle.split.2x1", "오른쪽에 터미널 추가 (⌘D)", #selector(splitRight))
    private lazy var splitDownButton = button("rectangle.split.1x2", "아래에 터미널 추가 (⇧⌘D)", #selector(splitDown))
    private lazy var closeButton = button("xmark", "이 터미널 닫기 (⌘W)", #selector(close))
    private var dragOrigin: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingHead
        subtitleLabel.alignment = .right
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        let titleStack = NSStackView(views: [titleLabel, spinner, statusLabel])
        titleStack.spacing = 6
        let buttons = NSStackView(views: [splitRightButton, splitDownButton, closeButton])
        buttons.spacing = 2
        for v in [titleStack, subtitleLabel, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleStack.trailingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "끌어서 옮기기 · 더블클릭으로 이름 바꾸기 · 우클릭으로 메뉴"
        updateColors()
        updateState()
    }

    private func updateState() {
        switch state {
        case .idle:
            spinner.stopAnimation(nil)
            statusLabel.isHidden = true
        case .working:
            spinner.startAnimation(nil)
            statusLabel.isHidden = true
        case .attention:
            spinner.stopAnimation(nil)
            statusLabel.stringValue = "● 완료"
            statusLabel.isHidden = false
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!
        let b = NSButton(image: img, target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setButtonType(.momentaryChange)
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    @objc private func splitRight() { onSplit?(true) }
    @objc private func splitDown() { onSplit?(false) }
    @objc private func close() { onClose?() }

    private func updateColors() {
        let bg = focused ? Theme.headerFocused : state == .attention ? Theme.headerAttention : Theme.headerIdle
        layer?.backgroundColor = bg.cgColor
        statusLabel.textColor = focused ? .white : .systemGreen
        titleLabel.textColor = focused ? .white : NSColor(white: 0.75, alpha: 1)
        subtitleLabel.textColor = focused ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0.5, alpha: 1)
        let tint = focused ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0.6, alpha: 1)
        [splitRightButton, splitDownButton, closeButton].forEach { $0.contentTintColor = tint }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin, let pane else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 6 else { return }
        dragOrigin = nil

        PaneView.dragging = pane
        let item = NSPasteboardItem()
        item.setString("pane", forType: .termHubPane)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // 패널 모습을 작게 줄여서 커서에 붙인다
        let img = pane.snapshotImage()
        let scale = min(1, 320 / max(img.size.width, 1))
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let local = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: local.x - size.width / 2, y: local.y - size.height / 2,
                                         width: size.width, height: size.height), contents: img)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        PaneView.dragging = nil
    }
}

/// 끌어다 놓을 자리를 파랗게 보여주는 반투명 상자. 마우스 이벤트는 그대로 통과시킨다.
final class DropOverlay: NSView {
    var label = "" { didSet { text.stringValue = label } }
    private let text = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        isHidden = true
        text.font = .systemFont(ofSize: 15, weight: .semibold)
        text.textColor = .white
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
