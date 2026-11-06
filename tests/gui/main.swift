import Cocoa

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func pumpUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(condition(), "Timed out waiting for app state")
}

final class TestDelegate: AppDelegate {
    override func refreshDisks() {
        volumes = [
            ExternalVolume(id: "disk9s2", name: "test", mounted: true),
            ExternalVolume(id: "disk9s3", name: "test2", mounted: true)
        ]
        diskPopup.removeAllItems()
        diskPopup.addItems(withTitles: ["test", "test2"])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let suiteName = "SmartDiskGuardTests.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suiteName)!
defer { preferences.removePersistentDomain(forName: suiteName) }
let delegate = TestDelegate()
delegate.preferences = preferences
delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
expect(delegate.retrySettings == .defaults, "Default settings")
expect(delegate.advancedView.isHidden && !delegate.advancedExpanded, "Advanced starts collapsed")
let collapsed = delegate.window.contentView!.frame.height
let versionY = delegate.versionLabel.frame.minY
delegate.toggleAdvanced()
expect(delegate.window.contentView!.frame.height == collapsed + 104, "Expand height")
expect(!delegate.advancedView.isHidden, "Expanded fields visible")
expect(delegate.advancedButton.frame.minY > delegate.advancedView.frame.maxY, "Disclosure below main UI")
delegate.toggleAdvanced()
expect(delegate.window.contentView!.frame.height == collapsed, "Collapse height")
expect(delegate.versionLabel.frame.minY == versionY, "No layout drift")
delegate.retryCountField.stringValue = "2"
delegate.retryIntervalField.stringValue = "7"
delegate.saveRetrySettings()
expect(delegate.retrySettings == UnmountRetrySettings(retries: 2, interval: 7), "Edited settings applied")
delegate.retrySettings = .defaults
delegate.loadRetrySettings()
expect(delegate.retrySettings == UnmountRetrySettings(retries: 2, interval: 7), "Settings persisted")

var attempts: [String] = []
var allowSuccess = false
delegate.makeSafeUnmount = {
    SafeUnmount(
        command: { _, args in
            if args.first == "info" {
                let id = args[2]
                attempts.append(id)
                let data = try! PropertyListSerialization.data(fromPropertyList: [
                    "DeviceIdentifier": id, "Internal": false, "WholeDisk": false,
                    "VolumeUUID": id, "MountPoint": "/Volumes/\(id)",
                    "ParentWholeDisk": "disk9", "FilesystemType": "hfs"
                ], format: .xml, options: 0)
                return CommandResult(ok: true, output: String(decoding: data, as: UTF8.self))
            }
            expect(args.first == "unmount" && !args.contains("force"), "Only simulated normal unmount")
            return CommandResult(ok: allowSuccess || args[1] == "disk9s2", output: "simulated")
        },
        activity: { _ in DiskActivity(registryID: 9, counters: [0, 0, 0, 0, 0, 0]) },
        wait: { _ in },
        identity: { id, path in
            VolumeIdentity(registryID: 90, device: "/dev/\(id)", mountPoint: path, filesystemID: [1, 2])
        }
    )
}
delegate.screensDidSleep()
pumpUntil { !delegate.diskOperationInProgress }
expect(attempts == ["disk9s2", "disk9s3"], "Initial batch")
expect(delegate.retryPlan?.pending.count == 1, "Only failed volume pending")
expect(delegate.retryTimer != nil, "Retry scheduled")
expect(abs(delegate.retryTimer!.fireDate.timeIntervalSinceNow - 7) < 1, "Configured interval used")
delegate.screensDidSleep()
expect(attempts.count == 2, "Duplicate sleep event does not restart cycle")
delegate.retrySettings = UnmountRetrySettings(retries: 10, interval: 30)
let firstTimer = delegate.retryTimer!
firstTimer.fire()
firstTimer.invalidate()
pumpUntil { !delegate.diskOperationInProgress }
expect(attempts == ["disk9s2", "disk9s3", "disk9s3"], "Retry excludes successful volume")
expect(delegate.retryPlan?.retriesUsed == 1, "First retry counted")
expect(delegate.retryPlan?.settings.interval == 7, "Active settings snapshot preserved")
let secondTimer = delegate.retryTimer!
secondTimer.fire()
secondTimer.invalidate()
pumpUntil { !delegate.diskOperationInProgress }
expect(attempts.count == 4 && delegate.retryPlan == nil && delegate.retryTimer == nil, "Stop after exactly two retries")
expect(delegate.logLabel.stringValue.contains("重试已用完"), "Exhaustion visible")

delegate.screensDidSleep()
pumpUntil { !delegate.diskOperationInProgress }
expect(delegate.retryPlan?.settings == .defaults, "Next cycle uses new defaults")
expect(abs(delegate.retryTimer!.fireDate.timeIntervalSinceNow - 30) < 1, "Default retry interval is thirty seconds")
let cancelledTimer = delegate.retryTimer!
let count = attempts.count
delegate.screensDidWake()
expect(delegate.retryTimer == nil && delegate.retryPlan == nil, "Wake cancels retry")
cancelledTimer.fire()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
expect(attempts.count == count, "Stale timer cannot run")

delegate.screenDidLock()
pumpUntil { !delegate.diskOperationInProgress }
delegate.autoUnmountCheckbox.state = .off
delegate.checkboxChanged()
expect(delegate.retryTimer == nil && delegate.retryPlan == nil, "Disabling cancels retry")
delegate.autoUnmountCheckbox.state = .on
delegate.screenDidUnlock()
allowSuccess = true
delegate.screensDidSleep()
pumpUntil { !delegate.diskOperationInProgress }
expect(delegate.retryTimer == nil && delegate.retryPlan == nil, "All success stops immediately")
delegate.screensDidWake()

var simulatedUnmounts = 0
delegate.makeSafeUnmount = {
    SafeUnmount(
        command: { _, args in
            if args.first == "unmount" {
                simulatedUnmounts += 1
                return CommandResult(ok: true, output: "simulated")
            }
            let id = args[2]
            let data = try! PropertyListSerialization.data(fromPropertyList: [
                "DeviceIdentifier": id, "Internal": false, "WholeDisk": false,
                "VolumeUUID": id, "MountPoint": "/Volumes/\(id)",
                "ParentWholeDisk": "disk9", "FilesystemType": "hfs"
            ], format: .xml, options: 0)
            return CommandResult(ok: true, output: String(decoding: data, as: UTF8.self))
        },
        activity: { _ in DiskActivity(registryID: 9, counters: [0, 0, 0, 0, 0, 0]) },
        wait: { _ in
            DispatchQueue.main.async { delegate.screensDidWake() }
            Thread.sleep(forTimeInterval: 0.05)
        },
        identity: { id, path in
            VolumeIdentity(registryID: 90, device: "/dev/\(id)", mountPoint: path, filesystemID: [1, 2])
        }
    )
}
delegate.screensDidSleep()
pumpUntil { !delegate.diskOperationInProgress }
expect(simulatedUnmounts == 0 && delegate.retryTimer == nil, "Wake cancels an in-flight safety check")
expect(delegate.mountButton.isEnabled && delegate.unmountButton.isEnabled, "Buttons restored after cancellation")
delegate.window.close()
print("PASS: Advanced layout, persistence, retry timing/count, failed-only retries, cancellation, and success")
print("No real mount or unmount commands were executed.")
