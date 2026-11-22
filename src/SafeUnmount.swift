import Foundation
import IOKit
import Darwin

struct CommandResult {
    let ok: Bool
    let output: String
    var timedOut = false
}

final class DiagnosticLog {
    static let shared = DiagnosticLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SmartDiskGuard", isDirectory: true))
    let directory: URL
    private let lock = NSLock()
    private let maxBytes: Int
    private let maxTotalBytes: Int
    private let maxAge: TimeInterval
    private let now: () -> Date

    init(
        directory: URL, maxBytes: Int = 1_048_576,
        maxTotalBytes: Int = 10_485_760, maxAge: TimeInterval = 10 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxAge = maxAge
        self.now = now
    }

    private func logFile(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "SmartDiskGuard.log" : "SmartDiskGuard.\(index).log")
    }

    private func existingFiles() throws -> [(url: URL, size: Int, created: Date)] {
        let manager = FileManager.default
        return try (0...9).compactMap { index in
            let file = logFile(index)
            guard manager.fileExists(atPath: file.path) else { return nil }
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber,
                  let created = attributes[.creationDate] as? Date else {
                throw UnmountCheckError("Cannot read diagnostic log retention metadata")
            }
            return (file, size.intValue, created)
        }
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let timestamp = now()
            let line = "\(ISO8601DateFormatter().string(from: timestamp)) pid=\(ProcessInfo.processInfo.processIdentifier) \(message.prefix(4096))\n"
            let data = Data(line.utf8)
            guard data.count <= maxTotalBytes else {
                throw UnmountCheckError("Diagnostic entry exceeds total log size limit")
            }
            // Use creation time, not last-write time: an actively appended file must still expire.
            for entry in try existingFiles() where timestamp.timeIntervalSince(entry.created) >= maxAge {
                try manager.removeItem(at: entry.url)
            }
            let file = logFile(0)
            if manager.fileExists(atPath: file.path) {
                let size = (try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 0 && size + data.count > maxBytes {
                    for index in stride(from: 8, through: 0, by: -1) {
                        let source = logFile(index)
                        let destination = logFile(index + 1)
                        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                        if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: destination) }
                    }
                }
            }
            let files = try existingFiles()
            var total = files.reduce(0) { $0 + $1.size }
            // Higher archive numbers contain older records; delete them before the active file.
            for entry in files.reversed() where total + data.count > maxTotalBytes {
                try manager.removeItem(at: entry.url)
                total -= entry.size
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw UnmountCheckError("Cannot create diagnostic log")
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { handle.closeFile() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("SmartDiskGuard log write failed: %@", error.localizedDescription)
        }
    }
}

final class CommandProcesses {
    static let shared = CommandProcesses()
    private let lock = NSLock()
    private var tasks: [Int32: Process] = [:]

    func add(_ task: Process) {
        lock.lock()
        tasks[task.processIdentifier] = task
        lock.unlock()
    }

    func remove(_ task: Process) {
        lock.lock()
        tasks.removeValue(forKey: task.processIdentifier)
        lock.unlock()
    }

