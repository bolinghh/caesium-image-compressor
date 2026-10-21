import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
private var nativeWindow: NativeWindowController?

@MainActor
@_cdecl("CaesiumShowNativeUI")
public func showNativeUI() {
  let preview = CommandLine.arguments.contains("--native-ui-preview")
  let store = preview ? MockBatch.make() : BatchStore()
  nativeWindow = NativeWindowController(store: store)
  nativeWindow?.showWindow(nil)
  NSApp.activate(ignoringOtherApps: true)
  if !preview {
    nativeWindow?.configureNotifications()
    store.session?.startPlatformServices()
    // Flags are parsed by the C++ entry point; positional file paths retain existing behavior.
    let paths = store.session?.launchPaths ?? []
    if !paths.isEmpty { store.importPaths(paths, fromArguments: true) }
  }
}

@MainActor
@_cdecl("CaesiumCloseNativeUI")
public func closeNativeUI() {
  nativeWindow?.shutdown()
  nativeWindow = nil
}

@MainActor
final class NativeWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
  UNUserNotificationCenterDelegate
{
  let store: BatchStore
  private var settingsWindow: NSWindow?
  private var stateSubscription: AnyCancellable?
  private var statusItem: NSStatusItem?
  private var allowingClose = false
  private var confirmingClose = false
  private var menuLocale = ""
  private var notificationsReady = false

  init(store: BatchStore) {
    self.store = store
    let controller = NSHostingController(rootView: BatchView(store: store))
    let window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = "Caesium Image Compressor"
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 1120, height: 780))
    window.minSize = NSSize(width: 600, height: 480)
    if store.session != nil { window.setFrameAutosaveName("CaesiumNativeWorkbench") }
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.image = NSImage(
      systemSymbolName: "photo", accessibilityDescription: "Caesium Image Compressor")
    if store.session == nil || !window.setFrameUsingName("CaesiumNativeWorkbench") {
      window.center()
    }
    installMenus()
    store.onQuitRequested = { [weak self] in self?.requestClose() }
    store.onCloseReady = { [weak self] in self?.finishClose() }
    store.onBatchCompleted = { [weak self] title, detail in
      self?.notify(title: title, detail: detail)
    }
    stateSubscription = store.$settings.sink { [weak self] values in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let variant = (values["preferences/general/theme_variant"] as? NSNumber)?.intValue ?? 0
        let appearance: NSAppearance? =
          variant == 1
          ? NSAppearance(named: .aqua) : variant == 2 ? NSAppearance(named: .darkAqua) : nil
        self.window?.appearance = appearance
        self.settingsWindow?.appearance = appearance
        self.window?.toolbar?.isVisible =
          (values["mainwindow/toolbar/visible"] as? NSNumber)?.boolValue ?? true
        self.window?.toolbar?.displayMode =
          (values["mainwindow/toolbar/button_style"] as? NSNumber)?.intValue == 0
          ? .iconOnly : .iconAndLabel
        if self.menuLocale != (values["preferences/language/locale"] as? String ?? "") {
          self.installMenus()
        }
      }
    }
  }
  required init?(coder: NSCoder) { fatalError("Use init(store:)") }

  func shutdown() {
    // Release SwiftUI/adapter ownership before the C++ QApplication is destroyed.
    allowingClose = true
    store.session?.onChange = nil
    store.session?.onNotice = nil
    store.session?.onCloseReady = nil
    store.session?.onQuitRequested = nil
    stateSubscription = nil
    if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
    settingsWindow?.contentViewController = nil
    settingsWindow?.close()
    settingsWindow = nil
    window?.contentViewController = nil
    window?.close()
  }

  func configureNotifications() {
    notificationsReady = Bundle.main.bundleIdentifier != nil
    if notificationsReady { UNUserNotificationCenter.current().delegate = self }
  }
  private func notify(title: String, detail: String) {
    guard notificationsReady else { return }
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard
        settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
      else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = detail
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      self?.showMain()
      completionHandler()
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowingClose { return true }
    requestClose()
    return false
  }
  private func requestClose() {
    guard !store.closing, !confirmingClose else { return }
    if store.flag("preferences/general/prompt_before_exit") {
      confirmingClose = true
      let alert = NSAlert()
      alert.messageText = store.t("Do you really want to quit?")
      alert.addButton(withTitle: store.t("Cancel"))
      alert.addButton(withTitle: store.t("Yes"))
      let response = alert.runModal()
      confirmingClose = false
      guard response == .alertSecondButtonReturn else { return }
    }
    store.closing = true
    if let session = store.session { _ = session.requestClose() } else { finishClose() }
  }
  private func finishClose() {
    allowingClose = true
    window?.close()
    // The bridge has drained all workers; let Qt perform the application's normal shutdown.
    NotificationCenter.default.post(name: Notification.Name("CaesiumNativeCloseReady"), object: nil)
  }

  @objc func addFiles() { store.chooseFiles() }
  @objc func addFolder() { store.chooseFiles(folder: true) }
  @objc func advancedImport() { store.showAdvancedImport = true }
  @objc func compress() { store.compress() }
  @objc func retry() { store.compress(failedOnly: true) }
  @objc func removeItems() {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
      editor.deleteBackward(nil)
    } else {
      store.remove()
    }
  }
  @objc func clearItems() { store.remove(all: true) }
  @objc func selectAllImages() {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
      editor.selectAll(nil)
    } else {
      store.selection = Set(store.items.map(\.id))
    }
  }
  @objc func preview() { store.requestPreview(force: true) }
  @objc func showPreviews() {
    store.set("mainwindow/previews_visible", !store.flag("mainwindow/previews_visible", true))
  }
  @objc func autoPreview() {
    store.set("mainwindow/auto_preview", !store.flag("mainwindow/auto_preview"))
    store.requestPreview()
  }
  @objc func toggleInspector() {
    store.set("macos/inspector_visible", !store.flag("macos/inspector_visible", true))
  }
  @objc func originalInFinder() { store.reveal(output: false) }
  @objc func outputInFinder() { store.reveal(output: true) }
  @objc func about() { store.showAbout = true }
  @objc func quit() { requestClose() }
  @objc func closeMain() { window?.performClose(nil) }
  @objc func showMain() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
  @objc func toolbarIcons() {
    store.set("mainwindow/toolbar/visible", true)
    store.set("mainwindow/toolbar/button_style", 0)
  }
  @objc func toolbarLabels() {
    store.set("mainwindow/toolbar/visible", true)
    store.set("mainwindow/toolbar/button_style", 3)
  }
  @objc func toolbarHidden() { store.set("mainwindow/toolbar/visible", false) }
  @objc func donate() {
    NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/Lymphatus")!)
  }
  @objc func checkUpdates() { store.session?.checkForUpdates() }
  @objc func preferences() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentViewController: NSHostingController(rootView: SettingsView(store: store)))
      window.styleMask = [.titled, .closable]
      window.title = store.t("Preferences...")
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let idle = !store.busy && !store.closing
    switch item.action {
    case #selector(compress): return store.canCompress
    case #selector(retry): return store.canCompress && store.items.contains { $0.status == 3 }
    case #selector(removeItems):
      return NSApp.keyWindow?.firstResponder is NSTextView || (idle && !store.selection.isEmpty)
    case #selector(clearItems): return idle && !store.items.isEmpty
    case #selector(preview): return idle && !store.selection.isEmpty
    case #selector(originalInFinder): return store.selectedImage != nil
    case #selector(outputInFinder): return store.selectedImage?.output.isEmpty == false
    case #selector(showPreviews):
      item.state = store.flag("mainwindow/previews_visible", true) ? .on : .off
      return true
    case #selector(autoPreview):
      item.state = store.flag("mainwindow/auto_preview") ? .on : .off
      return idle
    case #selector(toggleInspector):
      item.state = store.flag("macos/inspector_visible", true) ? .on : .off
      return true
    case #selector(addFiles), #selector(addFolder), #selector(advancedImport),
      #selector(preferences):
      return idle
    case #selector(checkUpdates): return store.session?.updaterAvailable == true
    default: return true
    }
  }
  private func installMenus() {
    menuLocale = store.string("preferences/language/locale")
    let bar = NSMenu()
    func menu(_ title: String) -> NSMenu {
      let entry = NSMenuItem(title: store.t(title), action: nil, keyEquivalent: "")
      let submenu = NSMenu(title: store.t(title))
      entry.submenu = submenu
      bar.addItem(entry)
      return submenu
    }
    func item(
      _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: store.t(title), action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target ?? self
      menu.addItem(item)
    }
    let app = menu("Caesium Image Compressor")
    item(app, "About Caesium Image Compressor", #selector(about))
    item(app, "Check for updates", #selector(checkUpdates))
    app.addItem(.separator())
    item(app, "Preferences...", #selector(preferences), ",")
    let services = NSMenu(title: "Services")
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    app.addItem(servicesItem)
    NSApp.servicesMenu = services
    app.addItem(.separator())
    item(
      app, "Hide Caesium Image Compressor", #selector(NSApplication.hide(_:)), "h", target: NSApp)
    item(
      app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
      [.command, .option], target: NSApp)
    item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
    app.addItem(.separator())
    item(app, "Quit Caesium Image Compressor", #selector(quit), "q")
    let file = menu("File")
    item(file, "Add files...", #selector(addFiles), "o")
    item(file, "Add folder...", #selector(addFolder), "o", [.command, .shift])
    item(file, "Advanced import...", #selector(advancedImport))
    file.addItem(.separator())
    item(file, "Compress", #selector(compress))
    item(file, "Recompress failed", #selector(retry))
    file.addItem(.separator())
    item(file, "Show original in file manager", #selector(originalInFinder))
    item(file, "Show compressed in file manager", #selector(outputInFinder))
    file.addItem(.separator())
    item(file, "Close", #selector(closeMain), "w")
    let edit = menu("Edit")
    // Nil targets preserve the responder chain for text fields, including Select All and Delete.
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
    ] {
      let entry = NSMenuItem(title: store.t(title), action: action, keyEquivalent: key)
      edit.addItem(entry)
    }
    item(edit, "Select All", #selector(selectAllImages), "a")
    item(edit, "Remove", #selector(removeItems), "\u{8}", [])
    item(edit, "Clear", #selector(clearItems))
    let view = menu("View")
    item(view, "Preview", #selector(preview), "p")
    item(view, "Show previews", #selector(showPreviews))
    item(view, "Auto preview", #selector(autoPreview))
    item(view, "Parameters", #selector(toggleInspector), "i", [.command, .option])
    view.addItem(.separator())
    item(view, "Icons", #selector(toolbarIcons))
    item(view, "Icons and Text", #selector(toolbarLabels))
    item(view, "Hide toolbar", #selector(toolbarHidden))
    let windows = menu("Window")
    item(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: window)
    item(windows, "Show", #selector(showMain))
    NSApp.windowsMenu = windows
    let help = menu("Help")
    item(help, "Donate", #selector(donate))
    NSApp.helpMenu = help
    NSApp.mainMenu = bar
    let statusMenu = NSMenu()
    item(statusMenu, "Show", #selector(showMain))
    statusMenu.addItem(.separator())
    item(statusMenu, "Exit", #selector(quit))
    statusItem?.menu = statusMenu
  }
}
