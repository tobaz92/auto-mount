import AppKit
import NetFS
import ServiceManagement
import UserNotifications

// MARK: - Data Model

struct NASShare: Codable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var enabled: Bool = true

    var host: String {
        URL(string: url)?.host ?? ""
    }
    var shareName: String {
        let path = URL(string: url)?.path ?? ""
        let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return raw.replacingOccurrences(of: "..", with: "").replacingOccurrences(of: "/", with: "")
    }
    var mountPoint: String {
        shareName.isEmpty ? "" : "/Volumes/\(shareName)"
    }

    var isValid: Bool {
        guard let parsed = URL(string: url) else { return false }
        guard parsed.scheme?.lowercased() == "smb" else { return false }
        guard parsed.host != nil, !parsed.host!.isEmpty else { return false }
        guard !shareName.isEmpty else { return false }
        guard !url.contains("\n"), !url.contains("\r") else { return false }
        return true
    }
}

// MARK: - Config Manager

class ConfigManager {
    static let shared = ConfigManager()
    private init() {}
    private let sharesKey = "shares"
    private let intervalKey = "checkInterval"

    var shares: [NASShare] {
        get {
            guard let data = UserDefaults.standard.data(forKey: sharesKey),
                  let decoded = try? JSONDecoder().decode([NASShare].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: sharesKey)
            }
        }
    }

    /// Intervalle en minutes
    var checkIntervalMinutes: Double {
        get {
            let val = UserDefaults.standard.double(forKey: intervalKey)
            return val > 0 ? val : 30
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: intervalKey)
        }
    }
}

// MARK: - Mount Manager

class MountManager {
    static let shared = MountManager()
    private init() {}
    private let queue = DispatchQueue(label: "com.automount.app.mountmanager")
    private var previousStates: [UUID: Bool] = [:]

    func isMounted(_ share: NASShare) -> Bool {
        let mp = share.mountPoint
        guard !mp.isEmpty else { return false }
        let output = runProcess("/sbin/mount", captureOutput: true)
        let needle = " on \(mp) ("
        return output.components(separatedBy: "\n").contains { $0.contains(needle) }
    }

    /// macOS attend `-W` en millisecondes, contrairement à Linux.
    private let pingTimeoutMillis = "1500"

    func isReachable(_ share: NASShare) -> Bool {
        runProcess("/sbin/ping", args: ["-c1", "-W", pingTimeoutMillis, share.host]) != "error"
    }

    func isSMBOpen(_ share: NASShare) -> Bool {
        runProcess("/usr/bin/nc", args: ["-z", "-w2", share.host, "445"]) != "error"
    }

