import AppKit
import IOKit.pwr_mgt

// ClaudeOvertime — menu bar app that keeps the Mac awake while agentic CLIs
// (Claude Code, Codex, ...) are running.
//
// Split of responsibilities:
//  - This app: detects agent processes, holds a power assertion (prevents
//    idle sleep — no root needed), owns all settings via ~/.config/claude-overtime.conf.
//  - Root helper daemon (/usr/local/libexec/claude-overtime-helper.sh): reads the same
//    config and toggles `pmset disablesleep` for lid-closed running, which
//    macOS only permits as root.

// Process names (exact match) of well-known agentic CLI harnesses.
// Keep in sync with DEFAULT_AGENTS in claude-overtime-helper.sh and status.sh.
let kDefaultAgents = [
    "claude",        // Claude Code
    "codex",         // OpenAI Codex CLI
    "gemini",        // Gemini CLI
    "copilot",       // GitHub Copilot CLI
    "cursor-agent",  // Cursor CLI
    "amp",           // Sourcegraph Amp
    "aider",         // Aider
    "goose",         // Block Goose
    "opencode",      // OpenCode
    "crush",         // Charm Crush
    "qwen",          // Qwen Code
    "droid",         // Factory Droid
    "auggie",        // Augment CLI
]
let kConfigPath = NSString(string: "~/.config/claude-overtime.conf").expandingTildeInPath
let kLogPath = "/var/log/claude-overtime.log"
let kHelperPath = "/usr/local/libexec/claude-overtime-helper.sh"
let kLaunchAgentPath = NSString(string: "~/Library/LaunchAgents/com.claudeovertime.app.plist").expandingTildeInPath

