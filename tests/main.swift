import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func plist(_ info: [String: Any]) -> CommandResult {
    let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    return CommandResult(ok: true, output: String(data: data, encoding: .utf8)!)
}

func volumeInfo(_ id: String = "disk9s2") -> [String: Any] {
    [
        "DeviceIdentifier": id, "Internal": false, "WholeDisk": false,
        "VolumeUUID": "test-volume", "MountPoint": "/Volumes/Test",
        "ParentWholeDisk": "disk9", "FilesystemType": "hfs"
    ]
}

final class Fixture {
    var info = volumeInfo()
    var stores: [String: [String: Any]] = [:]
    var samples = [
        DiskActivity(registryID: 9, counters: [10, 20, 1, 2, 100, 200])
    ]
    var sampledDisks: [String] = []
    var commands: [[String]] = []
    var waits: [TimeInterval] = []
    var infoFailure: CommandResult?
    var activityFailure = false
    var unmountOK = true
    var onWait: (() -> Void)?
    var volumeIdentity = VolumeIdentity(
        registryID: 90, device: "/dev/disk9s2", mountPoint: "/Volumes/Test", filesystemID: [1, 2]
    )
    var identityFailure = false
    var onInfo: (() -> Void)?

    var service: SafeUnmount {
        SafeUnmount(
            command: { path, args in
                expect(path == "/usr/sbin/diskutil", "Unexpected executable")
                self.commands.append(args)
                expect(args == ["unmount", self.info["DeviceIdentifier"] as! String],
                       "Only normal volume unmount is allowed")
                return CommandResult(ok: self.unmountOK, output: "test unmount result")
            },
            activity: { disk in
                self.sampledDisks.append(disk)
                if self.activityFailure { throw UnmountCheckError("Missing statistics") }
                if self.samples.count > 1 { return self.samples.removeFirst() }
                return self.samples[0]
            },
            wait: {
                self.waits.append($0)
                self.onWait?()
            },
            identity: { _, _ in
                if self.identityFailure { throw UnmountCheckError("Mount information unavailable") }
                return self.volumeIdentity
            },
            metadata: { id in
                if let failure = self.infoFailure {
                    guard failure.ok else { throw UnmountCheckError(failure.output) }
                    return try PropertyListSerialization.propertyList(
                        from: Data(failure.output.utf8), options: [], format: nil
                    ) as? [String: Any] ?? [:]
                }
                self.onInfo?()
                return self.stores[id] ?? self.info
            }
        )
    }

    var unmountCommands: [[String]] { commands.filter { $0.first == "unmount" } }
}

var testCount = 0
func test(_ name: String, _ body: () -> Void) {
    body()
    testCount += 1
    print("PASS: \(name)")
}

test("idle disk requires two one-second intervals and a final sample") {
    let f = Fixture()
    expect(f.service.unmount("disk9s2").ok, "Idle disk should unmount")
    expect(f.waits == [1, 1], "Must observe two seconds")
    expect(f.sampledDisks == Array(repeating: "disk9", count: 4), "Must check physical disk")
    expect(!f.commands.contains { $0.first == "info" }, "Never invoke diskutil info")
    expect(f.unmountCommands.count == 1, "Exactly one normal unmount")
}

for counter in 0..<6 {
    test("activity counter \(counter) blocks unmount") {
        let f = Fixture()
        let initial = f.samples[0]
        var counters = initial.counters
        counters[counter] += 1
        f.samples = [initial, DiskActivity(registryID: 9, counters: counters)]
        expect(!f.service.unmount("disk9s2").ok, "Activity must block unmount")
        expect(f.unmountCommands.isEmpty, "Busy disk must remain mounted")
    }
}

