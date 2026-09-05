import AppKit
import ServiceManagement

// 用途：管理 Gemini2API 菜单栏应用生命周期、菜单和设置窗口。
// 使用方法：由主程序注册为 NSApplicationDelegate。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cfg = Store.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cfg.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◐"
        HTTPServer.shared.stateDidChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        buildMenu()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = HTTPServer.shared.stop()
    }

    // MARK: 菜单

    private func buildMenu() {
        let menu = NSMenu()
        let running = HTTPServer.shared.running
        let status = NSMenuItem(
            title: running ? "● 运行中  http://localhost:\(cfg.port)" : "○ 已停止",
            action: nil,
            keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "复制 Base URL",
            action: #selector(copyBaseURL),
            keyEquivalent: "c").target = self
        menu.addItem(
            withTitle: running ? "停止服务" : "启动服务",
            action: #selector(toggleServer),
            keyEquivalent: "").target = self
        menu.addItem(
            withTitle: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ",").target = self

        let launch = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        launch.target = self
        launch.state = cfg.launchAtLogin ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "关于 Gemini2API",
            action: #selector(showAbout),
            keyEquivalent: "").target = self
        menu.addItem(
            withTitle: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        let url = "https://github.com/4she2run2024/gemini-api"
        let credits = NSMutableAttributedString(string: "开源项目\n")
        credits.append(NSAttributedString(string: url, attributes: [.link: URL(string: url)!]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Gemini2API",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        statusItem.button?.title = HTTPServer.shared.running ? "◉" : "○"
        buildMenu()
    }

    // MARK: 动作

    private func startServer() {
        do { try HTTPServer.shared.start() }
        catch { alert("启动失败", "端口 \(cfg.port) 可能被占用：\(error)") }
        refresh()
    }

    @objc private func toggleServer() {
        if HTTPServer.shared.running {
            guard HTTPServer.shared.stop() else {
                alert("停止失败", "listener 未能在期限内停止，请重试。")
                refresh()
                return
            }
            refresh()
        } else {
            startServer()
        }
    }

    @objc private func copyBaseURL() {
        let s = "http://localhost:\(cfg.port)/v1"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        cfg.launchAtLogin.toggle()
        do {
            if cfg.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { alert("开机自启设置失败", "\(error)") }
        cfg.save()
        refresh()
    }

    // MARK: 设置窗口

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(onSave: { [weak self] in
                self?.applySettings()
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func applySettings() {
        cfg.save()
        guard HTTPServer.shared.running else {
            refresh()
            return
        }
        guard HTTPServer.shared.stop() else {
            alert("重启失败", "旧 listener 未能在期限内停止，请重试。")
            refresh()
            return
        }
        startServer()
    }

    private func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }
}
