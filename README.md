# Mobile Tunnel Manager

English · [简体中文](README.zh-CN.md)

A macOS menu bar app for managing TCP port forwarding between your Mac and connected mobile devices. Save multiple rules per device and toggle them individually in the main window or the menu bar. Enabled rules resume when the device reconnects.

| Platform | Direction | Backend |
| --- | --- | --- |
| Android | Mac → device | `adb forward` |
| Android | Device → Mac | `adb reverse` |
| iOS / iPadOS | Mac → device | `iproxy` over USB or paired Wi-Fi |

## Build and run

Requires macOS 14 or later, Swift 5.9 or later, and the Xcode command-line tools. Install Android SDK Platform-Tools for Android, or libimobiledevice and libusbmuxd for iOS. You can install them with Homebrew:

```sh
brew install --cask android-platform-tools
brew install libimobiledevice libusbmuxd
```

```sh
bash build-app.sh
open "dist/Mobile Tunnel Manager.app"
```

## Usage

The app interface is currently in Simplified Chinese. Enable debugging and authorize your Mac on Android. Connect wireless Android devices to the local ADB server first. For iOS over Wi-Fi, pair the device with your Mac and enable Wi-Fi syncing.

The app shows custom iOS device names when available. When the device reports a generic name such as “iPhone” or “iPad,” the app looks up its model using libirecovery if installed. If the model is unknown, it shows the model identifier and the last characters of the UDID.

Select a device, add a rule, and turn on its switch. An active status means ADB registered the forward or the proxy has started listening. The destination service still needs to be running. Rules are saved in `~/Library/Application Support/MobileTunnelManager/tunnels.json`.

Preferences (偏好设置) has separate options to launch at login and restore previously enabled rules when the app starts. Turn on both to restore forwarding at login. macOS may ask you to approve the login item under **System Settings → General → Login Items & Extensions**.

## Port conflicts

Mac-to-device rules check the Mac listening port while you edit the rule and again when you enable it. The app keeps the rule and retries if the port is busy. With Android reverse forwarding, the Mac port is the destination and can already be in use by your local service.

To free a port, click **View port owners** (查看占用进程…) to see the process name, PID, and listening address. When you confirm **Force quit** (强制结束), the app checks that the process still owns the listener and sends `SIGKILL`. You can only end processes owned by the current user. Force quitting can interrupt the process’s other connections and lose unsaved data.

The iOS proxy listens on `127.0.0.1`. Android uses the local ADB server and preserves existing mappings. The app removes forwarding rules it created during the session when you quit. If ADB still reports a conflict after the app was force quit, use `adb forward --list` or `adb -s SERIAL reverse --list` to inspect existing mappings.
