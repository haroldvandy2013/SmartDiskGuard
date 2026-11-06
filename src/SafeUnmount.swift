import Foundation
import IOKit
import Darwin

struct CommandResult {
    let ok: Bool
    let output: String
}

func runCommand(_ launchPath: String, args: [String]) -> CommandResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        // Drain before waiting so a full pipe cannot deadlock the child process.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(ok: task.terminationStatus == 0, output: output)
    } catch {
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

    private struct Target: Equatable {
        let uuid: String
        let mountPoint: String
        let disks: [String]
    }

    private func diskInfo(_ id: String) throws -> [String: Any] {
        let result = command("/usr/sbin/diskutil", ["info", "-plist", id])
        guard result.ok else {
            throw UnmountCheckError("无法检查 \(id)：\(result.output)")
        }
        guard let data = result.output.data(using: .utf8),
              let info = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              info["DeviceIdentifier"] as? String == id else {
            throw UnmountCheckError("\(id) 的磁盘信息无效")
        }
        return info
    }

    private func target(_ id: String) throws -> Target {
        let info = try diskInfo(id)
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
