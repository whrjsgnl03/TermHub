import Darwin
import Foundation

enum Shell {
    static let path: String = {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
        return "/bin/zsh"
    }()

    /// Finder에서 실행하면 환경 변수가 거의 비어 있어서, 터미널에 필요한 것들을 채워 넣는다.
    static var environment: [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "TermHub"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// 셸 프로세스의 현재 작업 폴더.
    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// 셸 아래에서 뭔가(claude 등) 실행 중인지.
    static func hasRunningChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0
    }

    /// 실행 중인 자식 프로세스 이름 (예: "claude").
    static func childName(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard proc_name(pids[0], &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
