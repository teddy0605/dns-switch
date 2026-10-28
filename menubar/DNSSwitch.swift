// Menu bar front end for dns-switch.sh. Built by build.sh into "DNS Switch.app".
import AppKit

let scriptPath = Bundle.main.object(forInfoDictionaryKey: "DNSSwitchScript") as? String ?? ""
// VPN_GATEWAYS from local/.env, copied into Info.plist by build.sh. The first one is the default.
let gateways = Bundle.main.object(forInfoDictionaryKey: "VPNGateways") as? [String] ?? []
let refreshInterval: TimeInterval = 5
// The watchdog re-activates after this many failed checks in a row. One extra
// tick gives vpn-hook.sh time to re-activate on its own after a VPN change.
let watchdogFailLimit = 2

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  let menu = NSMenu()
  let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  let activateItem = NSMenuItem(title: "Activate", action: #selector(activate), keyEquivalent: "a")
  let vpnItem = NSMenuItem(title: "Connect VPN…", action: #selector(toggleVPN), keyEquivalent: "v")
  var busy = false
  var vpn = false
  var checking = false
  var failedChecks = 0
  var autoFailAlerted = false
  // False after Deactivate, so the watchdog leaves DNS alone until the next Activate.
  var dnsWanted: Bool {
    get { UserDefaults.standard.bool(forKey: "dnsWanted") }
    set { UserDefaults.standard.set(newValue, forKey: "dnsWanted") }
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    UserDefaults.standard.register(defaults: ["dnsWanted": true])
    stateItem.isEnabled = false
    lastItem.isEnabled = false
    lastItem.isHidden = true
    menu.addItem(stateItem)
    menu.addItem(lastItem)
    menu.addItem(.separator())
    menu.addItem(vpnItem)
    menu.addItem(.separator())
    menu.addItem(activateItem)
    menu.addItem(NSMenuItem(title: "Deactivate", action: #selector(deactivate), keyEquivalent: "d"))
    menu.addItem(NSMenuItem(title: "Flush DNS Cache", action: #selector(flush), keyEquivalent: "f"))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Show Status…", action: #selector(status), keyEquivalent: "s"))
    menu.addItem(NSMenuItem(title: "Clean Up VPN Routes", action: #selector(cleanupRoutes), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    for i in menu.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
    menu.delegate = self
    item.menu = menu
    refresh()
    Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
      self?.refresh()
      self?.watchdog()
    }
  }

  func menuWillOpen(_ menu: NSMenu) { refresh() }

  func refresh() {
    let active = run("/usr/bin/pgrep", ["-x", "dnsmasq"]).status == 0
    vpn = run("/usr/bin/pgrep", ["-x", "openconnect"]).status == 0
    let symbol = busy ? "arrow.triangle.2.circlepath"
      : !active ? "network.slash" : vpn ? "network.badge.shield.half.filled" : "network"
    item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DNS Switch")
    stateItem.title = busy ? "Working…" : "dnsmasq \(active ? "active" : "inactive") · VPN \(vpn ? "on" : "off")"
    activateItem.title = active ? "Re-activate" : "Activate"
    vpnItem.title = vpn ? "Disconnect VPN" : "Connect VPN…"
  }

  // Re-activates when "dns-switch.sh check" fails watchdogFailLimit times in a row:
  // dnsmasq died, or the VPN or location changed under the live config.
  func watchdog() {
    guard dnsWanted, !busy, !checking else { return }
    checking = true
    DispatchQueue.global().async {
      let r = run(scriptPath, ["check"])
      DispatchQueue.main.async {
        self.checking = false
        self.failedChecks = r.status == 0 ? 0 : self.failedChecks + 1
        guard self.failedChecks >= watchdogFailLimit, self.dnsWanted else { return }
        self.failedChecks = 0
        self.perform("activate", auto: true)
      }
    }
  }

  @objc func activate() {
    dnsWanted = true
    perform("activate")
  }
  @objc func deactivate() {
    dnsWanted = false
    perform("deactivate")
  }
  @objc func toggleVPN() { vpn ? perform("vpn-disconnect") : askVPN() }
  @objc func flush() { perform("flush") }
  @objc func cleanupRoutes() { perform("cleanup-routes") }
  @objc func status() { perform("status", showOutput: true) }

  // Asks for gateway, password and 2FA code. Nothing is stored: the answers go
  // to openconnect on stdin and are dropped after this connect attempt.
  func askVPN() {
    let width: CGFloat = 260
    let gatewayPopup = NSPopUpButton(frame: NSRect(x: 0, y: 64, width: width, height: 26))
    gatewayPopup.addItems(withTitles: gateways)
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: width, height: 24))
    password.placeholderString = "Password"
    let code = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    code.placeholderString = "6-digit code"
    password.nextKeyView = code
    code.nextKeyView = gatewayPopup
    gatewayPopup.nextKeyView = password
    let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 92))
    [gatewayPopup, password, code].forEach(box.addSubview)

    let alert = NSAlert()
    alert.messageText = "Connect VPN"
    alert.accessoryView = box
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = password
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    connectVPN(gateway: gatewayPopup.titleOfSelectedItem ?? "",
               input: password.stringValue + "\n" + code.stringValue + "\n")
  }

  func connectVPN(gateway: String, input: String) {
    perform("vpn-connect", args: [gateway], input: input) { r in
      // Exit 2: "UNTRUSTED_CERT <host> <pin>" for a portal or gateway not trusted yet.
      let parts = r.output.split(separator: "\n").last?.split(separator: " ").map(String.init) ?? []
      guard r.status == 2, parts.count == 3 else { return false }
      let alert = NSAlert()
      alert.messageText = "Trust \(parts[1])?"
      alert.informativeText = "This host's certificate is not trusted yet:\n\(parts[2])\n\nTrust it and connect again?"
      alert.addButton(withTitle: "Trust and Connect")
      alert.addButton(withTitle: "Cancel")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return true }
      self.perform("vpn-trust", args: [parts[2]]) { t in
        if t.status == 0 { self.connectVPN(gateway: gateway, input: input) }
        return false
      }
      return true
    }
  }

  // `handled` gets the result first and returns true when it showed its own UI.
  func perform(_ cmd: String, args: [String] = [], input: String? = nil, showOutput: Bool = false,
               auto: Bool = false, handled: ((_ r: (status: Int32, output: String)) -> Bool)? = nil) {
    guard !busy else { return }
    busy = true
    refresh()
    DispatchQueue.global().async {
      let r = run("/usr/bin/sudo", ["-n", scriptPath, cmd] + args, input: input)
      DispatchQueue.main.async {
        self.busy = false
        self.refresh()
        let lines = r.output.split(separator: "\n").map(String.init)
        self.lastItem.title = "Last \(auto ? "auto " : "")\(cmd): \(r.status == 0 ? (lines.last ?? "ok") : "failed")"
        self.lastItem.isHidden = false
        if handled?(r) == true { return }
        // A failed auto activate alerts once per failure streak, since the watchdog keeps retrying.
        let repeatAutoFail = auto && self.autoFailAlerted
        if cmd == "activate" { self.autoFailAlerted = auto && r.status != 0 }
        if showOutput || (r.status != 0 && !repeatAutoFail) {
          let alert = NSAlert()
          alert.messageText = r.status == 0 ? "dns-switch \(cmd)"
            : auto ? "Auto activate failed (exit \(r.status)). DNS is not protected."
            : "dns-switch \(cmd) failed (exit \(r.status))"
          alert.informativeText = r.output.isEmpty ? "(no output)" : r.output
          NSApp.activate(ignoringOtherApps: true)
          alert.runModal()
        }
      }
    }
  }
}

func run(_ path: String, _ args: [String], input: String? = nil) -> (status: Int32, output: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = args
  // GUI apps get a minimal PATH. The script needs brew, dnsmasq, dig, etc.
  var env = ProcessInfo.processInfo.environment
  env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
  p.environment = env
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = pipe
  let stdin = Pipe()
  p.standardInput = stdin
  do { try p.run() } catch { return (-1, error.localizedDescription) }
  stdin.fileHandleForWriting.write(Data((input ?? "").utf8))
  try? stdin.fileHandleForWriting.close()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// A child that exits before reading stdin must not kill the app with SIGPIPE.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