    /// `mount volume` d'AppleScript passe par NetAuthAgent en mode interactif : le
    /// moindre échec ouvre un dialogue Finder. NetFS en NoUI n'affiche jamais rien,
    /// y compris pour demander des identifiants absents du trousseau.
    @discardableResult
    func mount(_ share: NASShare) -> Int32 {
        guard let url = URL(string: share.url) else { return -1 }
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil,
                                       unsafeBitCast(openOptions, to: CFMutableDictionary.self),
                                       nil, &mountpoints)
        mountpoints?.release()
        if status != 0 {
            NSLog("AutoMount: montage de %@ refusé — code %d", share.name, status)
        }
        return status
    }

    func unmount(_ share: NASShare) {
        runProcess("/usr/sbin/diskutil", args: ["unmount", share.mountPoint])
    }

    func checkAndMount(_ share: NASShare) -> Bool {
        guard share.isValid else { return false }
        if isMounted(share) { return true }
        guard isReachable(share), isSMBOpen(share) else { return false }
        return mount(share) == 0 && isMounted(share)
    }

    func notifyIfChanged(share: NASShare, connected: Bool) {
        var previous: Bool?
        queue.sync {
            previous = previousStates[share.id]
            previousStates[share.id] = connected
        }
        if let prev = previous, prev != connected {
            let title = connected ? "\(share.name) connecté" : "\(share.name) déconnecté"
            let body = connected ? "Monté sur \(share.mountPoint)" : "Le partage n'est plus disponible"
            sendNotification(title: title, body: body, identifier: share.id.uuidString)
        }
    }

    func notifyUnreachable(_ share: NASShare) {
        sendNotification(title: "\(share.name) injoignable",
                         body: "\(share.host) ne répond pas — montage annulé",
                         identifier: share.id.uuidString)
    }

    func cleanupStates(activeIds: Set<UUID>) {
        queue.sync {
            previousStates = previousStates.filter { activeIds.contains($0.key) }
        }
    }

    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @discardableResult
    private func runProcess(_ path: String, args: [String] = [], captureOutput: Bool = false) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        let pipe: Pipe? = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("AutoMount: impossible de lancer %@ — %@", path, error.localizedDescription)
            return "error"
        }
        let data = pipe?.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if captureOutput, let data = data {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return process.terminationStatus == 0 ? "" : "error"
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var shares: [NASShare] = []
    private var shareStates: [UUID: Bool] = [:]

    private var urlField: NSTextField!
    private var nameField: NSTextField!
    private var enabledCheckbox: NSButton!
    private var intervalField: NSTextField!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var selectedIndex: Int = -1

    var onSave: (() -> Void)?

    private func reloadShares() {
        shares = ConfigManager.shared.shares
        let currentShares = shares
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var states: [UUID: Bool] = [:]
            for share in currentShares {
                states[share.id] = MountManager.shared.isMounted(share)
            }
            DispatchQueue.main.async {
                self?.shareStates = states
                self?.tableView?.reloadData()
            }
        }
    }

    func showWindow() {
        if window != nil {
            reloadShares()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        reloadShares()

        let W: CGFloat = 560
        let H: CGFloat = 380
        let pad: CGFloat = 20
        let innerW = W - pad * 2

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AutoMount"
        window.center()
        window.isReleasedWhenClosed = false

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        window.contentView = cv

        // ── Titre section ──
        let title = NSTextField(labelWithString: "Partages NAS")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: pad, y: H - 32, width: innerW, height: 20)
        cv.addSubview(title)

        // ── Table ──
        let tableH: CGFloat = 120
        let tableY: CGFloat = H - 38 - tableH
        let scrollView = NSScrollView(frame: NSRect(x: pad, y: tableY, width: innerW, height: tableH))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22

        for (id, colTitle, width) in [
            ("dot", "", 26), ("name", "Nom", 160), ("url", "URL SMB", 280), ("status", "Statut", 50)
        ] as [(String, String, CGFloat)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = colTitle
            col.width = width
            if id == "dot" { col.maxWidth = 26; col.minWidth = 26 }
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        cv.addSubview(scrollView)

        // ── Boutons +/- ──
        let btnY = tableY - 24
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Ajouter")!,
                             target: self, action: #selector(addShare))
        addButton.frame = NSRect(x: pad, y: btnY, width: 32, height: 22)
        addButton.bezelStyle = .smallSquare
        cv.addSubview(addButton)

        removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Supprimer")!,
                                target: self, action: #selector(removeShare))
        removeButton.frame = NSRect(x: pad + 32, y: btnY, width: 32, height: 22)
        removeButton.bezelStyle = .smallSquare
        cv.addSubview(removeButton)

        // ── Formulaire d'édition ──
        let boxH: CGFloat = 100
        let boxY = btnY - boxH - 8
        let editBox = NSBox(frame: NSRect(x: pad, y: boxY, width: innerW, height: boxH))
        editBox.title = "Partage sélectionné"
        editBox.titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        cv.addSubview(editBox)

        let bx: CGFloat = 8
        let bw = innerW - 24

        let urlLabel = NSTextField(labelWithString: "URL SMB")
        urlLabel.frame = NSRect(x: bx, y: 50, width: 55, height: 17)
        urlLabel.font = NSFont.systemFont(ofSize: 11)
        urlLabel.alignment = .right
        urlLabel.textColor = .secondaryLabelColor
        editBox.contentView?.addSubview(urlLabel)

        urlField = NSTextField(frame: NSRect(x: bx + 62, y: 48, width: bw - 62, height: 22))
        urlField.placeholderString = "smb://adresse-nas/partage"
        urlField.font = NSFont.systemFont(ofSize: 12)
        editBox.contentView?.addSubview(urlField)

        let nameLabel = NSTextField(labelWithString: "Nom")
        nameLabel.frame = NSRect(x: bx, y: 22, width: 55, height: 17)
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.alignment = .right
        nameLabel.textColor = .secondaryLabelColor
        editBox.contentView?.addSubview(nameLabel)

        nameField = NSTextField(frame: NSRect(x: bx + 62, y: 20, width: 170, height: 22))
        nameField.placeholderString = "Mon NAS"
        nameField.font = NSFont.systemFont(ofSize: 12)
        editBox.contentView?.addSubview(nameField)

        enabledCheckbox = NSButton(checkboxWithTitle: "Activé", target: nil, action: nil)
        enabledCheckbox.frame = NSRect(x: bx + 245, y: 21, width: 65, height: 20)
        enabledCheckbox.state = .on
        enabledCheckbox.font = NSFont.systemFont(ofSize: 11)
        editBox.contentView?.addSubview(enabledCheckbox)

        let applyButton = NSButton(title: "Appliquer", target: self, action: #selector(applyToSelected))
        applyButton.frame = NSRect(x: bw - 80, y: 18, width: 88, height: 26)
        applyButton.bezelStyle = .rounded
        editBox.contentView?.addSubview(applyButton)

        let hint = NSTextField(labelWithString: "Monté dans /Volumes/<partage>")
        hint.frame = NSRect(x: bx + 62, y: 2, width: 250, height: 14)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        editBox.contentView?.addSubview(hint)

        // ── Barre du bas ──
        let bottomY: CGFloat = 14

        let intervalLabel = NSTextField(labelWithString: "Vérifier toutes les")
        intervalLabel.frame = NSRect(x: pad, y: bottomY + 4, width: 115, height: 17)
        intervalLabel.font = NSFont.systemFont(ofSize: 12)
        cv.addSubview(intervalLabel)

        intervalField = NSTextField(frame: NSRect(x: pad + 118, y: bottomY + 1, width: 40, height: 22))
        intervalField.stringValue = String(Int(ConfigManager.shared.checkIntervalMinutes))
        intervalField.alignment = .center
        intervalField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cv.addSubview(intervalField)

        let minLabel = NSTextField(labelWithString: "min")
        minLabel.frame = NSRect(x: pad + 162, y: bottomY + 4, width: 30, height: 17)
        minLabel.font = NSFont.systemFont(ofSize: 12)
        cv.addSubview(minLabel)

        let saveButton = NSButton(title: "Sauvegarder", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: W - pad - 110, y: bottomY, width: 110, height: 28)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        cv.addSubview(saveButton)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Table Data Source

    func numberOfRows(in tableView: NSTableView) -> Int {
        shares.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shares.count else { return nil }
        let share = shares[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let mounted = shareStates[share.id] ?? false

        if id == "dot" {
            let imageView = NSImageView()
            let symbol = mounted ? "circle.fill" : "circle"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imageView.image = image
            imageView.contentTintColor = mounted ? .systemGreen : .tertiaryLabelColor
            return imageView
        }

        let text: String
        switch id {
        case "name": text = share.name + (share.enabled ? "" : " (off)")
        case "url": text = share.url
        case "status": text = mounted ? "OK" : "—"
        default: text = ""
        }

        let cellId = NSUserInterfaceItemIdentifier("cell_\(id)")
        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellId
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
        }
        cell.stringValue = text
        if id == "status" {
            cell.textColor = mounted ? .systemGreen : .tertiaryLabelColor
            cell.font = NSFont.systemFont(ofSize: 11, weight: mounted ? .medium : .regular)
        } else {
            cell.textColor = share.enabled ? .labelColor : .tertiaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < shares.count else {
            selectedIndex = -1
            return
        }
        selectedIndex = row
        let share = shares[row]
        urlField.stringValue = share.url
        nameField.stringValue = share.name
        enabledCheckbox.state = share.enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func addShare() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let enabled = enabledCheckbox.state == .on

        guard !url.isEmpty, !name.isEmpty else {
            showAlert("Champs requis", "Remplis l'URL SMB et le nom avant d'ajouter.")
            return
        }

        let newShare = NASShare(name: name, url: url, enabled: enabled)

        guard newShare.isValid else {
            showAlert("URL invalide", "L'URL doit commencer par smb:// et pointer vers un partage valide.")
            return
        }
        shares.append(newShare)
        tableView.reloadData()
        tableView.deselectAll(nil)

        urlField.stringValue = ""
        nameField.stringValue = ""
        enabledCheckbox.state = .on
        window.makeFirstResponder(urlField)
    }

    @objc private func removeShare() {
        let row = tableView.selectedRow
        guard row >= 0, row < shares.count else { return }
        shares.remove(at: row)
        tableView.reloadData()
        tableView.deselectAll(nil)
        urlField.stringValue = ""
        nameField.stringValue = ""
        enabledCheckbox.state = .on
    }

    @objc private func applyToSelected() {
        guard selectedIndex >= 0, selectedIndex < shares.count else { return }
        let testShare = NASShare(name: nameField.stringValue, url: urlField.stringValue)
        guard testShare.isValid else {
            showAlert("URL invalide", "L'URL doit commencer par smb:// et pointer vers un partage valide.")
            return
        }
        shares[selectedIndex].url = urlField.stringValue
        shares[selectedIndex].name = nameField.stringValue
        shares[selectedIndex].enabled = enabledCheckbox.state == .on
        tableView.reloadData()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func save() {
        if selectedIndex >= 0, selectedIndex < shares.count {
            applyToSelected()
        }
        ConfigManager.shared.shares = shares
        let minutes = max(1, Double(intervalField.stringValue) ?? 30)
        intervalField.stringValue = String(Int(minutes))
        ConfigManager.shared.checkIntervalMinutes = minutes
        onSave?()
        window.close()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var shareStates: [UUID: Bool] = [:]
    private var isChecking = false
    private var bootCheckCount = 0
    private let bootCheckMax = 5
    private let bootInterval: TimeInterval = 60
    private let settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()
        requestNotificationPermission()
        setupStatusItem()
        startTimer()
        checkAll()

        settingsController.onSave = { [weak self] in
            self?.restartTimer()
            self?.checkAll()
        }
    }

    // MARK: - Edit Menu (Cmd+C/V/X/A)

    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
    }

    private func updateIcon() {
        let anyConnected = shareStates.values.contains(true)
        let symbolName = anyConnected
            ? "externaldrive.fill.badge.checkmark"
            : "externaldrive.badge.xmark"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NAS")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()
        let shares = ConfigManager.shared.shares

        if shares.isEmpty {
            let empty = NSMenuItem(title: "Aucun partage configuré", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for share in shares {
                let connected = shareStates[share.id] ?? false
                let icon = connected ? "✔" : "✘"
                let status = connected ? "connecté" : "déconnecté"
                let title = "\(share.name) : \(status) \(icon)"

                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = true

                let submenu = NSMenu()
                if connected {
                    let unmountItem = NSMenuItem(title: "Démonter", action: #selector(unmountAction(_:)), keyEquivalent: "")
                    unmountItem.representedObject = share.id
                    unmountItem.target = self
                    submenu.addItem(unmountItem)

                    let openItem = NSMenuItem(title: "Ouvrir dans le Finder", action: #selector(openAction(_:)), keyEquivalent: "")
                    openItem.representedObject = share.mountPoint
                    openItem.target = self
                    submenu.addItem(openItem)
                } else {
                    let mountItem = NSMenuItem(title: "Monter", action: #selector(mountAction(_:)), keyEquivalent: "")
                    mountItem.representedObject = share.id
                    mountItem.target = self
                    submenu.addItem(mountItem)
                }

                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Réglages...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Lancer au démarrage", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Timer

    private func startTimer() {
        let interval: TimeInterval
        if bootCheckCount < bootCheckMax {
            interval = bootInterval
        } else {
            interval = ConfigManager.shared.checkIntervalMinutes * 60
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAll()
            self.bootCheckCount += 1
            if self.bootCheckCount >= self.bootCheckMax {
                self.restartTimer()
            }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        startTimer()
    }

    // MARK: - UI Refresh

    private func refreshUI() {
        updateIcon()
        buildMenu()
    }

    // MARK: - Core Logic

    private func checkAll() {
        guard !isChecking else { return }
        isChecking = true
        let shares = ConfigManager.shared.shares
        let activeIds = Set(shares.filter(\.enabled).map(\.id))
        MountManager.shared.cleanupStates(activeIds: activeIds)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var states: [UUID: Bool] = [:]
            for share in shares where share.enabled {
                let connected = MountManager.shared.checkAndMount(share)
                states[share.id] = connected
                MountManager.shared.notifyIfChanged(share: share, connected: connected)
            }
            DispatchQueue.main.async {
                self.shareStates = states
                self.isChecking = false
                self.refreshUI()
            }
        }
    }

    // MARK: - Menu Actions

    private func shareFromSender(_ sender: NSMenuItem) -> NASShare? {
        guard let shareId = sender.representedObject as? UUID else { return nil }
        return ConfigManager.shared.shares.first(where: { $0.id == shareId })
    }

    @objc private func mountAction(_ sender: NSMenuItem) {
        guard let share = shareFromSender(sender) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let manager = MountManager.shared
            // Sans ce filtre, NetFS bloque jusqu'à son timeout de 60 s sur un NAS
            // éteint, et l'UI d'authentification remonte un dialogue d'erreur.
            guard manager.isReachable(share), manager.isSMBOpen(share) else {
                manager.notifyUnreachable(share)
                DispatchQueue.main.async {
                    self?.shareStates[share.id] = false
                    self?.refreshUI()
                }
                return
            }
            manager.mount(share)
            let mounted = manager.isMounted(share)
            DispatchQueue.main.async {
                self?.shareStates[share.id] = mounted
                self?.refreshUI()
            }
        }
    }

    @objc private func unmountAction(_ sender: NSMenuItem) {
        guard let share = shareFromSender(sender) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            MountManager.shared.unmount(share)
            DispatchQueue.main.async {
                self?.shareStates[share.id] = false
                self?.refreshUI()
            }
        }
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    // MARK: - Login Items

    private func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {}
            sender.state = service.status == .enabled ? .on : .off
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
