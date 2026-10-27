import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var diskPopup: NSPopUpButton!
    var statusLabel: NSTextField!
    var autoUnmountCheckbox: NSButton!
    var logLabel: NSTextField!
    
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
        window.title = "智能外接盘管家 (SmartDiskGuard)"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: rect)
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "检测到的外接硬盘：")
        titleLabel.frame = NSRect(x: 24, y: 202, width: 140, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        contentView.addSubview(titleLabel)

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
        contentView.addSubview(mountBtn)

        let unmountBtn = NSButton(frame: NSRect(x: 230, y: 86, width: 186, height: 38))
        unmountBtn.title = "Unmount (卸载休眠)"
        unmountBtn.bezelStyle = .rounded
        unmountBtn.font = NSFont.boldSystemFont(ofSize: 13)
        unmountBtn.target = self
        unmountBtn.action = #selector(unmountSelected)
        contentView.addSubview(unmountBtn)

        autoUnmountCheckbox = NSButton(checkboxWithTitle: "锁屏后自动 Unmount 所有外接硬盘（程序运行期间生效）", target: self, action: #selector(checkboxChanged))
        autoUnmountCheckbox.frame = NSRect(x: 24, y: 46, width: 392, height: 24)
        let savedState = UserDefaults.standard.object(forKey: "AutoUnmountOnLock") as? Bool ?? true
        autoUnmountCheckbox.state = savedState ? .on : .off
        contentView.addSubview(autoUnmountCheckbox)

        logLabel = NSTextField(labelWithString: "提示：用完请点 Unmount，勿在 Finder 点推出(Eject)。")
        logLabel.frame = NSRect(x: 24, y: 14, width: 392, height: 20)
        logLabel.font = NSFont.systemFont(ofSize: 11)
        logLabel.textColor = .secondaryLabelColor
        contentView.addSubview(logLabel)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
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
        UserDefaults.standard.set(isChecked, forKey: "AutoUnmountOnLock")
        logLabel.stringValue = isChecked ? "✅ 已开启：锁屏时将自动卸载所有外接盘" : "⚪️ 已关闭锁屏自动卸载"
    }

    @objc func screenDidLock() {
        guard autoUnmountCheckbox.state == .on else { return }
        refreshDisks()
        var unmountedCount = 0
        for v in volumes where v.mounted {
            let res = runCommand("/usr/sbin/diskutil", args: ["unmount", v.id])
            if !res.ok {
                _ = runCommand("/usr/sbin/diskutil", args: ["unmount", "force", v.id])
            }
            unmountedCount += 1
        }
        if unmountedCount > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: Date())
            DispatchQueue.main.async {
                self.refreshDisks()
                self.logLabel.stringValue = "🔒 已在 \(timeStr) 锁屏时自动卸载 \(unmountedCount) 个外接卷宗"
            }
        }
    }

    func runCommand(_ launchPath: String, args: [String]) -> (ok: Bool, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (task.terminationStatus == 0, out)
        } catch {
            return (false, error.localizedDescription)
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
        let idx = diskPopup.indexOfSelectedItem
        guard idx >= 0 && idx < volumes.count else { return }
        let v = volumes[idx]
        logLabel.stringValue = "正在卸载 \(v.name)..."
        var res = runCommand("/usr/sbin/diskutil", args: ["unmount", v.id])
        if !res.ok {
            let alert = NSAlert()
            alert.messageText = "无法正常卸载 \(v.name)"
            alert.informativeText = "可能有后台进程（如 Spotlight）正在占用该盘，是否执行强制卸载 (Force Unmount)？\n\n详情：\(res.output)"
            alert.addButton(withTitle: "强制卸载")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                res = runCommand("/usr/sbin/diskutil", args: ["unmount", "force", v.id])
            } else {
                logLabel.stringValue = "已取消卸载操作"
                return
            }
        }
        refreshDisks()
        logLabel.stringValue = res.ok ? "💤 \(v.name) 已安全卸载并切入待机" : "❌ 卸载失败：\(res.output)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