test("activity in second interval blocks unmount") {
    let f = Fixture()
    let initial = f.samples[0]
    f.samples = [initial, initial, DiskActivity(registryID: 9, counters: [11, 20, 1, 2, 100, 200])]
    expect(!f.service.unmount("disk9s2").ok, "Second interval activity must block")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("activity immediately before unmount blocks unmount") {
    let f = Fixture()
    let initial = f.samples[0]
    f.samples = [initial, initial, initial,
                 DiskActivity(registryID: 9, counters: [11, 20, 1, 2, 100, 200])]
    expect(!f.service.unmount("disk9s2").ok, "Final activity must block")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("counter reset and device replacement block unmount") {
    for sample in [
        DiskActivity(registryID: 9, counters: [0, 0, 0, 0, 0, 0]),
        DiskActivity(registryID: 10, counters: [10, 20, 1, 2, 100, 200])
    ] {
        let f = Fixture()
        f.samples.append(sample)
        expect(!f.service.unmount("disk9s2").ok, "Changed device must block")
        expect(f.unmountCommands.isEmpty, "No unmount")
    }
}

test("missing statistics fail closed") {
    let f = Fixture()
    f.activityFailure = true
    expect(!f.service.unmount("disk9s2").ok, "Missing stats must block")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("installer disk images are rejected before activity sampling") {
    let f = Fixture()
    f.info["BusProtocol"] = "Disk Image"
    expect(!f.service.unmount("disk9s2").ok, "DMG must not be managed as a physical disk")
    expect(f.sampledDisks.isEmpty && f.unmountCommands.isEmpty, "No sampling or unmount of image")
}

test("statistics disappearing during observation fail closed") {
    let f = Fixture()
    f.onWait = { f.activityFailure = true }
    expect(!f.service.unmount("disk9s2").ok, "Stats disappearing must block")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("failed or invalid disk info fails closed") {
    for failure in [
        CommandResult(ok: false, output: "permission denied"),
        CommandResult(ok: true, output: "not a plist"),
        plist(["DeviceIdentifier": "disk99s2"])
    ] {
        let f = Fixture()
        f.infoFailure = failure
        expect(!f.service.unmount("disk9s2").ok, "Invalid info must block")
        expect(f.unmountCommands.isEmpty, "No unmount")
    }
}

test("internal, whole, unmounted and unidentified volumes are rejected") {
    for (key, value) in [
        ("Internal", true as Any), ("WholeDisk", true as Any),
        ("MountPoint", "" as Any), ("VolumeUUID", "" as Any)
    ] {
        let f = Fixture()
        f.info[key] = value
        expect(!f.service.unmount("disk9s2").ok, "Unsafe volume must block")
        expect(f.unmountCommands.isEmpty, "No unmount")
    }
}

test("mount or volume device changes during observation block unmount") {
    for changed in [
        VolumeIdentity(registryID: 91, device: "/dev/disk9s2", mountPoint: "/Volumes/Test", filesystemID: [1, 2]),
        VolumeIdentity(registryID: 90, device: "/dev/disk9s2", mountPoint: "/Volumes/Other", filesystemID: [1, 2]),
        VolumeIdentity(registryID: 90, device: "/dev/disk9s2", mountPoint: "/Volumes/Test", filesystemID: [3, 4]),
        VolumeIdentity(registryID: 90, device: "/dev/disk10s2", mountPoint: "/Volumes/Test", filesystemID: [1, 2])
    ] {
        let f = Fixture()
        f.onWait = { f.volumeIdentity = changed }
        expect(!f.service.unmount("disk9s2").ok, "Changed target must block")
        expect(f.unmountCommands.isEmpty, "No unmount")
    }
}

test("cached identity failure on final recheck blocks unmount") {
    let f = Fixture()
    f.onWait = { f.identityFailure = true }
    expect(!f.service.unmount("disk9s2").ok, "Final info failure must block")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("metadata-induced reads happen before the idle baseline") {
    let f = Fixture()
    var infoCount = 0
    f.onInfo = {
        expect(f.sampledDisks.isEmpty, "Metadata must never be queried after sampling starts")
        infoCount += 1
        f.samples = [DiskActivity(registryID: 9, counters: [373248, 0, 207, 0, 31031635, 0])]
    }
    expect(f.service.unmount("disk9s2").ok, "Metadata reads must not cause self-rejection")
    expect(infoCount == 1 && f.unmountCommands.count == 1, "One metadata check and normal unmount")
}

test("missing initial cached identity fails closed") {
    let f = Fixture()
    f.identityFailure = true
    expect(!f.service.unmount("disk9s2").ok, "Missing identity must block")
    expect(f.unmountCommands.isEmpty && f.waits.isEmpty, "No sampling or unmount")
}

test("automatic cancellation before or during observation blocks unmount") {
    let f = Fixture()
    expect(!f.service.unmount("disk9s2", shouldProceed: { false }).ok, "Cancelled request")
    expect(f.commands.isEmpty, "Pre-cancel must do nothing")
    var allowed = true
    f.onWait = { allowed = false }
    expect(!f.service.unmount("disk9s2", shouldProceed: { allowed }).ok, "Cancelled during check")
    expect(f.unmountCommands.isEmpty, "No unmount")
}

test("macOS rejection never falls back to force") {
    let f = Fixture()
    f.unmountOK = false
    expect(!f.service.unmount("disk9s2").ok, "OS refusal must be reported")
    expect(f.unmountCommands == [["unmount", "disk9s2"]], "Never force unmount")
}

func apfsFixture() -> Fixture {
    let f = Fixture()
    f.info["DeviceIdentifier"] = "disk12s1"
    f.info["ParentWholeDisk"] = "disk12"
    f.info["FilesystemType"] = "apfs"
    f.info["APFSPhysicalStores"] = [
        ["APFSPhysicalStore": "disk9s2"], ["APFSPhysicalStore": "disk10s2"]
    ]
    f.stores = [
        "disk9s2": ["DeviceIdentifier": "disk9s2", "Internal": false, "ParentWholeDisk": "disk9"],
        "disk10s2": ["DeviceIdentifier": "disk10s2", "Internal": false, "ParentWholeDisk": "disk10"]
    ]
    return f
}

test("APFS checks every physical store, not the synthesized disk") {
    let f = apfsFixture()
    expect(f.service.unmount("disk12s1").ok, "Idle APFS stores should unmount")
    expect(Set(f.sampledDisks) == Set(["disk9", "disk10"]), "All physical disks checked")
    expect(f.sampledDisks.count == 8, "Each physical disk sampled four times")
}

test("activity on either APFS backing disk blocks unmount") {
    for index in 2...3 {
        let f = apfsFixture()
        let initial = f.samples[0]
        f.samples = Array(repeating: initial, count: index) +
            [DiskActivity(registryID: 9, counters: [11, 20, 1, 2, 100, 200])]
        expect(!f.service.unmount("disk12s1").ok, "Any backing disk activity must block")
        expect(f.unmountCommands.isEmpty, "No unmount")
    }
}

test("missing or internal APFS physical stores fail closed") {
    let missing = apfsFixture()
    missing.info.removeValue(forKey: "APFSPhysicalStores")
    expect(!missing.service.unmount("disk12s1").ok, "Missing stores must block")
    expect(missing.unmountCommands.isEmpty, "No unmount")
    let internalStore = apfsFixture()
    internalStore.stores["disk10s2"]?["Internal"] = true
    expect(!internalStore.service.unmount("disk12s1").ok, "Internal backing store must block")
    expect(internalStore.unmountCommands.isEmpty, "No unmount")
}

test("APFS backed by a disk image is excluded") {
    let f = apfsFixture()
    f.stores["disk9s2"]?["BusProtocol"] = "Disk Image"
    expect(!f.service.unmount("disk12s1").ok, "APFS image must be excluded")
    expect(f.sampledDisks.isEmpty && f.unmountCommands.isEmpty, "No unmount of APFS image")
}

test("real IOKit sampling is read-only") {
    do {
        let activity = try DiskActivity.read("disk0")
        expect(activity.registryID != 0 && activity.counters.count == 6, "Valid live counters")
    } catch {
        fatalError("Cannot read real macOS disk statistics: \(error)")
    }
    do {
        _ = try DiskActivity.read("disk999999")
        fatalError("Nonexistent disk must fail")
    } catch {
        expect(error is UnmountCheckError, "Missing disk must report a check error")
    }
}

test("cached mount identity resolves the actual root volume and rejects mismatches") {
    let result = runCommand("/usr/sbin/diskutil", args: ["info", "-plist", "/"])
    let data = Data(result.output.utf8)
    let info = try! PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    let id = info["DeviceIdentifier"] as! String
    do {
        let identity = try VolumeIdentity.read(id, "/")
        expect(identity.registryID != 0 && identity.device == "/dev/\(id)", "Actual mounted device")
        expect(identity.mountPoint == "/" && identity.filesystemID.count == 2, "Cached mount identity")
        let repeatedIdentity = try VolumeIdentity.read(id, "/")
        expect(repeatedIdentity == identity, "Stable cached identity")
    } catch {
        fatalError("Cannot read cached mount identity: \(error)")
    }
    do {
        _ = try VolumeIdentity.read(id, "/nonexistent-mount")
        fatalError("Mismatched mount point must fail")
    } catch {
        expect(error is UnmountCheckError, "Mount mismatch must report a check error")
    }
    do {
        _ = try VolumeIdentity.read("disk999999", "/")
        fatalError("Missing volume must fail")
    } catch {
        expect(error is UnmountCheckError, "Missing device must report a check error")
    }
}

test("command runner drains output larger than the pipe buffer") {
    let result = runCommand("/usr/bin/head", args: ["-c", "100000", "/dev/zero"])
    expect(result.ok && result.output.utf8.count == 100000, "Large output must not deadlock")
}

test("command timeout returns failure promptly and allows the next command") {
    let start = ProcessInfo.processInfo.systemUptime
    let result = runCommand("/bin/sleep", args: ["10"], timeout: 0.1)
    expect(!result.ok && result.timedOut, "Timeout must be explicit failure")
    expect(ProcessInfo.processInfo.systemUptime - start < 3, "No unlimited wait")
    let next = runCommand("/usr/bin/printf", args: ["recovered"], timeout: 1)
    expect(next.ok && !next.timedOut && next.output == "recovered", "Runner recovers after timeout")
}

test("timeout remains failure even when process ignores termination") {
    let result = runCommand("/usr/bin/python3", args: [
        "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(10)"
    ], timeout: 0.5)
    expect(!result.ok && result.timedOut, "Escalated timeout cannot report partial output as success")
}

test("command launch errors are explicit") {
    let result = runCommand("/nonexistent-SmartDiskGuard-command", args: [], timeout: 1)
    expect(!result.ok && !result.timedOut && !result.output.isEmpty, "Report launch failure")
}

test("app exit cleanup terminates only registered commands and lets them return") {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuardOwnedTest-\(UUID().uuidString)")
    defer { try! FileManager.default.removeItem(at: marker) }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let result = runCommand("/usr/bin/python3", args: [
            "-c", "import pathlib,time,sys; pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(20)", marker.path
        ], timeout: 25)
        expect(!result.ok, "Cancelled owned command must report failure")
        finished.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    expect(FileManager.default.fileExists(atPath: marker.path), "Owned child started")
    CommandProcesses.shared.terminateOwnedCommands()
    expect(finished.wait(timeout: .now() + 3) == .success, "Exit cleanup releases waiting command")
}

test("diagnostic logs rotate and retain only nine backups") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuardLogsTests-\(UUID().uuidString)")
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { fatalError("Cannot clean log test directory: \(error)") }
    }
    let logger = DiagnosticLog(directory: directory, maxBytes: 1)
    for index in 1...12 { logger.write("test-entry-\(index)") }
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        expect(Set(files) == Set(["SmartDiskGuard.log"] + (1...9).map { "SmartDiskGuard.\($0).log" }), "Bounded retained files")
        let current = try String(contentsOf: directory.appendingPathComponent("SmartDiskGuard.log"), encoding: .utf8)
        let oldest = try String(contentsOf: directory.appendingPathComponent("SmartDiskGuard.9.log"), encoding: .utf8)
        expect(current.contains("test-entry-12") && oldest.contains("test-entry-3"), "Correct rotation order")
    } catch { fatalError("Cannot inspect log rotation: \(error)") }
}

test("log expiration removes an active file even if it was recently appended") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuardAgeTests-\(UUID().uuidString)")
    defer { try! FileManager.default.removeItem(at: directory) }
    var clock = Date()
    let logger = DiagnosticLog(directory: directory, now: { clock })
    logger.write("old-entry")
    clock = clock.addingTimeInterval(9 * 24 * 60 * 60)
    logger.write("recent-entry-in-old-file")
    let before = try! String(contentsOf: directory.appendingPathComponent("SmartDiskGuard.log"), encoding: .utf8)
    expect(before.contains("old-entry"), "Retain before ten days")
    clock = clock.addingTimeInterval(2 * 24 * 60 * 60)
    logger.write("new-entry")
    let after = try! String(contentsOf: directory.appendingPathComponent("SmartDiskGuard.log"), encoding: .utf8)
    expect(after.contains("new-entry") && !after.contains("old-entry"), "Expire by creation, not last write")
}

test("log total byte limit includes active file and all backups") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuardSizeTests-\(UUID().uuidString)")
    defer { try! FileManager.default.removeItem(at: directory) }
    let logger = DiagnosticLog(directory: directory, maxBytes: 220, maxTotalBytes: 512)
    for index in 1...12 {
        logger.write("entry-\(index) " + String(repeating: "x", count: 80))
        let files = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let size = files.reduce(0) {
            $0 + (try! FileManager.default.attributesOfItem(atPath: $1.path)[.size] as! NSNumber).intValue
        }
        expect(size <= 512, "Enforce total byte limit after every write")
    }
    let current = try! String(contentsOf: directory.appendingPathComponent("SmartDiskGuard.log"), encoding: .utf8)
    expect(current.contains("entry-12"), "Newest records retained")
}

