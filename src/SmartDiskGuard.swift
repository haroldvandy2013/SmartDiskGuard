import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var diskPopup: NSPopUpButton!
    var statusLabel: NSTextField!
    var autoUnmountCheckbox: NSButton!
    var logLabel: NSTextField!
    var mountButton: NSButton!
    var unmountButton: NSButton!
    var versionLabel: NSTextField!
    var diskOperationInProgress = false
    var screenLocked = false
    var displayAsleep = false
    var advancedButton: NSButton!
    var advancedView: NSView!
    var retryCountField: NSTextField!
    var retryIntervalField: NSTextField!
    var advancedExpanded = false
    var retrySettings = UnmountRetrySettings.defaults
    var retryTimer: Timer?
    var automaticGeneration = 0
    struct UnmountTarget {
        let volume: ExternalVolume
        var identity: VolumeIdentity?
    }
    var retryPlan: UnmountRetryPlan<UnmountTarget>?
    var preferences = UserDefaults.standard
    var makeSafeUnmount: () -> SafeUnmount = { SafeUnmount() }
    
    struct ExternalVolume {
        let id: String
        let name: String
        let mounted: Bool
    }
    var volumes: [ExternalVolume] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 440, height: 250)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionText: String
        if let version = version, !version.isEmpty {
            versionText = "v\(version)"
        } else {
            versionText = "版本信息缺失"
            NSLog("SmartDiskGuard: missing application version in Info.plist")
        }
        window.title = "智能外接硬盘管家 — \(versionText)"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: rect)
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "检测到的外接硬盘：")
        titleLabel.frame = NSRect(x: 24, y: 202, width: 140, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        contentView.addSubview(titleLabel)

        versionLabel = NSTextField(labelWithString: versionText)
        versionLabel.frame = NSRect(x: 174, y: 202, width: 242, height: 20)
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .right
        contentView.addSubview(versionLabel)

        diskPopup = NSPopUpButton(frame: NSRect(x: 24, y: 168, width: 310, height: 28), pullsDown: false)
        diskPopup.target = self
        diskPopup.action = #selector(selectionChanged)
        contentView.addSubview(diskPopup)

        let refreshBtn = NSButton(frame: NSRect(x: 342, y: 168, width: 74, height: 28))
        refreshBtn.title = "刷新列表"
        refreshBtn.bezelStyle = .rounded
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshDisks)
        contentView.addSubview(refreshBtn)

        statusLabel = NSTextField(labelWithString: "状态：正在扫描...")
        statusLabel.frame = NSRect(x: 24, y: 136, width: 392, height: 22)
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(statusLabel)

        let mountBtn = NSButton(frame: NSRect(x: 24, y: 86, width: 186, height: 38))
        mountBtn.title = "Mount (挂载连接)"
        mountBtn.bezelStyle = .rounded
        mountBtn.font = NSFont.boldSystemFont(ofSize: 13)
        mountBtn.target = self
        mountBtn.action = #selector(mountSelected)
        mountButton = mountBtn
        contentView.addSubview(mountBtn)

        let unmountBtn = NSButton(frame: NSRect(x: 230, y: 86, width: 186, height: 38))
        unmountBtn.title = "Unmount (卸载休眠)"
        unmountBtn.bezelStyle = .rounded
        unmountBtn.font = NSFont.boldSystemFont(ofSize: 13)
        unmountBtn.target = self
        unmountBtn.action = #selector(unmountSelected)
        unmountButton = unmountBtn
        contentView.addSubview(unmountBtn)

        autoUnmountCheckbox = NSButton(checkboxWithTitle: "锁屏或熄屏后安全卸载空闲外接盘（运行期间生效）", target: self, action: #selector(checkboxChanged))
        autoUnmountCheckbox.frame = NSRect(x: 24, y: 46, width: 392, height: 24)
        let savedState = preferences.object(forKey: "AutoUnmountOnLock") as? Bool ?? true
        autoUnmountCheckbox.state = savedState ? .on : .off
        contentView.addSubview(autoUnmountCheckbox)

        logLabel = NSTextField(labelWithString: "提示：用完请点 Unmount，勿在 Finder 点推出(Eject)。")
        logLabel.frame = NSRect(x: 24, y: 14, width: 392, height: 20)
        logLabel.font = NSFont.systemFont(ofSize: 11)
        logLabel.textColor = .secondaryLabelColor
        contentView.addSubview(logLabel)

        for view in contentView.subviews {
            view.frame.origin.y += 32
        }
        window.setContentSize(NSSize(width: 440, height: 282))
        advancedButton = NSButton(title: "▸ Advanced", target: self, action: #selector(toggleAdvanced))
        advancedButton.frame = NSRect(x: 24, y: 8, width: 140, height: 24)
        advancedButton.isBordered = false
        advancedButton.alignment = .left
        contentView.addSubview(advancedButton)

        advancedView = NSView(frame: NSRect(x: 24, y: 8, width: 392, height: 96))
        advancedView.isHidden = true
        contentView.addSubview(advancedView)
        loadRetrySettings()
        let retryLabel = NSTextField(labelWithString: "自动卸载重试次数：")
        retryLabel.frame = NSRect(x: 0, y: 66, width: 145, height: 22)
        advancedView.addSubview(retryLabel)
        retryCountField = NSTextField(string: "\(retrySettings.retries)")
        retryCountField.frame = NSRect(x: 150, y: 64, width: 75, height: 24)
        advancedView.addSubview(retryCountField)
        let intervalLabel = NSTextField(labelWithString: "重试间隔（秒）：")
        intervalLabel.frame = NSRect(x: 0, y: 34, width: 145, height: 22)
        advancedView.addSubview(intervalLabel)
        retryIntervalField = NSTextField(string: "\(retrySettings.interval)")
        retryIntervalField.frame = NSRect(x: 150, y: 32, width: 75, height: 24)
        advancedView.addSubview(retryIntervalField)
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveRetrySettings))
        saveButton.frame = NSRect(x: 245, y: 32, width: 70, height: 26)
        saveButton.bezelStyle = .rounded
        advancedView.addSubview(saveButton)
        let settingsHint = NSTextField(labelWithString: "首次尝试之外的重试次数；0 为不重试。保存后下轮生效。")
        settingsHint.font = NSFont.systemFont(ofSize: 10)
        settingsHint.frame = NSRect(x: 0, y: 4, width: 392, height: 20)
        advancedView.addSubview(settingsHint)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )

        refreshDisks()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        refreshDisks()
        return true
    }

    @objc func checkboxChanged() {
        let isChecked = (autoUnmountCheckbox.state == .on)
        preferences.set(isChecked, forKey: "AutoUnmountOnLock")
        if !isChecked { cancelAutomaticUnmount() }
        logLabel.stringValue = isChecked ? "✅ 已开启：锁屏或熄屏时检查读写后安全卸载" : "⚪️ 已关闭自动卸载"
    }

    @objc func screenDidLock() {
        screenLocked = true
        automaticallyUnmount()
    }

    @objc func screenDidUnlock() {
        screenLocked = false
        if !displayAsleep { cancelAutomaticUnmount() }
    }

    @objc func screensDidSleep() {
        displayAsleep = true
        automaticallyUnmount()
    }

    @objc func screensDidWake() {
        displayAsleep = false
        if !screenLocked { cancelAutomaticUnmount() }
    }

    func loadRetrySettings() {
        let defaults = preferences
        guard defaults.object(forKey: "AutoUnmountRetryCount") != nil ||
              defaults.object(forKey: "AutoUnmountRetryInterval") != nil else { return }
        do {
            retrySettings = try UnmountRetrySettings.parse(
                retries: defaults.string(forKey: "AutoUnmountRetryCount") ?? "",
                interval: defaults.string(forKey: "AutoUnmountRetryInterval") ?? ""
            )
        } catch {
            retrySettings = .defaults
            NSLog("Invalid automatic unmount settings: %@", error.localizedDescription)
            logLabel.stringValue = "⚠️ 重试设置无效，已恢复默认值"
        }
    }

    @objc func toggleAdvanced() {
        let delta: CGFloat = advancedExpanded ? -104 : 104
        let top = window.frame.maxY
        for view in window.contentView!.subviews where view !== advancedView {
            view.frame.origin.y += delta
        }
        window.setContentSize(NSSize(width: 440, height: advancedExpanded ? 282 : 386))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        advancedExpanded.toggle()
        advancedView.isHidden = !advancedExpanded
        advancedButton.title = advancedExpanded ? "▾ Advanced" : "▸ Advanced"
    }

    @objc func saveRetrySettings() {
        do {
            retrySettings = try UnmountRetrySettings.parse(
                retries: retryCountField.stringValue, interval: retryIntervalField.stringValue
            )
            preferences.set("\(retrySettings.retries)", forKey: "AutoUnmountRetryCount")
            preferences.set("\(retrySettings.interval)", forKey: "AutoUnmountRetryInterval")
            retryCountField.stringValue = "\(retrySettings.retries)"
            retryIntervalField.stringValue = "\(retrySettings.interval)"
            logLabel.stringValue = "✅ 重试 \(retrySettings.retries) 次 / 间隔 \(retrySettings.interval) 秒，下轮生效"
        } catch {
            let alert = NSAlert()
            alert.messageText = "重试设置无效"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    var automaticUnmountAllowed: Bool {
        autoUnmountCheckbox.state == .on && (screenLocked || displayAsleep)
    }

    func cancelAutomaticUnmount() {
        automaticGeneration += 1
        retryTimer?.invalidate()
        retryTimer = nil
        let hadPlan = retryPlan != nil
        retryPlan = nil
        if hadPlan { logLabel.stringValue = "⚪️ 已取消自动卸载重试" }
    }

    func automaticallyUnmount() {
        guard automaticUnmountAllowed, !diskOperationInProgress, retryPlan == nil else { return }
        refreshDisks()
        let mountedVolumes = volumes.filter { $0.mounted }
        guard !mountedVolumes.isEmpty else { return }
        automaticGeneration += 1
        let targets = mountedVolumes.map { UnmountTarget(volume: $0) }
        retryPlan = UnmountRetryPlan(targets: targets, settings: retrySettings)
        safelyUnmount(targets, automatic: true)
    }

    func scheduleAutomaticRetry() {
        guard automaticUnmountAllowed, let plan = retryPlan else {
            retryPlan = nil
            return
        }
        guard plan.canRetry else {
            if !plan.pending.isEmpty {
                logLabel.stringValue = "⚠️ 自动重试已用完（\(plan.settings.retries) 次），仍有 \(plan.pending.count) 个未卸载"
            }
            retryPlan = nil
            return
        }
        let generation = automaticGeneration
        logLabel.stringValue = "⏳ \(plan.settings.interval) 秒后重试 \(plan.retriesUsed + 1)/\(plan.settings.retries)"
        retryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(plan.settings.interval), repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard generation == self.automaticGeneration, self.automaticUnmountAllowed,
                  let targets = self.retryPlan?.nextRetry() else { return }
            self.retryTimer = nil
            self.safelyUnmount(targets, automatic: true)
        }
    }

    func safelyUnmount(_ targets: [UnmountTarget], automatic: Bool) {
        guard !diskOperationInProgress else { return }
        diskOperationInProgress = true
        mountButton.isEnabled = false
        unmountButton.isEnabled = false
        logLabel.stringValue = "正在检查硬盘读写，请稍候..."
        let generation = automaticGeneration
        let service = makeSafeUnmount()
        DispatchQueue.global(qos: .utility).async {
            var unmountedCount = 0
            var failures: [String] = []
            var failedTargets: [UnmountTarget] = []
            for var target in targets {
                let volume = target.volume
                let result = service.unmount(volume.id, expectedIdentity: target.identity, identityVerified: {
                    target.identity = $0
                }, shouldProceed: {
                    guard automatic else { return true }
                    return DispatchQueue.main.sync {
                        generation == self.automaticGeneration && self.automaticUnmountAllowed
                    }
                })
                if result.ok {
                    unmountedCount += 1
                } else {
                    failures.append("\(volume.name)：\(result.output)")
                    failedTargets.append(target)
                }
            }
            let count = unmountedCount
            let failedCount = failures.count
            let details = failures.joined(separator: "\n")
            let pending = failedTargets
            DispatchQueue.main.async {
                self.diskOperationInProgress = false
                self.mountButton.isEnabled = true
                self.unmountButton.isEnabled = true
                self.refreshDisks()
                self.logLabel.stringValue = failedCount == 0
                    ? "💤 已安全卸载 \(count) 个外接卷宗"
                    : "⚠️ 已卸载 \(count) 个，未卸载 \(failedCount) 个（详情见提示）"
                self.logLabel.toolTip = details.isEmpty ? nil : details
                if automatic, generation == self.automaticGeneration {
                    self.retryPlan?.recordFailures(pending)
                    self.scheduleAutomaticRetry()
                } else if automatic {
                    self.logLabel.stringValue = "⚪️ 自动卸载已取消，成功 \(count) 个"
                }
                if !details.isEmpty {
                    NSLog("Safe unmount: %@", details)
                    if !automatic {
                        let alert = NSAlert()
                        alert.messageText = "未执行卸载"
                        alert.informativeText = details
                        alert.addButton(withTitle: "好")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc func refreshDisks() {
        volumes.removeAll()
        diskPopup.removeAllItems()

        let res = runCommand("/usr/sbin/diskutil", args: ["list", "-plist", "external"])
        if res.ok, let data = res.output.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] {

            for disk in allDisks {
                let parts = (disk["Partitions"] as? [[String: Any]] ?? []) + (disk["APFSVolumes"] as? [[String: Any]] ?? [])
                for p in parts {
                    let devId = p["DeviceIdentifier"] as? String ?? ""
                    var volName = p["VolumeName"] as? String ?? ""
                    var mountPt = p["MountPoint"] as? String ?? ""
                    let content = p["Content"] as? String ?? ""

                    if ["EFI", "Apple_APFS_ISC", "Apple_APFS_Recovery"].contains(content) { continue }
                    if ["EFI", "Recovery", "Preboot", "VM", "Update"].contains(volName) { continue }

                    if volName.isEmpty && !devId.isEmpty {
                        let infoRes = runCommand("/usr/sbin/diskutil", args: ["info", "-plist", devId])
                        if infoRes.ok, let iData = infoRes.output.data(using: .utf8),
                           let iPlist = try? PropertyListSerialization.propertyList(from: iData, options: [], format: nil) as? [String: Any] {
                            if (iPlist["Internal"] as? Bool) == true { continue }
                            volName = (iPlist["VolumeName"] as? String) ?? (iPlist["MediaName"] as? String) ?? devId
                            mountPt = (iPlist["MountPoint"] as? String) ?? ""
                        }
                    }

                    let display = volName.isEmpty ? devId : volName
                    let isMounted = !mountPt.isEmpty
                    volumes.append(ExternalVolume(id: devId, name: display, mounted: isMounted))
                }
            }
        }

        if volumes.isEmpty {
            diskPopup.addItem(withTitle: "未检测到外接硬盘")
            diskPopup.isEnabled = false
            statusLabel.stringValue = "当前状态：未检测到外接硬盘（请确认未点击 Finder 弹出）"
        } else {
            diskPopup.isEnabled = true
            for v in volumes {
                let tag = v.mounted ? "🟢 已挂载" : "⚪️ 已卸载"
                diskPopup.addItem(withTitle: "\(v.name) (\(v.id)) — [\(tag)]")
            }
            selectionChanged()
        }
    }

    @objc func selectionChanged() {
        let idx = diskPopup.indexOfSelectedItem
        guard idx >= 0 && idx < volumes.count else { return }
        let v = volumes[idx]
        statusLabel.stringValue = "当前选中：\(v.name) (\(v.id))   |   状态：" + (v.mounted ? "🟢 已挂载 (Mounted)" : "⚪️ 已卸载休眠 (Unmounted)")
    }

    @objc func mountSelected() {
        guard !diskOperationInProgress else { return }
        cancelAutomaticUnmount()
        let idx = diskPopup.indexOfSelectedItem
        guard idx >= 0 && idx < volumes.count else { return }
        let v = volumes[idx]
        logLabel.stringValue = "正在挂载 \(v.name)..."
        var res = runCommand("/usr/sbin/diskutil", args: ["mount", v.id])
        if !res.ok {
            res = runCommand("/usr/sbin/diskutil", args: ["mountDisk", v.id])
        }
        refreshDisks()
        logLabel.stringValue = res.ok ? "✅ \(v.name) 挂载成功！" : "❌ 挂载失败：\(res.output)"
    }

    @objc func unmountSelected() {
        guard !diskOperationInProgress else { return }
        cancelAutomaticUnmount()
        let idx = diskPopup.indexOfSelectedItem
        guard idx >= 0 && idx < volumes.count else { return }
        let v = volumes[idx]
        safelyUnmount([UnmountTarget(volume: v)], automatic: false)
    }
}
