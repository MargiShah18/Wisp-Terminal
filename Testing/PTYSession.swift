import Foundation
import Darwin

final class PTYSession {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let lock = NSLock()
    private(set) var shellPath: String = ""
    private(set) var arguments: [String] = []
    private(set) var initialDirectory: String?

    /// The spawned shell's pid (used to query its working directory via
    /// `proc_pidinfo` since most zsh setups don't emit OSC 7 outside of
    /// Apple's Terminal.app).
    var childPid: pid_t { childPID }

    func start(shellPath: String,
               arguments: [String] = [],
               cols: Int,
               rows: Int,
               environmentOverrides: [String: String] = [:],
               workingDirectory: String? = nil) {
        stop()

        self.shellPath = shellPath
        self.arguments = arguments
        self.initialDirectory = workingDirectory

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(max(rows, 1)),
                           ws_col: UInt16(max(cols, 1)),
                           ws_xpixel: 0,
                           ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.onOutput?(Data("Failed to create PTY.\r\n".utf8))
            }
            return
        }

        // Build environment
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "en_US.UTF-8"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TERM_PROGRAM"] = "SwiftMiniTerm"
        environment.removeValue(forKey: "PROMPT_COMMAND")
        for (k, v) in environmentOverrides { environment[k] = v }

        var envCArrays: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envCArrays.append(nil)
        defer { for ptr in envCArrays { if let p = ptr { free(p) } } }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(master); close(slave)
            return
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let cwd = workingDirectory, FileManager.default.fileExists(atPath: cwd) {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        }

        _ = posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        _ = posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&fileActions, master)
        _ = posix_spawn_file_actions_addclose(&fileActions, slave)

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        let flags: Int16 = Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigemptyset(&allSignals)
        posix_spawnattr_setsigdefault(&attrs, &noSignals)
        posix_spawnattr_setsigmask(&attrs, &allSignals)
        posix_spawnattr_setflags(&attrs, flags)

        let shellName = (shellPath as NSString).lastPathComponent
        // Login shell convention: argv[0] is "-shellName"
        var argvStrings = ["-" + shellName]
        argvStrings.append(contentsOf: arguments)
        var argvC: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argvC.append(nil)
        defer { for p in argvC { if let p = p { free(p) } } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, shellPath, &fileActions, &attrs, &argvC, &envCArrays)

        if result != 0 {
            close(master); close(slave)
            DispatchQueue.main.async { [weak self] in
                self?.onOutput?(Data("Failed to launch shell (\(result)).\r\n".utf8))
            }
            return
        }

        childPID = pid
        masterFD = master
        close(slave)

        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)

        startReading()
        watchExit()
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            let total = rawBuf.count
            while written < total {
                let n = Darwin.write(masterFD, base.advanced(by: written), total - written)
                if n <= 0 {
                    if errno == EAGAIN || errno == EINTR {
                        usleep(500)
                        continue
                    }
                    break
                }
                written += n
            }
        }
    }

    func write(_ string: String) {
        if let d = string.data(using: .utf8) { write(d) }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(rows, 1)),
                           ws_col: UInt16(max(cols, 1)),
                           ws_xpixel: 0,
                           ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        if childPID > 0 {
            kill(childPID, SIGWINCH)
        }
    }

    func sendInterrupt() {
        write(Data([0x03]))
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if childPID > 0 {
            kill(childPID, SIGTERM)
            childPID = -1
        }
    }

    private func startReading() {
        let queue = DispatchQueue(label: "pty.read.queue", qos: .userInitiated)
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var collected = Data()
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    collected.append(buf, count: n)
                    if collected.count >= 256 * 1024 { break }
                } else {
                    break
                }
            }
            if !collected.isEmpty {
                let payload = collected
                DispatchQueue.main.async { [weak self] in
                    self?.onOutput?(payload)
                }
            }
        }
        source.setCancelHandler { /* nothing to do */ }
        readSource = source
        source.resume()
    }

    private func watchExit() {
        let pid = childPID
        DispatchQueue.global(qos: .background).async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                self?.onExit?(status)
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Process cwd lookup
//
// macOS doesn't give us a clean way to learn "what directory is the shell in?"
// after a `cd` unless the shell itself emits OSC 7 (which it only does by
// default inside Terminal.app). We fall back to asking the kernel directly via
// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, which is what `lsof` uses — it works
// for any descendant PID we own and needs no shell integration.
enum ProcInfo {
    static func cwd(ofPid pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }
}