test("default log cap removes oversized legacy files and preserves unrelated files") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmartDiskGuardDefaultSizeTests-\(UUID().uuidString)")
    defer { try! FileManager.default.removeItem(at: directory) }
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0...9 {
        let name = index == 0 ? "SmartDiskGuard.log" : "SmartDiskGuard.\(index).log"
        try! Data(repeating: 120, count: 1_200_000).write(to: directory.appendingPathComponent(name))
    }
    let unrelated = directory.appendingPathComponent("unrelated.txt")
    try! Data("keep".utf8).write(to: unrelated)
    DiagnosticLog(directory: directory).write("new-record")
    let files = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "log" }
    let size = files.reduce(0) {
        $0 + (try! FileManager.default.attributesOfItem(atPath: $1.path)[.size] as! NSNumber).intValue
    }
    expect(size <= 10 * 1024 * 1024, "Exact default 10 MB total limit")
    expect(FileManager.default.fileExists(atPath: unrelated.path), "Never delete unrelated files")
}

test("default retry plan allows exactly ten retries after the initial attempt") {
    let settings = UnmountRetrySettings.defaults
    expect(settings.retries == 10 && settings.interval == 30, "Exact default settings")
    var plan = UnmountRetryPlan(targets: ["a", "b"], settings: settings)
    plan.recordFailures(["b"])
    for number in 1...10 {
        expect(plan.canRetry, "Retry \(number) should be available")
        expect(plan.nextRetry() == ["b"], "Only failed volumes may retry")
        expect(plan.retriesUsed == number, "Exact retry count")
        plan.recordFailures(["b"])
    }
    expect(!plan.canRetry && plan.nextRetry() == nil, "No eleventh retry")
}

