import AppKit
import SwiftTerm

/// 출력/입력/벨/알림 신호를 밖으로 알려주는 터미널 뷰.
/// 에이전트(클로드, 안티그래비티 등)가 일하는 중인지, 끝났는지 판단하는 데 쓴다.
final class AgentTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    var onBell: (() -> Void)?
    /// OSC 9 (iTerm2) / OSC 777 (Ghostty) 알림. 메시지 내용을 넘긴다.
    var onNotify: ((String) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if slice.contains(0x1b) { scanNotifications(slice) }
        onOutput?()
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
    }

    override func bell(source: Terminal) {
        onBell?()
    }

    /// `ESC ] 9 ; 메시지 BEL` 과 `ESC ] 777 ; notify ; 제목 ; 내용 BEL` 을 찾는다.
    /// (`ESC ] 9 ; 4 ; …` 는 진행률 표시라서 제외)
    private func scanNotifications(_ slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        var i = 0
        while i + 2 < bytes.count {
            guard bytes[i] == 0x1b, bytes[i + 1] == 0x5d else { i += 1; continue } // ESC ]
            var end = i + 2
            while end < bytes.count, bytes[end] != 0x07, !(bytes[end] == 0x1b && end + 1 < bytes.count && bytes[end + 1] == 0x5c) {
                end += 1
            }
            guard end < bytes.count else { return }
            let body = String(decoding: bytes[(i + 2)..<end], as: UTF8.self)
            if body.hasPrefix("9;"), !body.hasPrefix("9;4;") {
                onNotify?(String(body.dropFirst(2)))
            } else if body.hasPrefix("777;notify;") {
                let parts = body.dropFirst("777;notify;".count).split(separator: ";", maxSplits: 1)
                onNotify?(parts.map(String.init).joined(separator: " — "))
            }
            i = end + 1
        }
    }
}
