// NetToggle: list the apps in /Applications and toggle their network access.
//
// Turning an app's network off swaps it in place: /Applications/X.app is renamed to X.app.bak
// (no longer an app to macOS, so it drops out of Spotlight and Open With), and a launcher takes
// its name, bundle ID, document types and icon. The launcher starts the original's program under
// sandbox-exec with all IP traffic denied, so Finder, the Dock, Launchpad, Spotlight and
// double-clicked documents all get the blocked version. Turning network on reverses the swap.
// Apps that use Apple's App Sandbox are killed by sandbox-exec and are shown disabled.

import SwiftUI
import AppKit
import Security

let sandboxProfile = #"(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(deny network-bind (local ip "*:*"))"#
let markerKey = "NetToggleOriginal"
let originalSuffix = ".bak"   // X.app → X.app.bak: not an app to macOS, so out of Spotlight and Open With
let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

enum NetState {
    case allowed         // X.app is the real app
    case blocked         // X.app is our launcher, X.app.bak the original
    case orphanOriginal  // only X.app.bak exists: turning network on restores it
    case staleOriginal   // X.app is a real app and an old X.app.bak is left over (app updated while blocked?)
    case brokenLauncher  // X.app is our launcher but X.app.bak is gone
}

struct AppEntry: Identifiable {
    let id: URL                  // /…/X.app, the path Finder and the Dock use
    let name: String
    let bundleID: String?
    let executable: String?      // CFBundleExecutable of the real app
    let sandboxed: Bool
    let icon: NSImage
    let state: NetState
    var originalURL: URL { URL(fileURLWithPath: id.path + originalSuffix) }
    var realBundle: URL { state == .blocked || state == .orphanOriginal ? originalURL : id }
}

struct ToolError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Scanning

func infoPlist(_ bundle: URL) -> [String: Any]? {
    NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
}

func isLauncher(_ bundle: URL) -> Bool { infoPlist(bundle)?[markerKey] != nil }

func scanApplications() -> [AppEntry] {
    let fm = FileManager.default
    var paths = Set<String>()   // canonical /…/X.app paths
    func scan(_ dir: URL, depth: Int) {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for url in items {
            if url.pathExtension == "app" {
                paths.insert(url.path)
            } else if url.path.hasSuffix(".app" + originalSuffix) {
                paths.insert(String(url.path.dropLast(originalSuffix.count)))
            } else if depth < 1, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                scan(url, depth: depth + 1)   // e.g. /Applications/Utilities, vendor folders
            }
        }
    }
    scan(URL(fileURLWithPath: "/Applications"), depth: 0)
    return paths.map { entry(for: URL(fileURLWithPath: $0)) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func entry(for app: URL) -> AppEntry {
    let fm = FileManager.default
    let original = URL(fileURLWithPath: app.path + originalSuffix)
    let appExists = fm.fileExists(atPath: app.path), originalExists = fm.fileExists(atPath: original.path)
    let launcher = appExists && isLauncher(app)
    let state: NetState
    switch (appExists, originalExists) {
    case (true, true):  state = launcher ? .blocked : .staleOriginal
    case (true, false): state = launcher ? .brokenLauncher : .allowed
    default:            state = .orphanOriginal
    }
    let real = (state == .blocked || state == .orphanOriginal) ? original : app
    let info = infoPlist(real)
    return AppEntry(
        id: app,
        name: app.deletingPathExtension().lastPathComponent,
        bundleID: info?["CFBundleIdentifier"] as? String,
        executable: info?["CFBundleExecutable"] as? String,
        sandboxed: isAppSandboxed(real),
        icon: NSWorkspace.shared.icon(forFile: appExists ? app.path : original.path),
        state: state
    )
}

func isAppSandboxed(_ url: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
    return (entitlements["com.apple.security.app-sandbox"] as? Bool) == true
}

// MARK: - Launcher

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

/// Builds the launcher for `app` in a temporary folder, copying the original's Info.plist and icon.
func buildLauncher(for app: AppEntry) throws -> URL {
    guard var plist = infoPlist(app.id), let exe = app.executable else { throw ToolError("Can't read \(app.name)'s Info.plist.") }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("NetToggle-\(UUID().uuidString)")
    let launcher = tmp.appendingPathComponent(app.id.lastPathComponent)
    let contents = launcher.appendingPathComponent("Contents")
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

    plist["CFBundleExecutable"] = "launcher"
    plist[markerKey] = app.originalURL.path
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))

    let target = app.originalURL.appendingPathComponent("Contents/MacOS/\(exe)").path
    let script = "#!/bin/sh\nexec /usr/bin/sandbox-exec -p \(shellQuote(sandboxProfile)) \(shellQuote(target)) \"$@\"\n"
    let scriptURL = contents.appendingPathComponent("MacOS/launcher")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    // Icon: the .icns named by CFBundleIconFile, and Assets.car for apps that use CFBundleIconName.
    let resources = app.id.appendingPathComponent("Contents/Resources")
    var iconFiles: [String] = []
    if let file = plist["CFBundleIconFile"] as? String { iconFiles.append(file.hasSuffix(".icns") ? file : file + ".icns") }
    if plist["CFBundleIconName"] != nil { iconFiles.append("Assets.car") }
    for file in iconFiles where fm.fileExists(atPath: resources.appendingPathComponent(file).path) {
        try? fm.copyItem(at: resources.appendingPathComponent(file), to: contents.appendingPathComponent("Resources/\(file)"))
    }
    return launcher
}

