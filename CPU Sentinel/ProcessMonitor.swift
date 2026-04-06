import Foundation
import Darwin

struct MonitoredProcess {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let memory: Int // MB
    let uptimeSeconds: Int
    let command: String
    let name: String
    let isOrphan: Bool
    let isRunaway: Bool
    let isWarning: Bool

    var uptimeFormatted: String {
        if uptimeSeconds < 60 { return "\(uptimeSeconds)s" }
        if uptimeSeconds < 3600 { return "\(uptimeSeconds / 60)m" }
        if uptimeSeconds < 86400 {
            return "\(uptimeSeconds / 3600)h \((uptimeSeconds % 3600) / 60)m"
        }
        return "\(uptimeSeconds / 86400)d \((uptimeSeconds % 86400) / 3600)h"
    }
}

struct SensitivityProfile {
    let label: String
    let cpuThreshold: Double
    let memoryThreshold: Int
    let uptimeThreshold: Int
    let checkInterval: TimeInterval

    static let relaxed = SensitivityProfile(
        label: "Relaxed — catch only extreme cases",
        cpuThreshold: 400, memoryThreshold: 4096, uptimeThreshold: 86400, checkInterval: 300
    )
    static let balanced = SensitivityProfile(
        label: "Balanced — recommended for most users",
        cpuThreshold: 200, memoryThreshold: 2048, uptimeThreshold: 3600, checkInterval: 30
    )
    static let aggressive = SensitivityProfile(
        label: "Aggressive — catch issues early",
        cpuThreshold: 100, memoryThreshold: 1024, uptimeThreshold: 1800, checkInterval: 10
    )

    static let all: [(key: String, profile: SensitivityProfile)] = [
        ("relaxed", .relaxed),
        ("balanced", .balanced),
        ("aggressive", .aggressive)
    ]
}

class ProcessMonitor {
    var profile: SensitivityProfile = .balanced
    var onScan: (([MonitoredProcess]) -> Void)?
    var onRunaway: ((MonitoredProcess) -> Void)?

