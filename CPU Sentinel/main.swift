import Cocoa
import UserNotifications

// MARK: - Settings
var autoKill = UserDefaults.standard.bool(forKey: "autoKill")
var showNotifications = UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true
var currentProfileKey = UserDefaults.standard.string(forKey: "sensitivityProfile") ?? "balanced"
var launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
let monitor = ProcessMonitor()
var lastProcesses: [MonitoredProcess] = []
var statusItem: NSStatusItem!

// MARK: - Menu Actions
class MenuActions: NSObject {
    @objc func killProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32 else { return }
        monitor.killProcess(pid)
        notify(title: "CPU Sentinel", body: "Process killed (PID \(pid))")
    }

    @objc func toggleAutoKill(_ sender: NSMenuItem) {
        autoKill = !autoKill
        UserDefaults.standard.set(autoKill, forKey: "autoKill")
        updateMenu()
    }

    @objc func changeSensitivity(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let selected = SensitivityProfile.all.first(where: { $0.key == key }) else { return }
        currentProfileKey = key
        monitor.profile = selected.profile
        UserDefaults.standard.set(key, forKey: "sensitivityProfile")
        monitor.restart()
        updateMenu()
    }

    @objc func toggleNotifications(_ sender: NSMenuItem) {
        showNotifications = !showNotifications
        UserDefaults.standard.set(showNotifications, forKey: "showNotifications")
        updateMenu()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin = !launchAtLogin
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        updateMenu()
    }

    @objc func quit(_ sender: NSMenuItem) {
        monitor.stop()
        NSApp.terminate(nil)
    }
}

let actions = MenuActions()

// MARK: - Notifications
func notify(title: String, body: String) {
    guard showNotifications else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}

// MARK: - Menu Builder
func updateMenu() {
    let menu = NSMenu()

    let header = NSMenuItem(title: "CPU Sentinel", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(NSMenuItem.separator())

    let runaways = lastProcesses.filter { $0.isRunaway }
    let warnings = lastProcesses.filter { $0.isWarning }

    if runaways.isEmpty && warnings.isEmpty {
        let clear = NSMenuItem(title: "All clear", action: nil, keyEquivalent: "")
        clear.isEnabled = false
        menu.addItem(clear)
    }

    if !runaways.isEmpty {
        let label = NSMenuItem(title: "Runaway", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)

        for proc in runaways {
            let item = NSMenuItem(
                title: "\(proc.name) — \(Int(proc.cpu))% CPU, \(proc.memory)MB, \(proc.uptimeFormatted)",
                action: nil, keyEquivalent: ""
            )
            let submenu = NSMenu()
            let killItem = NSMenuItem(title: "Kill Process", action: #selector(MenuActions.killProcess(_:)), keyEquivalent: "")
            killItem.target = actions
            killItem.representedObject = proc.pid
            submenu.addItem(killItem)
            submenu.addItem(NSMenuItem.separator())
            let info = NSMenuItem(title: "PID \(proc.pid) · \(proc.memory)MB RAM", action: nil, keyEquivalent: "")
            info.isEnabled = false
            submenu.addItem(info)
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    if !warnings.isEmpty {
        if !runaways.isEmpty { menu.addItem(NSMenuItem.separator()) }
        let label = NSMenuItem(title: "Watch List", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)

        for proc in warnings {
            let item = NSMenuItem(
                title: "\(proc.name) — \(Int(proc.cpu))% CPU, \(proc.memory)MB, \(proc.uptimeFormatted)",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    menu.addItem(NSMenuItem.separator())

    let autoKillItem = NSMenuItem(title: "Auto-Kill", action: #selector(MenuActions.toggleAutoKill(_:)), keyEquivalent: "")
    autoKillItem.target = actions
    autoKillItem.state = autoKill ? .on : .off
    menu.addItem(autoKillItem)

    let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
    let sensitivityMenu = NSMenu()
    for (key, profile) in SensitivityProfile.all {
        let item = NSMenuItem(title: profile.label, action: #selector(MenuActions.changeSensitivity(_:)), keyEquivalent: "")
        item.target = actions
        item.representedObject = key
        item.state = currentProfileKey == key ? .on : .off
        sensitivityMenu.addItem(item)
    }
    sensitivityItem.submenu = sensitivityMenu
    menu.addItem(sensitivityItem)

    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    let settingsMenu = NSMenu()
    let notifItem = NSMenuItem(title: "Notifications", action: #selector(MenuActions.toggleNotifications(_:)), keyEquivalent: "")
    notifItem.target = actions
    notifItem.state = showNotifications ? .on : .off
    settingsMenu.addItem(notifItem)

    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(MenuActions.toggleLaunchAtLogin(_:)), keyEquivalent: "")
    loginItem.target = actions
    loginItem.state = launchAtLogin ? .on : .off
    settingsMenu.addItem(loginItem)

    settingsItem.submenu = settingsMenu
    menu.addItem(settingsItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "Quit", action: #selector(MenuActions.quit(_:)), keyEquivalent: "q")
    quitItem.target = actions
    menu.addItem(quitItem)

    statusItem.menu = menu
}

// MARK: - App Setup
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
if let button = statusItem.button {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    if let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU Sentinel")?.withSymbolConfiguration(config) {
        image.isTemplate = true
        button.image = image
    } else {
        button.title = "●"
    }
}

UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

if let saved = SensitivityProfile.all.first(where: { $0.key == currentProfileKey }) {
    monitor.profile = saved.profile
}

monitor.onScan = { processes in
    lastProcesses = processes
    updateMenu()
}

monitor.onRunaway = { proc in
    if autoKill {
        monitor.killProcess(proc.pid)
        notify(title: "CPU Sentinel - Killed", body: "\(proc.name) — \(Int(proc.cpu))% CPU, running \(proc.uptimeFormatted)")
    } else {
        notify(title: "CPU Sentinel - Runaway Detected", body: "\(proc.name) — \(Int(proc.cpu))% CPU, running \(proc.uptimeFormatted)")
    }
}

updateMenu()
monitor.start()
app.run()