// MARK: - Swapping

/// $1 = X.app, $2 = X.app.bak, $3 = new launcher. Rolls back if the launcher can't be put in place.
let blockScript = """
set -e
[ ! -e "$2" ] || { echo "$2 already exists" >&2; exit 1; }
mv "$1" "$2"
if ! mv "$3" "$1"; then mv "$2" "$1"; exit 1; fi
chown -R "$4" "$1" 2>/dev/null || true
"""

/// $1 = X.app, $2 = X.app.bak. Only removes X.app if it is a NetToggle launcher; rolls back on failure.
let unblockScript = """
T=""
if [ -e "$1" ]; then
  /usr/libexec/PlistBuddy -c 'Print :\(markerKey)' "$1/Contents/Info.plist" >/dev/null 2>&1 || { echo "$1 is not a NetToggle launcher" >&2; exit 1; }
  T=$(mktemp -d) && mv "$1" "$T/launcher.app" || exit 1
fi
if mv "$2" "$1"; then
  [ -z "$T" ] || rm -rf "$T"
else
  [ -z "$T" ] || mv "$T/launcher.app" "$1"
  exit 1
fi
"""

/// Runs a script as the user; if that fails for lack of permission, again with the admin password.
func runSwap(_ script: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "sh"] + args
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard message.contains("Permission denied") || message.contains("Operation not permitted") else {
        throw ToolError(message.isEmpty ? "The swap failed." : message)
    }

    let command = (["/bin/sh", "-c", script, "sh"] + args).map(shellQuote).joined(separator: " ")
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
    if let error {
        let text = error[NSAppleScript.errorMessage] as? String ?? "The swap failed."
        throw ToolError(text + (text.contains("not permitted")
            ? "\n\nAllow NetToggle in System Settings → Privacy & Security → App Management, then try again." : ""))
    }
}

func block(_ app: AppEntry) throws {
    let launcher = try buildLauncher(for: app)
    defer { try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent()) }
    try runSwap(blockScript, [app.id.path, app.originalURL.path, launcher.path, NSUserName()])
    if !FileManager.default.fileExists(atPath: app.id.appendingPathComponent("Contents/Resources/Assets.car").path),
       infoPlist(app.id)?["CFBundleIconFile"] == nil {
        NSWorkspace.shared.setIcon(app.icon, forFile: app.id.path, options: [])   // no icon file to copy
    }
    LSRegisterURL(app.id as CFURL, true)
    unregister(app.originalURL)
}

func unblock(_ app: AppEntry) throws {
    try runSwap(unblockScript, [app.id.path, app.originalURL.path])
    LSRegisterURL(app.id as CFURL, true)
}

func unregister(_ url: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: lsregister)
    p.arguments = ["-u", url.path]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Model

struct PendingSwitch: Identifiable {
    let app: AppEntry
    let networkOn: Bool
    var id: URL { app.id }
}