    private var timer: Timer?
    private var knownRunaways: Set<Int32> = []
    private var cpuHistory: [Int32: (prevTime: Double, prevSample: Date)] = [:]

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: profile.checkInterval, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        stop()
        start()
    }

    func scan() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let processes = self.getProcesses()
            let runaways = processes.filter { $0.isRunaway }

            DispatchQueue.main.async {
                for proc in runaways {
                    if !self.knownRunaways.contains(proc.pid) {
                        self.knownRunaways.insert(proc.pid)
                        self.onRunaway?(proc)
                    }
                }

                let activePids = Set(processes.map { $0.pid })
                self.knownRunaways = self.knownRunaways.intersection(activePids)
                self.onScan?(processes)
            }
        }
    }

    func killProcess(_ pid: Int32) {
        kill(pid, SIGTERM)
        knownRunaways.remove(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Native process listing via sysctl
    private func getProcesses() -> [MonitoredProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0

        // first call to get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        let now = Date()
        var results: [MonitoredProcess] = []

        for i in 0..<actualCount {
            let proc = procList[i]
            let pid = proc.kp_proc.p_pid
            let ppid = proc.kp_eproc.e_ppid
            let uid = proc.kp_eproc.e_ucred.cr_uid

            // skip root/system processes
            guard uid >= 500 else { continue }
            guard pid > 0 else { continue }

            let command = getProcessCommand(pid: pid)
            guard !command.isEmpty else { continue }

            // uptime from start time
            let startSec = proc.kp_proc.p_starttime.tv_sec
            let uptimeSeconds = Int(now.timeIntervalSince1970) - Int(startSec)
            guard uptimeSeconds > 0 else { continue }

            // memory (resident size in bytes)
            let memoryMB = getResidentMemory(pid: pid)

            // cpu estimation via proc_pid_rusage or task_info
            let cpu = getCPUUsage(pid: pid, now: now)

            let isOrphan = ppid == 1 && isUserProcess(command) && !isLaunchedApp(command)
            let isHighCPU = cpu >= profile.cpuThreshold && uptimeSeconds >= profile.uptimeThreshold
            let isHighMemory = memoryMB >= profile.memoryThreshold
            let isRunaway = isOrphan && (isHighCPU || isHighMemory)
            let isWarning = isOrphan && !isRunaway && (
                (cpu >= profile.cpuThreshold * 0.5 && uptimeSeconds >= profile.uptimeThreshold / 2) ||
                (memoryMB >= profile.memoryThreshold / 2)
            )

            // only include processes that are orphan or dev servers
            guard isOrphan || isRunaway || isWarning else { continue }

            results.append(MonitoredProcess(
                pid: pid, ppid: ppid, cpu: cpu, memory: memoryMB,
                uptimeSeconds: uptimeSeconds, command: command,
                name: extractName(command),
                isOrphan: isOrphan, isRunaway: isRunaway, isWarning: isWarning
            ))
        }

        return results
    }

    private func getProcessCommand(pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return "" }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return "" }

        // KERN_PROCARGS2: first 4 bytes = argc, then exec path (null-terminated)
        guard size > MemoryLayout<Int32>.size else { return "" }

        let execStart = MemoryLayout<Int32>.size
        if let nullIndex = buffer[execStart..<size].firstIndex(of: 0) {
            let pathData = Data(buffer[execStart..<nullIndex])
            return String(data: pathData, encoding: .utf8) ?? ""
        }
        return ""
    }

    private func getResidentMemory(pid: Int32) -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }

        // p_rssize is in pages, page size is typically 16384 on Apple Silicon
        let pageSize = Int(vm_page_size)
        let rsPages = Int(info.kp_eproc.e_xrssize)
        return (rsPages * pageSize) / (1024 * 1024)
    }

    private func getCPUUsage(pid: Int32, now: Date) -> Double {
        // use rusage to estimate CPU
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }

        let utime = Double(info.kp_proc.p_uticks)
        let stime = Double(info.kp_proc.p_sticks)
        let totalTicks = utime + stime

        if let prev = cpuHistory[pid] {
            let elapsed = now.timeIntervalSince(prev.prevSample)
            if elapsed > 0 {
                let tickDelta = totalTicks - prev.prevTime
                // ticks are in microseconds on macOS
                let cpuPercent = (tickDelta / (elapsed * 1_000_000)) * 100
                cpuHistory[pid] = (totalTicks, now)
                return min(cpuPercent, 999)
            }
        }

        cpuHistory[pid] = (totalTicks, now)
        return 0
    }

    // MARK: - Process classification

    private func isUserProcess(_ command: String) -> Bool {
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/", "com.apple."]
        if systemPrefixes.contains(where: { command.contains($0) }) { return false }

        let userSignals = ["node", "python", "ruby", "java", "go ", "npm", "yarn", "pnpm", "bun",
                           "docker", "kubectl", "electron", "/Users/", "/home/"]
        return userSignals.contains(where: { command.lowercased().contains($0.lowercased()) })
    }

    private func isLaunchedApp(_ command: String) -> Bool {
        return command.contains("/Applications/") ||
               command.contains(".app/") ||
               command.contains("/Library/") ||
               command.contains("/System/")
    }

    private func extractProjectName(_ command: String) -> String? {
        let genericDirs = ["frontend", "backend", "server", "client", "app", "web", "src", "packages"]

        let patterns = [
            #"\/([^/]+)\/node_modules\/"#,
            #"\/([^/]+)\/\.next"#,
            #"\/([^/]+)\/\.nuxt"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                let name = String(command[range])
                if genericDirs.contains(name.lowercased()) {
                    let parentPattern = "/([^/]+)/\(name)/"
                    if let parentRegex = try? NSRegularExpression(pattern: parentPattern),
                       let parentMatch = parentRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                       let parentRange = Range(parentMatch.range(at: 1), in: command) {
                        return String(command[parentRange])
                    }
                }
                return name
            }
        }

        let pathPatterns = [#"\/projects?\/([^/]+)"#, #"\/([^/]+)\/(?:frontend|backend|server|client|app|web)\/"#]
        for pattern in pathPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                return String(command[range])
            }
        }
        return nil
    }

    private func extractName(_ command: String) -> String {
        let project = extractProjectName(command)

        let serverTypes: [(String, String)] = [
            ("next-server", "Next.js"), ("next dev", "Next.js"), ("turbopack", "Turbopack"),
            ("vite", "Vite"), ("webpack-dev", "Webpack"), ("webpack serve", "Webpack"),
            ("nodemon", "Nodemon"), ("ts-node-dev", "ts-node-dev"),
            ("react-scripts", "CRA"), ("ng serve", "Angular"), ("nuxt dev", "Nuxt"),
        ]

        var serverType: String? = nil
        for (pattern, name) in serverTypes {
            if command.contains(pattern) {
                serverType = name
                break
            }
        }

        if let project = project, let serverType = serverType { return "\(project) (\(serverType))" }
        if let project = project { return project }
        if let serverType = serverType { return "\(serverType) Dev" }

        let parts = command.components(separatedBy: "/")
        let last = parts.last?.components(separatedBy: " ").first ?? "unknown"
        return String(last.prefix(30))
    }
}
