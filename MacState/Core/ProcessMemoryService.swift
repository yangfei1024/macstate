import Foundation
import AppKit

struct ProcessMemoryUsage {
    let pid: Int32            // 组内占用最高的进程 PID
    let name: String
    let icon: NSImage?
    let memoryBytes: UInt64
    let command: String       // 聚合行: 各成员进程明细; 单进程: 命令行
    let processCount: Int

    var memoryFormatted: String {
        let mb = Double(memoryBytes) / 1_048_576
        if mb < 1 { return "\(memoryBytes / 1024) KB" }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", gb)
    }
}

/// 按 App 聚合的内存排行（腾讯柠檬风格）：同一个 .app 的主进程/helper
/// （Electron 一类应用会有十几个进程）合并为一行显示总占用。
final class ProcessMemoryService {
    static let shared = ProcessMemoryService()

    private var bundleNameCache: [String: String] = [:]
    private var bundleIconCache: [String: NSImage] = [:]

    private init() {}

    private struct Member {
        var pid: Int32
        var rssKB: UInt64
        var args: String
    }

    private struct AppGroup {
        var key: String
        var bundlePath: String?
        var name: String
        var icon: NSImage?
        var members: [Member] = []
        var totalKB: UInt64 = 0
    }

    func topProcesses(limit: Int = 10) -> [ProcessMemoryUsage] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,rss,args"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var groupsByKey: [String: AppGroup] = [:]
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            guard let pid = Int32(parts[0]) else { continue }
            guard let rssKB = UInt64(parts[1]) else { continue }
            guard rssKB > 0 else { continue }

            let args = String(parts[2])
            let executablePath = executablePath(pid: pid) ?? args
            let (key, bundlePath, name, icon) = classify(path: executablePath, pid: pid)

            if groupsByKey[key] == nil {
                groupsByKey[key] = AppGroup(key: key, bundlePath: bundlePath, name: name, icon: icon)
            }
            groupsByKey[key]?.members.append(Member(pid: pid, rssKB: rssKB, args: args))
            groupsByKey[key]?.totalKB += rssKB
        }

        let sorted = groupsByKey.values.sorted { $0.totalKB > $1.totalKB }.prefix(limit)

        return sorted.map { group in
            let top = group.members.max { $0.rssKB < $1.rssKB }
            let command: String
            if group.members.count > 1 {
                let rows = group.members
                    .sorted { $0.rssKB > $1.rssKB }
                    .map { String(format: "%-7d %7.1f MB  %@", $0.pid, Double($0.rssKB) / 1024.0, $0.args) }
                command = rows.joined(separator: "\n")
            } else {
                command = top?.args ?? group.key
            }
            return ProcessMemoryUsage(
                pid: top?.pid ?? 0,
                name: group.name,
                icon: group.icon,
                memoryBytes: group.totalKB * 1024,
                command: command,
                processCount: group.members.count
            )
        }
    }

    /// 归组规则：路径落在某个 .app 内 → 按该 App 聚合；否则按可执行文件自身。
    private func classify(path: String, pid: Int32) -> (key: String, bundlePath: String?, name: String, icon: NSImage?) {
        var bundlePath: String? = nil
        if let range = path.range(of: ".app/Contents/") {
            bundlePath = String(path[path.startIndex..<range.lowerBound]) + ".app"
        }

        if let bp = bundlePath {
            return (key: bp, bundlePath: bp, name: bundleDisplayName(bp), icon: bundleIcon(bp))
        }

        let lastComponent = (path as NSString).lastPathComponent
        let app = NSRunningApplication(processIdentifier: pid)
        let name: String
        if let localized = app?.localizedName, !localized.isEmpty {
            name = localized
        } else {
            name = lastComponent
        }
        return (key: path, bundlePath: nil, name: name, icon: app?.icon)
    }

    private func executablePath(pid: Int32) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        guard ret > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private func bundleDisplayName(_ bundlePath: String) -> String {
        if let cached = bundleNameCache[bundlePath] { return cached }

        // Spotlight 显示名（本地化，如 微信）→ Info.plist → 目录名
        let bundleURL = URL(fileURLWithPath: bundlePath) as CFURL
        var name: String?
        if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL),
           let mdName = MDItemCopyAttribute(mdItem, kMDItemDisplayName) as? String,
           !mdName.isEmpty {
            name = (mdName as NSString).deletingPathExtension
        }

        if name == nil, let bundle = Bundle(path: bundlePath) {
            let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
            name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String
        }

        let resolved = name ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        bundleNameCache[bundlePath] = resolved
        return resolved
    }

    private func bundleIcon(_ bundlePath: String) -> NSImage? {
        if let cached = bundleIconCache[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        bundleIconCache[bundlePath] = icon
        return icon
    }
}