test("successful retries stop and custom counts are respected") {
    var plan = UnmountRetryPlan(targets: ["a"], settings: UnmountRetrySettings(retries: 2, interval: 7))
    expect(plan.settings.interval == 7 && plan.nextRetry() == ["a"], "Custom retry policy")
    plan.recordFailures([])
    expect(!plan.canRetry && plan.nextRetry() == nil, "Success stops immediately")
    let disabled = UnmountRetryPlan(targets: ["a"], settings: UnmountRetrySettings(retries: 0, interval: 30))
    expect(!disabled.canRetry, "Zero disables retries but not initial attempt")
}

test("retry settings validate integers and allow zero retry count") {
    do {
        let settings = try UnmountRetrySettings.parse(retries: " 0 ", interval: "1")
        expect(settings == UnmountRetrySettings(retries: 0, interval: 1), "Valid boundary settings")
    } catch { fatalError("Valid settings rejected: \(error)") }
    for pair in [("-1", "30"), ("10", "0"), ("10", "-1"), ("1.5", "30"),
                 ("10", "abc"), ("", "30"), ("99999999999999999999999999", "30")] {
        do {
            _ = try UnmountRetrySettings.parse(retries: pair.0, interval: pair.1)
            fatalError("Invalid settings accepted")
        } catch { expect(error is UnmountCheckError, "Explicit settings error") }
    }
}

