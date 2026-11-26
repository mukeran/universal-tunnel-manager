# Mobile Tunnel Manager

[English](README.md) · 简体中文

用于管理已连接手机与 Mac 之间 TCP 转发的 macOS 菜单栏应用。支持为每台设备保存多条规则，从主窗口或菜单栏单独启停。设备重新接入时，会恢复仍处于启用状态的规则。

| 平台 | 方向 | 后端 |
| --- | --- | --- |
| Android | Mac → 设备 | `adb forward` |
| Android | 设备 → Mac | `adb reverse` |
| iOS / iPadOS | Mac → 设备 | `iproxy`（USB 或已配对的 Wi-Fi 设备） |

## 构建与打开

需要 macOS 14 或更新版本、Swift 5.9 或更新版本及 Xcode 命令行工具。对应设备需要 Android SDK Platform-Tools，或 libimobiledevice 和 libusbmuxd。如果本机还没装，可用 Homebrew 安装：

```sh
brew install --cask android-platform-tools
brew install libimobiledevice libusbmuxd
```

```sh
bash build-app.sh
open "dist/Mobile Tunnel Manager.app"
```

## 使用

Android 请先打开调试并完成授权。无线 Android 设备需先连接到本机 ADB，iOS Wi-Fi 设备需先与 Mac 配对并启用 Wi-Fi 同步。

iOS 设备优先显示自定义名称。设备只返回「iPhone」或「iPad」时，应用会用已安装的 libirecovery 型号表查找具体型号，查不到时显示型号代码和 UDID 尾号。

选中设备，添加转发规则后打开开关。「已建立」表示转发已注册或代理已开始监听，目标端口仍需要实际运行服务。配置保存在 `~/Library/Application Support/MobileTunnelManager/tunnels.json`。

左下角偏好设置可单独开启「登录时自动启动」和「启动应用时恢复上次启用的转发」。需要随登录恢复转发时，打开这两项。macOS 可能要求在「系统设置 → 通用 → 登录项与扩展」中批准登录项。

## 端口冲突

Mac → 设备的规则会在编辑时提示本机监听端口冲突，启用时再检查一次。遇到冲突会保留规则并重试。Android 设备 → Mac 的规则把 Mac 端口作为目标，允许本机服务已经在该端口监听。

若需释放冲突端口，点击「查看占用进程…」查看进程名、PID 和监听地址。确认「强制结束」后，应用会核对进程仍在监听该端口并发送 `SIGKILL`。仅可结束当前用户拥有的进程。进程的其他连接也会中断，未保存的数据可能丢失。

iOS 代理监听 `127.0.0.1`。Android 使用本机的 ADB 服务，启动规则时禁止覆盖已有映射。退出应用时会清理本次会话建立的转发。如果应用被强制退出后 ADB 仍报告端口冲突，可用 `adb forward --list` 或 `adb -s SERIAL reverse --list` 查看已有映射。
