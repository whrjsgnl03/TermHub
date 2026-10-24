import Foundation

/// 앱을 껐다 켜도 탭/화면 나누기 구조를 복원하기 위해 저장하는 형태.
indirect enum SavedNode: Codable {
    case pane(name: String?, cwd: String?)
    case split(vertical: Bool, ratios: [Double], children: [SavedNode])
}

struct SavedState: Codable {
    var tabs: [SavedNode]
    var selectedTab: Int
    var frame: String?
}

enum StateStore {
    /// 테스트용 Dev 빌드는 저장 파일을 따로 쓴다 (쓰고 있는 앱의 레이아웃을 건드리지 않도록)
    private static var folderName: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "TermHub Dev" : "TermHub"
    }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func save(_ state: SavedState?) {
        guard let state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