test("retry identity prevents unmounting a replacement volume") {
    let f = Fixture()
    var pinned: VolumeIdentity?
    f.samples.append(DiskActivity(registryID: 9, counters: [11, 20, 1, 2, 100, 200]))
    expect(!f.service.unmount("disk9s2", identityVerified: { pinned = $0 }).ok, "First busy attempt")
    expect(pinned != nil, "First attempt pins volume identity")
    f.volumeIdentity = VolumeIdentity(
        registryID: 91, device: "/dev/disk9s2", mountPoint: "/Volumes/Test", filesystemID: [3, 4]
    )
    expect(!f.service.unmount("disk9s2", expectedIdentity: pinned).ok, "Replacement must be rejected")
    expect(f.unmountCommands.isEmpty, "Never unmount the replacement")
}

test("list-based metadata resolves APFS only when every backing store is external") {
    let physical: [String: Any] = [
        "AllDisksAndPartitions": [
            ["OSInternal": false, "DeviceIdentifier": "disk9",
             "Partitions": [["DeviceIdentifier": "disk9s2", "VolumeUUID": "store"]]]
        ]
    ]
    for store in ["disk9s2", "disk0s2"] {
        var calls: [[String]] = []
        do {
            let info = try SafeUnmount.ExternalDiskMetadata.read("disk12s1", command: { _, args in
                calls.append(args)
                if args == ["list", "-plist", "external", "physical"] { return plist(physical) }
                expect(args == ["apfs", "list", "-plist"], "Never query bootability via info")
                return plist(["Containers": [[
                    "PhysicalStores": [["DeviceIdentifier": store]],
                    "Volumes": [["DeviceIdentifier": "disk12s1", "APFSVolumeUUID": "volume",
                                 "MountPoint": "/Volumes/Test"]]
                ]]])
            })
            expect(store == "disk9s2", "Internal or image-backed store must fail")
            expect(info["VolumeUUID"] as? String == "volume" && info["FilesystemType"] as? String == "apfs", "APFS metadata preserved")
        } catch {
            expect(store == "disk0s2", "Valid external store should resolve")
        }
        expect(calls.count == 2, "Bounded list lookups")
    }
}

print("\(testCount) checks passed; no real disk was mounted or unmounted.")