    func terminateOwnedCommands() {
        lock.lock()
        let running = Array(tasks.values)
        lock.unlock()
        for task in running where task.isRunning {
            DiagnosticLog.shared.write("app exit terminating owned command child=\(task.processIdentifier)")
            task.terminate()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while running.contains(where: { $0.isRunning }), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for task in running where task.isRunning {
            if kill(task.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                DiagnosticLog.shared.write("app exit kill failed child=\(task.processIdentifier) errno=\(errno)")
            }
        }
    }
}

func runCommand(_ launchPath: String, args: [String], timeout: TimeInterval = 30) -> CommandResult {
    guard timeout.isFinite, timeout > 0 else {
        DiagnosticLog.shared.write("command rejected: invalid timeout")
        return CommandResult(ok: false, output: "命令超时设置无效")
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let outputFile = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuard-command-\(UUID().uuidString)")
    defer {
        do {
            if FileManager.default.fileExists(atPath: outputFile.path) {
                try FileManager.default.removeItem(at: outputFile)
            }
        } catch { DiagnosticLog.shared.write("command output cleanup failed: \(error.localizedDescription)") }
    }
    let completed = DispatchSemaphore(value: 0)
    task.terminationHandler = {
        CommandProcesses.shared.remove($0)
        completed.signal()
    }
    let started = ProcessInfo.processInfo.systemUptime
    let description = "\(URL(fileURLWithPath: launchPath).lastPathComponent) \(args.joined(separator: " "))"
    do {
        // A file avoids pipe-buffer deadlocks and lets timeout return even if a writer never closes stdout.
        guard FileManager.default.createFile(atPath: outputFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UnmountCheckError("无法创建命令输出文件")
        }
        let handle = try FileHandle(forWritingTo: outputFile)
        defer { handle.closeFile() }
        task.standardOutput = handle
        task.standardError = handle
        try task.run()
        CommandProcesses.shared.add(task)
        if !task.isRunning { CommandProcesses.shared.remove(task) }
        DiagnosticLog.shared.write("command started child=\(task.processIdentifier) timeout=\(timeout)s \(description)")
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if task.isRunning { task.terminate() }
            if completed.wait(timeout: .now() + 1) == .timedOut {
                if task.isRunning, kill(task.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                    DiagnosticLog.shared.write("command kill failed child=\(task.processIdentifier) errno=\(errno)")
                }
                _ = completed.wait(timeout: .now() + 1)
            }
            DiagnosticLog.shared.write("command timeout child=\(task.processIdentifier) stillRunning=\(task.isRunning) \(description)")
            return CommandResult(ok: false, output: "命令超过 \(timeout.formatted()) 秒未响应，已取消等待；请检查硬盘连接后重试", timedOut: true)
        }
        let data = try Data(contentsOf: outputFile)
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DiagnosticLog.shared.write("command completed child=\(task.processIdentifier) status=\(task.terminationStatus) elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s \(description)")
        return CommandResult(ok: task.terminationStatus == 0, output: output)
    } catch {
        DiagnosticLog.shared.write("command failed \(description): \(error.localizedDescription)")
        return CommandResult(ok: false, output: error.localizedDescription)
    }
}

struct DiskActivity: Equatable {
    let registryID: UInt64
    let counters: [UInt64]

    static func read(_ disk: String) throws -> DiskActivity {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, disk) else {
            throw UnmountCheckError("无法定位 \(disk) 的读写统计")
        }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else {
            throw UnmountCheckError("无法定位 \(disk) 的读写统计")
        }
        defer { IOObjectRelease(entry) }

        while IOObjectConformsTo(entry, "IOBlockStorageDriver") == 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else {
                throw UnmountCheckError("\(disk) 不提供可验证的物理磁盘读写统计")
            }
            IOObjectRelease(entry)
            entry = parent
        }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS,
              let statistics = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? [String: Any] else {
            throw UnmountCheckError("无法读取 \(disk) 的读写统计")
        }
        let keys = [
            "Bytes (Read)", "Bytes (Write)", "Operations (Read)", "Operations (Write)",
            "Total Time (Read)", "Total Time (Write)"
        ]
        let counters = try keys.map { key -> UInt64 in
            guard let value = statistics[key] as? NSNumber, value.int64Value >= 0 else {
                throw UnmountCheckError("\(disk) 的读写统计不完整")
            }
            return value.uint64Value
        }
        return DiskActivity(registryID: registryID, counters: counters)
    }
}

struct UnmountCheckError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct VolumeIdentity: Equatable {
    let registryID: UInt64
    let device: String
    let mountPoint: String
    let filesystemID: [Int32]