func shell(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var assertionID: IOPMAssertionID = 0
    var assertionActive = false

    // Settings (persisted to config file, shared with the root helper)
    var keepAwake = true
    var lidClosed = true
    var batteryFloor = 10
    var extraAgents: [String] = []       // EXTRA_AGENTS: appended to defaults
    var agentsOverride: [String] = []    // AGENTS: replaces the default list entirely

    var watchedAgents: [String] {
        (agentsOverride.isEmpty ? kDefaultAgents : agentsOverride) + extraAgents
    }

    var runningAgents: [(name: String, count: Int)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Self-healing: if lid-closed is enabled but the helper is missing
        // (or older than the one bundled in this app), prompt to install it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if self.keepAwake && self.lidClosed && self.helperNeedsInstall() {
                self.installHelper()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        setAssertion(false)
    }

    // MARK: - Config

    func loadConfig() {
        guard let text = try? String(contentsOfFile: kConfigPath, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            switch parts[0] {
            case "ENABLED": keepAwake = value != "0"
            case "LID_CLOSED": lidClosed = value != "0"
            case "BATTERY_FLOOR": batteryFloor = Int(value) ?? 10
            case "EXTRA_AGENTS": extraAgents = value.split(separator: " ").map(String.init)
            case "AGENTS": agentsOverride = value.split(separator: " ").map(String.init)
            default: break
            }
        }
    }

    func saveConfig() {
        var text = """
        # ClaudeOvertime settings — edited via the menu bar app; read by the root helper.
        ENABLED=\(keepAwake ? 1 : 0)
        LID_CLOSED=\(lidClosed ? 1 : 0)
        BATTERY_FLOOR=\(batteryFloor)
        EXTRA_AGENTS="\(extraAgents.joined(separator: " "))"
        """
        if !agentsOverride.isEmpty {
            text += "\nAGENTS=\"\(agentsOverride.joined(separator: " "))\""
        }
        let dir = (kConfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: kConfigPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Detection & power state

    func detectAgents() -> [(name: String, count: Int)] {
        // Match on the executable basename from ps. (pgrep -l is unreliable
        // here: for Claude Code it prints the versioned binary name, e.g.
        // "2.1.226", even though the process name it matches is "claude".)
        let out = shell("/bin/ps", ["-axo", "comm="])
        let watched = Set(watchedAgents)
        var counts: [String: Int] = [:]
        for line in out.split(separator: "\n") {
            let comm = String(line).trimmingCharacters(in: .whitespaces)
            let base = (comm as NSString).lastPathComponent
            if watched.contains(base) { counts[base, default: 0] += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
    }

    func setAssertion(_ on: Bool) {
        if on && !assertionActive {
            let ok = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude Overtime: agentic CLI session running" as CFString,
                &assertionID)
            assertionActive = (ok == kIOReturnSuccess)
        } else if !on && assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionActive = false
        }
    }

    func sleepDisabledActive() -> Bool {
        let out = shell("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    // When the kernel last actually slept — the ground truth that lets users
    // verify a lid-closed session really kept running (the lock screen on
    // reopen looks identical to waking from sleep).
    func lastRealSleep() -> Date? {
        let out = shell("/usr/sbin/sysctl", ["-n", "kern.sleeptime"])
        guard let range = out.range(of: "sec = "),
              let sec = Int(out[range.upperBound...].prefix(while: { $0.isNumber })) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sec))
    }

    func helperInstalled() -> Bool {
        FileManager.default.fileExists(atPath: kHelperPath)
    }

    func helperRunning() -> Bool {
        !shell("/usr/bin/pgrep", ["-f", kHelperPath]).isEmpty
    }

    // Installed helper differs from the one bundled in this app → update needed.
    func helperOutdated() -> Bool {
        guard helperInstalled(),
              let res = Bundle.main.resourcePath,
              let bundled = FileManager.default.contents(atPath: "\(res)/claude-overtime-helper.sh"),
              let installed = FileManager.default.contents(atPath: kHelperPath) else { return false }
        return bundled != installed
    }

    func helperNeedsInstall() -> Bool {
        !helperInstalled() || helperOutdated()
    }

    // MARK: - Refresh

    func refresh() {
        runningAgents = detectAgents()
        setAssertion(keepAwake && !runningAgents.isEmpty)
        updateButton()
    }

    func updateButton() {
        guard let btn = statusItem.button else { return }
        let active = assertionActive || sleepDisabledActive()
        let iconName = active ? "menubar-active" : "menubar-idle"
        if let path = Bundle.main.path(forResource: iconName, ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 20, height: 20)
            btn.image = img
        } else {
            btn.image = NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                                accessibilityDescription: "Claude Overtime")
        }
        let total = runningAgents.reduce(0) { $0 + $1.count }
        btn.title = total > 0 ? " \(total)" : ""
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        // Status header
        let lidActive = sleepDisabledActive()
        let header: String
        if runningAgents.isEmpty {
            header = keepAwake ? "Idle — no agents running" : "Disabled"
        } else if lidActive {
            header = "Keeping Mac awake (lid-closed OK)"
        } else if assertionActive {
            header = "Keeping Mac awake"
        } else {
            header = "Agents running — sleep not blocked"
        }
        menu.addItem(disabledItem(header, bold: true))

        if runningAgents.isEmpty {
            menu.addItem(disabledItem("   No agent harnesses detected"))
        } else {
            for agent in runningAgents {
                let suffix = agent.count == 1 ? "session" : "sessions"
                menu.addItem(disabledItem("   \(agent.name) — \(agent.count) \(suffix)"))
            }
        }
        menu.addItem(.separator())

        // Settings
        let awakeItem = NSMenuItem(title: "Keep Awake While Agents Run",
                                   action: #selector(toggleKeepAwake), keyEquivalent: "")
        awakeItem.target = self
        awakeItem.state = keepAwake ? .on : .off
        menu.addItem(awakeItem)

        let lidItem = NSMenuItem(title: "Keep Running With Lid Closed",
                                 action: #selector(toggleLidClosed), keyEquivalent: "")
        lidItem.target = self
        lidItem.state = lidClosed ? .on : .off
        lidItem.isEnabled = keepAwake
        if !helperInstalled() {
            lidItem.toolTip = "Installs a small helper on first use (asks for your admin password)"
        }
        menu.addItem(lidItem)

        // Battery floor submenu
        let floorItem = NSMenuItem(title: "Battery Safety Floor", action: nil, keyEquivalent: "")
        let floorMenu = NSMenu()
        for value in [0, 5, 10, 15, 20] {
            let label = value == 0 ? "Off" : "Sleep below \(value)%"
            let item = NSMenuItem(title: label, action: #selector(setBatteryFloor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = batteryFloor == value ? .on : .off
            floorMenu.addItem(item)
        }
        floorItem.submenu = floorMenu
        menu.addItem(floorItem)
        menu.addItem(.separator())

        // Helper daemon status
        if !helperInstalled() {
            let installItem = NSMenuItem(title: "Install Lid-Closed Helper…",
                                         action: #selector(installHelper), keyEquivalent: "")
            installItem.target = self
            installItem.toolTip = "One-time install; asks for your admin password"
            menu.addItem(installItem)
        } else if helperOutdated() {
            let updateItem = NSMenuItem(title: "Update Lid-Closed Helper…",
                                        action: #selector(installHelper), keyEquivalent: "")
            updateItem.target = self
            updateItem.toolTip = "This app bundles a newer helper than the one installed"
            menu.addItem(updateItem)
        } else if !helperRunning() {
            menu.addItem(disabledItem("⚠︎ Helper installed but not running"))
        } else {
            menu.addItem(disabledItem("Helper daemon: running"))
        }

        if let slept = lastRealSleep() {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .full
            menu.addItem(disabledItem("Mac last truly slept: \(rel.localizedString(for: slept, relativeTo: Date()))"))
        }

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        logItem.isEnabled = FileManager.default.fileExists(atPath: kLogPath)
        menu.addItem(logItem)

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: kLaunchAgentPath) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Claude Overtime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    func disabledItem(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)])
        }
        return item
    }

    // MARK: - Actions

    @objc func toggleKeepAwake() {
        keepAwake.toggle()
        saveConfig()
        refresh()
    }

    @objc func toggleLidClosed() {
        lidClosed.toggle()
        saveConfig()
        if lidClosed && helperNeedsInstall() {
            installHelper()
        }
        refresh()
    }

    @objc func setBatteryFloor(_ sender: NSMenuItem) {
        batteryFloor = sender.tag
        saveConfig()
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: kLogPath))
    }

    var installInFlight = false

    @objc func installHelper() {
        // The helper files ship inside the app bundle; run the bundled
        // installer through the native macOS admin-password prompt.
        guard !installInFlight,
              let res = Bundle.main.resourcePath,
              FileManager.default.fileExists(atPath: "\(res)/install.sh") else { return }
        installInFlight = true
        let freshInstall = !helperInstalled()
        let cmd = "bash '\(res)/install.sh'"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            _ = shell("/usr/bin/osascript",
                      ["-e", "do shell script \"\(cmd)\" with administrator privileges"])
            DispatchQueue.main.async {
                self.installInFlight = false
                if freshInstall && !self.helperInstalled() {
                    // User cancelled the password prompt: lid-closed can't
                    // work, so turn the setting off rather than nag again.
                    // Re-enabling the toggle re-prompts.
                    self.lidClosed = false
                    self.saveConfig()
                }
                self.refresh()
            }
        }
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: kLaunchAgentPath) {
            try? fm.removeItem(atPath: kLaunchAgentPath)
        } else {
            let binary = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.claudeovertime.app</string>
                <key>ProgramArguments</key><array><string>\(binary)</string></array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            let dir = (kLaunchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: kLaunchAgentPath, atomically: true, encoding: .utf8)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
