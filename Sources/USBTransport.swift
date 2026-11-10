import Foundation

enum USBTransport {
    private static let host = "root@192.168.2.2"

    static func send(_ png: Data) throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("frame.png")
            try png.write(to: file)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let script = """
            set -eu
            umask 077
            lock=/var/run/kindle-cast.lock
            mkdir "$lock" || { echo 'CAST_BUSY' >&2; exit 1; }
            trap 'rm -f "$lock/frame.png"; rmdir "$lock"' EXIT
            trap 'exit 1' HUP INT TERM
            frame="$lock/frame.png"
            cat >"$frame"
            [ "$(wc -c <"$frame" | tr -d ' ')" = "\(png.count)" ] || {
                echo 'CAST_INCOMPLETE' >&2
                exit 1
            }
            state() { lipc-get-prop -s com.lab126.powerd state; }
            if [ "$(state)" = active ]; then
                powerd_test -p
                sleep 2
            fi
            if [ "$(state)" != screenSaver ]; then
                echo 'CAST_STATE' >&2
                exit 1
            fi
            if [ "$(cat /sys/class/graphics/fb0/virtual_size)" != 824,1200 ]; then
                echo 'CAST_ORIENTATION' >&2
                exit 1
            fi
            /usr/sbin/eips -f -g "$frame"
            echo 'CAST_OK'
            """
            try ssh(script, input: input)
        }
    }

    static func returnToReader() throws {
        try ssh("""
        set -eu
        lipc-set-prop -i com.lab126.powerd wakeUp 1
        sleep 1
        [ "$(lipc-get-prop -s com.lab126.powerd state)" = active ]
        echo 'CAST_OK'
        """)
    }

    static func captureRegion() throws -> Data? {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("capture.png")
            let (status, output) = try run("/usr/sbin/screencapture",
                                           ["-i", "-s", "-x", "-t", "png", target.path])
            if FileManager.default.fileExists(atPath: target.path) {
                return try Data(contentsOf: target)
            }
            if status != 0 && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CastError.message("截图未完成。请检查系统设置中的屏幕录制权限。")
            }
            return nil
        }
    }

    private static func ssh(_ script: String, input: FileHandle? = nil) throws {
        let environment = ProcessInfo.processInfo.environment.merging([
            "SSH_ASKPASS_REQUIRE": "force",
            "SSH_ASKPASS": "/usr/bin/true"
        ]) { _, configured in configured }
        let arguments = [
            "-T", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2",
            "-o", "NumberOfPasswordPrompts=1", "-o", "ControlMaster=no",
            "-o", "PreferredAuthentications=publickey,password",
            host, script
        ]
        var (status, output) = try run("/usr/bin/ssh", arguments, input: input,
                                       environment: environment, timeout: 18)
        if status == 255 && output.contains("ssh: connect to host 192.168.2.2") &&
            output.contains("Operation timed out") {
            // Retry only when SSH failed before any remote command could run.
            try input?.seek(toOffset: 0)
            (status, output) = try run("/usr/bin/ssh", arguments, input: input,
                                       environment: environment, timeout: 18)
        }

        guard status == 0, output.split(whereSeparator: \.isNewline).contains("CAST_OK") else {
            if output.contains("Host key verification failed") || output.contains("No ED25519 host key") ||
                output.contains("REMOTE HOST IDENTIFICATION") {
                throw CastError.message("SSH 主机密钥校验失败。请在终端确认 Kindle 的身份后再试。")
            }
            if output.contains("Permission denied") {
                throw CastError.message("Kindle 拒绝 SSH 登录。请在终端确认 root@192.168.2.2 可以登录。")
            }
            if output.contains("CAST_STATE") {
                throw CastError.message("Kindle 尚未进入屏保。请先在 Kindle 上唤醒到阅读界面，再投放。")
            }
            if output.contains("CAST_ORIENTATION") {
                throw CastError.message("请先返回 Kindle 阅读界面，将屏幕切到竖向后再投放。")
            }
            if output.contains("CAST_BUSY") {
                throw CastError.message("Kindle 正在接收另一幅画面，请稍后重试。")
            }
            if output.contains("CAST_INCOMPLETE") {
                throw CastError.message("Kindle 收到的画面不完整。请重新投放。")
            }
            let detail = output.split(whereSeparator: \.isNewline)
                .filter { !$0.contains("Welcome to Kindle") }.last
            throw CastError.message("发送未完成。请检查 USB 连接和 USBNetwork。"
                                    + (detail.map { "\n\($0.prefix(220))" } ?? ""))
        }
    }

    private static func run(_ path: String, _ arguments: [String], input: FileHandle? = nil,
                            environment: [String: String]? = nil,
                            timeout: TimeInterval? = nil) throws -> (Int32, String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.environment = environment
        task.standardInput = input ?? FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let deadline = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        deadline.cancel()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KindleCast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}
