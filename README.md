# 智能外接盘管家 (SmartDiskGuard)

![Platform](https://img.shields.io/badge/Platform-macOS%2012.0%2B-blue)
![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20%7C%20Universal-success)
![Language](https://img.shields.io/badge/Language-Swift%205-orange)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

**智能外接盘管家 (SmartDiskGuard)** 是一款极简、零后台轮询开销的 macOS 原生外接存储挂载/卸载（Mount / Unmount）管理工具。

专为连接机械硬盘、移动固态硬盘或扩展坞的 Mac 用户打造，彻底解决**外接硬盘长期挂载引发的 macOS 系统休眠唤醒 I/O 死锁（Dock 应用无限跳动无法打开）、Spotlight 后台频繁唤醒读写、盘体发热与寿命损耗**等痛点。

---

## ✨ 核心特性

- **🔌 物理常插，软件级休眠与秒级唤醒**：
  - 无需反复插拔 USB/雷电数据线。日常不使用外接备份盘时，点击 **Unmount (卸载休眠)** 即可卸载文件系统并让硬盘切入低功耗停转待机状态，彻底隔离 macOS 后台的文件枚举与索引请求。
  - 需要备份或读取数据时，点击 **Mount (挂载连接)** 即可在 1 秒内重新挂载回系统。
- **🔒 锁屏自动 Unmount 保护（可选复选框）**：
  - 内置 `锁屏后自动 Unmount 所有外接硬盘` 开关（自动记忆勾选状态）。
  - 基于 macOS 原生 `DistributedNotificationCenter` 监听 `com.apple.screenIsLocked` 广播，零 CPU 轮询开销。一旦锁屏离开电脑，自动安全卸载所有已挂载的外接硬盘，杜绝睡眠期间发生 I/O 死锁。
- **🛡️ 防占用强制卸载兜底**：
  - 当遇到 Spotlight (`mds`) 或后台进程占用导致普通卸载受阻时，自动弹窗支持交互式执行 `Force Unmount`。
- **⚡ 100% 原生编译 & 自动生成高清图标**：
  - 纯 Swift + AppKit 编写，不依赖任何第三方库或运行时环境。
  - 内置 `make_icon.swift`，基于 Apple SF Symbols 动态渲染全尺寸 Retina 圆角渐变图标 (`.icns`)。

---

## 📂 项目目录结构

```text
SmartDiskGuard/
├── src/
│   └── SmartDiskGuard.swift      # 主程序源码（GUI + diskutil 调度 + 锁屏事件监听）
├── scripts/
│   └── make_icon.swift           # 基于 SF Symbols 自动生成 AppIcon.icns 的渲染脚本
├── .github/
│   └── workflows/
│       └── release.yml           # GitHub Actions 自动编译打包 DMG 工作流
├── build.sh                      # 一键编译生成 .app 的构建脚本（支持 Universal 通用架构）
├── package_dmg.sh                # 一键制作发行版 .dmg 安装镜像脚本
├── LICENSE                       # MIT 开源许可证
└── README.md                     # 项目说明文档
```

---

## 🚀 快速开始（本地编译与打包）

### 1. 编译生成 `.app` 应用程序

克隆本仓库后，在项目根目录执行：

```bash
chmod +x build.sh package_dmg.sh
./build.sh
```

编译完成后，生成的应用位于 `dist/智能外接盘管家.app`，可直接将其拖入 `/Applications`（应用程序）目录使用。

### 2. 打包生成 `.dmg` 分发安装镜像

如需分享给他人，可执行：

```bash
./package_dmg.sh
```

脚本会自动在 `dist/` 目录下生成 **`dist/智能外接盘管家_安装包.dmg`**，内含应用本体、`Applications` 拖拽快捷方式以及首次打开解除 Gatekeeper 隔离的辅助脚本。

---

## 💡 使用注意事项

1. **为什么平时要用 Unmount 而不是在 Finder 点击“推出 (Eject)”？**
   - Finder 中的“推出 (Eject)”会调用 `diskutil eject` 从 USB 总线层断开设备供电，之后必须**物理拔插数据线**才能再次识别。
   - 本工具的 **Unmount** 仅卸载卷宗文件系统（`diskutil unmount`），硬件仍保持总线就绪并进入停转待机，随时点击 **Mount** 即可立即恢复挂载。
2. **首次打开未公证提示**：
   - 如从 Release 下载直接运行提示“无法验证开发者”，可在终端执行：
     ```bash
     xattr -cr "/Applications/智能外接盘管家.app"
     ```

---

## 📄 开源协议

本项目基于 [MIT License](LICENSE) 开源。