    static func read(_ id: String, _ mountPoint: String) throws -> VolumeIdentity {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, id) else {
            throw UnmountCheckError("无法定位卷宗设备 \(id)")
        }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { throw UnmountCheckError("卷宗设备 \(id) 已断开") }
        defer { IOObjectRelease(entry) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else {
            throw UnmountCheckError("无法确认卷宗设备身份")
        }
        // MNT_NOWAIT reads cached mount information without querying the filesystem.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { throw UnmountCheckError("无法读取系统挂载信息") }
        var mounts = Array<statfs>(repeating: statfs(), count: Int(count) + 16)
        let loaded = mounts.withUnsafeMutableBytes {
            getfsstat($0.baseAddress?.assumingMemoryBound(to: statfs.self), Int32($0.count), MNT_NOWAIT)
        }
        guard loaded > 0, Int(loaded) < mounts.count else {
            throw UnmountCheckError("无法完整读取系统挂载信息")
        }
        for mount in mounts.prefix(Int(loaded)) {
            let path = withUnsafeBytes(of: mount.f_mntonname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let device = withUnsafeBytes(of: mount.f_mntfromname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path == mountPoint, device == "/dev/\(id)" {
                return VolumeIdentity(
                    registryID: registryID, device: device, mountPoint: path,
                    filesystemID: [mount.f_fsid.val.0, mount.f_fsid.val.1]
                )
            }
        }
        throw UnmountCheckError("卷宗挂载信息已变化，已取消卸载")
    }
}

struct SafeUnmount {
    var command: (String, [String]) -> CommandResult = { runCommand($0, args: $1) }
    var activity: (String) throws -> DiskActivity = DiskActivity.read
    var wait: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    var identity: (String, String) throws -> VolumeIdentity = VolumeIdentity.read
    var metadata: (String) throws -> [String: Any] = { try ExternalDiskMetadata.read($0) }

    private struct Target: Equatable {
        let uuid: String
        let mountPoint: String
        let disks: [String]
    }

    private func diskInfo(_ id: String) throws -> [String: Any] {
        let info = try metadata(id)
        guard info["DeviceIdentifier"] as? String == id else {
            throw UnmountCheckError("\(id) 的磁盘信息无效")
        }
        return info
    }

        enum ExternalDiskMetadata {
            static func read(
                _ id: String,
                command: (String, [String]) -> CommandResult = { runCommand($0, args: $1) }
            ) throws -> [String: Any] {
                func query(_ args: [String]) throws -> [String: Any] {
                    let result = command("/usr/sbin/diskutil", args)
                    guard result.ok else { throw UnmountCheckError("无法读取磁盘列表：\(result.output)") }
                    guard let value = try PropertyListSerialization.propertyList(
                        from: Data(result.output.utf8), options: [], format: nil
                    ) as? [String: Any] else { throw UnmountCheckError("磁盘列表格式无效") }
                    return value
                }
                let listing = try query(["list", "-plist", "external", "physical"])
                guard let disks = listing["AllDisksAndPartitions"] as? [[String: Any]] else {
                    throw UnmountCheckError("外接物理磁盘列表不完整")
                }
                for disk in disks {
                    guard disk["OSInternal"] as? Bool == false,
                          let whole = disk["DeviceIdentifier"] as? String else { continue }
                    for part in disk["Partitions"] as? [[String: Any]] ?? [] where part["DeviceIdentifier"] as? String == id {
                        var info = part
                        info["Internal"] = false
                        info["WholeDisk"] = false
                        info["ParentWholeDisk"] = whole
                        return info
                    }
                }
                // APFS volumes are synthesized devices; resolve their stores against physical disks only.
                let apfs = try query(["apfs", "list", "-plist"])
                for container in apfs["Containers"] as? [[String: Any]] ?? [] {
                    let stores = container["PhysicalStores"] as? [[String: Any]] ?? []
                    let storeIDs = stores.compactMap { $0["DeviceIdentifier"] as? String }
                    let externalParts = Set(disks.filter { $0["OSInternal"] as? Bool == false }
                        .flatMap { $0["Partitions"] as? [[String: Any]] ?? [] }
                        .compactMap { $0["DeviceIdentifier"] as? String })
                    guard !storeIDs.isEmpty, storeIDs.count == stores.count,
                          storeIDs.allSatisfy({ externalParts.contains($0) }) else { continue }
                    for volume in container["Volumes"] as? [[String: Any]] ?? [] where volume["DeviceIdentifier"] as? String == id {
                        var info = volume
                        info["Internal"] = false
                        info["WholeDisk"] = false
                        info["FilesystemType"] = "apfs"
                        info["VolumeUUID"] = volume["APFSVolumeUUID"]
                        info["APFSPhysicalStores"] = storeIDs.map { ["APFSPhysicalStore": $0] }
                        return info
                    }
                }
                throw UnmountCheckError("目标不在外接物理磁盘列表中，已跳过")
            }
        }
    private func target(_ id: String) throws -> Target {
        let info = try diskInfo(id)
        guard info["BusProtocol"] as? String != "Disk Image" else {
            throw UnmountCheckError("磁盘映像（如应用安装 DMG）不属于外接物理硬盘，已跳过")
        }
        guard info["Internal"] as? Bool == false,
              info["WholeDisk"] as? Bool == false,
              let uuid = info["VolumeUUID"] as? String, !uuid.isEmpty,
              let mountPoint = info["MountPoint"] as? String, !mountPoint.isEmpty else {
            throw UnmountCheckError("目标不是已挂载且可验证的外接卷宗")
        }
        let stores: [String]
        if info["FilesystemType"] as? String == "apfs" {
            guard let physicalStores = info["APFSPhysicalStores"] as? [[String: Any]],
                  !physicalStores.isEmpty else {
                throw UnmountCheckError("无法确认 APFS 卷宗对应的物理磁盘")
            }
            stores = try physicalStores.map {
                guard let store = $0["APFSPhysicalStore"] as? String, !store.isEmpty else {
                    throw UnmountCheckError("APFS 物理磁盘信息不完整")
                }
                return store
            }
        } else {
            stores = [id]
        }
        let disks = try stores.map { store -> String in
            let storeInfo = store == id ? info : try diskInfo(store)
            guard storeInfo["BusProtocol"] as? String != "Disk Image" else {
                throw UnmountCheckError("卷宗位于磁盘映像中，已跳过卸载")
            }
            guard storeInfo["Internal"] as? Bool == false,
                  let disk = storeInfo["ParentWholeDisk"] as? String, !disk.isEmpty else {
                throw UnmountCheckError("无法确认 \(store) 对应的外接物理磁盘")
            }
            return disk
        }
        return Target(uuid: uuid, mountPoint: mountPoint, disks: Array(Set(disks)).sorted())
    }

    func unmount(
        _ id: String,
        expectedIdentity: VolumeIdentity? = nil,
        identityVerified: (VolumeIdentity) -> Void = { _ in },
        shouldProceed: () -> Bool = { true }
    ) -> CommandResult {
        do {
            guard shouldProceed() else { throw UnmountCheckError("已取消自动卸载") }
            let initialTarget = try target(id)
            let initialIdentity = try identity(id, initialTarget.mountPoint)
            if let expectedIdentity = expectedIdentity, initialIdentity != expectedIdentity {
                throw UnmountCheckError("卷宗设备或挂载身份已变化，已取消卸载")
            }
            identityVerified(initialIdentity)
            let baseline = try initialTarget.disks.map(activity)
            // Require two consecutive one-second intervals without any physical disk I/O.
            for _ in 0..<2 {
                wait(1)
                guard shouldProceed() else { throw UnmountCheckError("已取消自动卸载") }
                guard try initialTarget.disks.map(activity) == baseline else {
                    throw UnmountCheckError("检测到硬盘读写或设备变化，已保留挂载，请空闲后重试")
                }
            }
            guard try identity(id, initialTarget.mountPoint) == initialIdentity else {
                throw UnmountCheckError("卷宗挂载或设备信息已变化，已取消卸载")
            }
            guard shouldProceed() else { throw UnmountCheckError("已取消自动卸载") }
            guard try initialTarget.disks.map(activity) == baseline else {
                throw UnmountCheckError("检测到硬盘读写或设备变化，已保留挂载，请空闲后重试")
            }
            // Normal unmount lets macOS flush cached writes and refuse an in-use volume.
            // Never force: I/O can start after the final sample.
            let result = command("/usr/sbin/diskutil", ["unmount", id])
            return result.ok ? result : CommandResult(
                ok: false, output: "安全卸载失败，未执行强制卸载：\(result.output)"
            )
        } catch {
            return CommandResult(ok: false, output: error.localizedDescription)
        }
    }
}