final class Model: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var query = ""
    @Published var loading = true
    @Published var errorMessage: String?
    @Published var pending: PendingSwitch?

    var filtered: [AppEntry] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var restorable: [AppEntry] { apps.filter { $0.state == .blocked || $0.state == .orphanOriginal } }

    func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = scanApplications()
            DispatchQueue.main.async { self.apps = list; self.loading = false }
        }
    }

    func refresh(_ app: AppEntry) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i] = entry(for: app.id) }
    }

    func running(_ app: AppEntry) -> NSRunningApplication? {
        guard let id = app.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// The app must be quit before its bundle is renamed, so a running app goes through the Quit prompt.
    func setNetwork(_ on: Bool, for app: AppEntry) {
        if running(app) != nil { pending = PendingSwitch(app: app, networkOn: on); return }
        perform(on, app)
    }

    func perform(_ on: Bool, _ app: AppEntry, relaunch: Bool = false) {
        do {
            if on { try unblock(app) } else { try block(app) }
            if relaunch { open(app) }
        } catch {
            errorMessage = "\(app.name): \(error.localizedDescription)"
        }
        refresh(app)
    }

    func quitThenPerform(_ p: PendingSwitch) {
        guard let instance = running(p.app) else { perform(p.networkOn, p.app); return }
        instance.terminate()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(15)
            while !instance.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            DispatchQueue.main.async {
                if instance.isTerminated { self.perform(p.networkOn, p.app, relaunch: true) }
                else { self.errorMessage = "\(p.app.name) didn't quit (unsaved work?). Quit it, then toggle again." }
            }
        }
    }

    func restoreAll() {
        let busy = restorable.filter { running($0) != nil }.map(\.name)
        guard busy.isEmpty else { errorMessage = "Quit these apps first: \(busy.joined(separator: ", "))"; return }
        for app in restorable { perform(true, app) }
    }

    func open(_ app: AppEntry) {
        NSWorkspace.shared.openApplication(at: app.id, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Reading /Applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.filtered) { app in row(app) }
            }
            Divider()
            Text("Blocking renames the app to “<App>.app.bak” and puts an offline launcher in its place, so every way of opening it is blocked. Turn network on before updating an app; quit an app before switching it.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .searchable(text: $model.query, placement: .toolbar)
        .toolbar {
            Button { model.load() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            Button("Restore All") { model.restoreAll() }
                .disabled(model.restorable.isEmpty)
                .help("Turn network back on for every blocked app")
        }
        .onAppear { model.load() }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
        .alert(item: $model.pending) { p in
            Alert(
                title: Text("Quit \(p.app.name)?"),
                message: Text("\(p.app.name) has to be closed while it is switched \(p.networkOn ? "back to the original" : "to the offline launcher"). It will reopen afterwards."),
                primaryButton: .default(Text("Quit & Switch")) { model.quitThenPerform(p) },
                secondaryButton: .cancel()
            )
        }
    }

    private func note(_ app: AppEntry) -> (String, Color)? {
        if app.sandboxed { return ("Uses Apple's App Sandbox; can't be blocked this way", .secondary) }
        switch app.state {
        case .allowed:        return nil
        case .blocked:        return ("Network blocked", .orange)
        case .orphanOriginal:   return ("Only \(app.originalURL.lastPathComponent) is left; turn network on to restore it", .orange)
        case .staleOriginal:    return ("\(app.originalURL.lastPathComponent) is left over, probably from an update while blocked. Delete it to block again", .red)
        case .brokenLauncher: return ("Offline launcher with no original; reinstall the app", .red)
        }
    }

    @ViewBuilder
    private func row(_ app: AppEntry) -> some View {
        let networkOn = app.state == .allowed || app.state == .staleOriginal
        HStack(spacing: 10) {
            Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                if let (text, color) = note(app) { Text(text).font(.caption).foregroundStyle(color) }
            }
            Spacer()
            if app.state == .staleOriginal {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([app.originalURL]) }
            }
            Toggle("Network", isOn: Binding(get: { networkOn }, set: { model.setNetwork($0, for: app) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(app.sandboxed || app.executable == nil || app.state == .staleOriginal || app.state == .brokenLauncher)
        }
        .padding(.vertical, 2)
    }
}

@main
struct NetToggleApp: App {
    var body: some Scene {
        WindowGroup("NetToggle") {
            ContentView().frame(minWidth: 560, minHeight: 480)
        }
    }
}
