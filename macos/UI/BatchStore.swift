import AppKit
import Combine
import SwiftUI
import UserNotifications

struct BatchImage: Identifiable {
  let id: String
  let name: String
  let path: String
  let output: String
  let bytes: Int64
  let outputBytes: Int64
  let resolution: String
  let saved: Double
  let status: Int
  let detail: String

  init(_ values: [String: Any]) {
    id = values["id"] as? String ?? ""
    name = values["name"] as? String ?? ""
    path = values["path"] as? String ?? ""
    output = values["output"] as? String ?? ""
    bytes = (values["bytes"] as? NSNumber)?.int64Value ?? 0
    outputBytes = (values["outputBytes"] as? NSNumber)?.int64Value ?? 0
    resolution = values["resolution"] as? String ?? ""
    saved = (values["saved"] as? NSNumber)?.doubleValue ?? 0
    status = (values["status"] as? NSNumber)?.intValue ?? 0
    detail = values["detail"] as? String ?? ""
  }

  var sizeText: String {
    ByteCountFormatter.string(
      fromByteCount: status == 2 || status == 4 ? outputBytes : bytes, countStyle: .binary)
  }
  var symbol: String {
    [
      "photo", "arrow.triangle.2.circlepath", "checkmark.circle", "exclamationmark.circle",
      "exclamationmark.triangle", "forward.end",
    ][min(5, max(0, status))]
  }
}

struct Notice: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
}

// This is the sole Swift owner of a bridge session; Views never touch C++ objects.
@MainActor
final class BatchStore: ObservableObject {
  let session: CSNativeSession?
  @Published var items: [BatchImage] = []
  @Published var settings: [String: Any] = [:]
  @Published var selection = Set<String>()
  @Published var sortOrder = [KeyPathComparator(\BatchImage.name)]
  @Published var busy = false
  @Published var phase = "idle"
  @Published var closing = false
  @Published var completed = 0
  @Published var total = 0
  @Published var previewLoading = false
  @Published var previewGenerated = false
  @Published var previewError = ""
  @Published var previewOriginalBytes: Int64 = 0
  @Published var previewCompressedBytes: Int64 = 0
  @Published var previewOriginalFormat = ""
  @Published var previewCompressedFormat = ""
  @Published var original: NSImage?
  @Published var compressed: NSImage?
  @Published var notice: Notice?
  @Published var summary = ""
  @Published var showSettings = false
  @Published var showAdvancedImport = false
  @Published var showUsage = false
  @Published var showAbout = false
  var onCloseReady: (() -> Void)?
  var onQuitRequested: (() -> Void)?
  var onBatchCompleted: ((String, String) -> Void)?

  init(session: CSNativeSession? = CSNativeSession()) {
    self.session = session
    settings = session?.settings ?? [:]
    let order: SortOrder =
      number("mainwindow/list_view/sort_column_order") == 0 ? .forward : .reverse
    switch number("mainwindow/list_view/sort_column_index") {
    case 1: sortOrder = [KeyPathComparator(\BatchImage.outputBytes, order: order)]
    case 2: sortOrder = [KeyPathComparator(\BatchImage.resolution, order: order)]
    case 3: sortOrder = [KeyPathComparator(\BatchImage.saved, order: order)]
    case 4: sortOrder = [KeyPathComparator(\BatchImage.detail, order: order)]
    default: sortOrder = [KeyPathComparator(\BatchImage.name, order: order)]
    }
    session?.onChange = { [weak self] snapshot in
      // Bridge contract is main-thread-only; defer to avoid publishing during AppKit updates.
      DispatchQueue.main.async { self?.consume(snapshot) }
    }
    session?.onNotice = { [weak self] title, detail in
      DispatchQueue.main.async { self?.notice = Notice(title: title, detail: detail) }
    }
    session?.onCloseReady = { [weak self] in DispatchQueue.main.async { self?.onCloseReady?() } }
    session?.onQuitRequested = { [weak self] in
      DispatchQueue.main.async { self?.onQuitRequested?() }
    }
    if let snapshot = session?.snapshot { consume(snapshot) }
  }

  func consume(_ snapshot: [String: Any]) {
    if snapshot["requestCompression"] as? Bool == true {
      if let current = session?.snapshot { consume(current) }
      compress()
      return
    }
    if snapshot["batchFinished"] as? Bool == true {
      onBatchCompleted?(
        snapshot["summaryTitle"] as? String ?? "", snapshot["summaryDetail"] as? String ?? "")
      summary =
        "\(snapshot["summaryTitle"] as? String ?? "") · \(snapshot["summaryDetail"] as? String ?? "")"
      return
    }
    items = (snapshot["items"] as? [[String: Any]] ?? []).map(BatchImage.init)
    selection.formIntersection(Set(items.map(\.id)))
    let wasBusy = busy
    busy = snapshot["busy"] as? Bool ?? false
    closing = snapshot["closing"] as? Bool ?? false
    phase = snapshot["phase"] as? String ?? "idle"
    completed = snapshot["completed"] as? Int ?? 0
    total = snapshot["total"] as? Int ?? 0
    previewLoading = snapshot["previewLoading"] as? Bool ?? false
    previewGenerated = snapshot["previewGenerated"] as? Bool ?? false
    previewError = snapshot["previewError"] as? String ?? ""
    previewOriginalBytes = (snapshot["previewOriginalBytes"] as? NSNumber)?.int64Value ?? 0
    previewCompressedBytes = (snapshot["previewCompressedBytes"] as? NSNumber)?.int64Value ?? 0
    previewOriginalFormat = snapshot["previewOriginalFormat"] as? String ?? ""
    previewCompressedFormat = snapshot["previewCompressedFormat"] as? String ?? ""
    original = session?.originalPreview
    compressed = session?.compressedPreview
    if wasBusy && !busy && !closing { requestPreview() }
  }

  func t(_ text: String, _ context: String = "MainWindow") -> String {
    session?.translate(text, context: context) ?? text
  }
  func number(_ key: String, _ fallback: Int = 0) -> Int {
    (settings[key] as? NSNumber)?.intValue ?? fallback
  }
  func flag(_ key: String, _ fallback: Bool = false) -> Bool {
    (settings[key] as? NSNumber)?.boolValue ?? fallback
  }
  func string(_ key: String, _ fallback: String = "") -> String {
    settings[key] as? String ?? fallback
  }

  func set(_ key: String, _ value: Any) {
    guard !closing, !busy || key.hasPrefix("mainwindow/") || key.hasPrefix("macos/") else { return }
    settings[key] = value
    session?.setSetting(key, value: value)
    let output = "compression_options/output/"
    let dates = ["keep_creation_date", "keep_last_modified_date", "keep_last_access_date"]
    if key == output + "keep_dates" {
      for date in dates {
        settings[output + date] = number(key) != 0
        session?.setSetting(output + date, value: number(key) != 0)
      }
    } else if dates.contains(where: { key == output + $0 }) {
      let count = dates.filter { flag(output + $0) }.count
      settings[output + "keep_dates"] = count == 0 ? 0 : count == 3 ? 2 : 1
      session?.setSetting(output + "keep_dates", value: number(output + "keep_dates"))
    }
    let compression = "compression_options/compression/"
    if key == compression + "max_output_size_unit" || key == compression + "max_output_size",
      number(compression + "max_output_size_unit") == 3,
      number(compression + "max_output_size") > 100
    {
      settings[compression + "max_output_size"] = 100
      session?.setSetting(compression + "max_output_size", value: 100)
    }
    // The old UI links percentage dimensions only; fixed pixel dimensions remain independent.
    let resize = "compression_options/resize/"
    if key.hasPrefix(resize) {
      if number(resize + "fit_to") == 2 {
        let maxValue = flag(resize + "do_not_enlarge") ? 100 : 999
        for dimension in ["width", "height"] {
          let name = resize + dimension
          let clamped = min(maxValue, max(1, number(name, 100)))
          settings[name] = clamped
          session?.setSetting(name, value: clamped)
        }
        if flag(resize + "keep_aspect_ratio") {
          let from = key == resize + "height" ? "height" : "width"
          let to = from == "height" ? "width" : "height"
          settings[resize + to] = number(resize + from)
          session?.setSetting(resize + to, value: number(resize + from))
        }
      }
    }
    if key == "compression_options/output/format_id", !supportsLossless {
      settings["compression_options/compression/lossless"] = false
      session?.setSetting("compression_options/compression/lossless", value: false)
    }
    if key.hasPrefix("compression_options/") { requestPreview() }
    if key == "mainwindow/previews_visible" { requestPreview() }
  }

  func boolBinding(_ key: String) -> Binding<Bool> {
    Binding(get: { self.flag(key) }, set: { self.set(key, $0) })
  }
  func persistSort() {
    guard let comparator = sortOrder.first else { return }
    let paths: [PartialKeyPath<BatchImage>] = [
      \BatchImage.name, \BatchImage.outputBytes, \BatchImage.resolution, \BatchImage.saved,
      \BatchImage.detail,
    ]
    set("mainwindow/list_view/sort_column_index", paths.firstIndex(of: comparator.keyPath) ?? 0)
    set("mainwindow/list_view/sort_column_order", comparator.order == .forward ? 0 : 1)
  }
  func intBinding(_ key: String) -> Binding<Int> {
    Binding(get: { self.number(key) }, set: { self.set(key, $0) })
  }
  func textBinding(_ key: String) -> Binding<String> {
    Binding(get: { self.string(key) }, set: { self.set(key, $0) })
  }
  var formats: [String] {
    session?.formats ?? ["same", "jpg", "png", "webp", "tiff", "avif", "heic"]
  }
  var supportsLossless: Bool {
    session?.canEncode(string("compression_options/output/format_id", "same"), lossless: true)
      ?? true
  }
  var selectedImage: BatchImage? { items.first { selection.contains($0.id) } }
  var canCompress: Bool {
    let format = string("compression_options/output/format_id", "same")
    return !busy && !closing && !items.isEmpty && formats.contains(format)
      && (session?.canEncode(format, lossless: flag("compression_options/compression/lossless"))
        ?? true)
  }
  var appearance: ColorScheme? {
    switch number("preferences/general/theme_variant") {
    case 1: return .light
    case 2: return .dark
    default: return nil
    }
  }

  var layoutDirection: LayoutDirection {
    session?.rightToLeft == true ? .rightToLeft : .leftToRight
  }
  func enableNotifications() {
    guard Bundle.main.bundleIdentifier != nil else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      [weak self] _, error in
      if let error = error {
        DispatchQueue.main.async {
          self?.notice = Notice(title: "Notifications", detail: error.localizedDescription)
        }
      }
    }
  }

  func chooseFiles(folder: Bool = false, completion: (([String]) -> Void)? = nil) {
    guard !busy, !closing else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = folder
    panel.canChooseFiles = !folder
    panel.allowsMultipleSelection = !folder
    let last = string("extra/last_opened_directory")
    if !last.isEmpty { panel.directoryURL = URL(fileURLWithPath: last) }
    panel.begin { [weak self] response in
      guard response == .OK, let self = self else { return }
      let paths = panel.urls.map(\.path)
      if let first = panel.urls.first {
        self.set(
          "extra/last_opened_directory",
          folder ? first.path : first.deletingLastPathComponent().path)
      }
      if let completion = completion { completion(paths) } else { self.importPaths(paths) }
    }
  }

  func chooseOutput() {
    chooseFiles(folder: true) { [weak self] paths in
      if let first = paths.first { self?.set("compression_options/output/output_folder", first) }
    }
  }
  func importPaths(_ paths: [String], advanced: Bool = false, fromArguments: Bool = false) {
    guard !busy, !closing else { return }
    summary = ""
    session?.importPaths(paths, advanced: advanced, fromArguments: fromArguments)
    // Lock commands immediately; the coalesced C++ snapshot follows.
    busy = !paths.isEmpty && session != nil
  }
  func remove(all: Bool = false) {
    guard !busy, !closing else { return }
    session?.removeIDs(all ? items.map(\.id) : Array(selection))
    selection.removeAll()
  }
  func compress(failedOnly: Bool = false) {
    guard canCompress else { return }
    if !flag("compression_options/output/same_folder_as_input"),
      string("compression_options/output/output_folder").isEmpty
    {
      notice = Notice(title: t("Output"), detail: t("Please select an output folder"))
      return
    }
    if session?.requiresOverwriteConfirmation() == true {
      let alert = NSAlert()
      alert.messageText = t(
        "You are about to overwrite your original images and this action can't be undone.\n\nDo you really want to continue?"
      )
      alert.alertStyle = .warning
      alert.addButton(withTitle: t("No"))
      alert.addButton(withTitle: t("Yes"))
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    session?.compressFailedOnly(failedOnly)
  }
  func requestPreview(force: Bool = false) {
    guard !busy, !closing else { return }
    guard flag("mainwindow/previews_visible", true), let image = selectedImage else {
      session?.invalidatePreview()
      return
    }
    session?.previewID(image.id, generate: force || flag("mainwindow/auto_preview"))
  }
  func reveal(output: Bool) {
    guard let image = selectedImage else { return }
    let path = output ? image.output : image.path
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
      notice = Notice(title: t("File not found", "QIODevice"), detail: path)
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
  func drop(_ providers: [NSItemProvider], completion: (([String]) -> Void)? = nil) -> Bool {
    guard !busy, !closing else { return false }
    let group = DispatchGroup()
    let lock = NSLock()
    var paths: [(Int, String)] = []
    for (index, provider) in providers.enumerated() {
      group.enter()
      provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
        defer { group.leave() }
        let url =
          (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        guard let url = url, url.isFileURL else { return }
        lock.lock()
        paths.append((index, url.path))
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      let values = paths.sorted { $0.0 < $1.0 }.map(\.1)
      if let completion = completion { completion(values) } else { self?.importPaths(values) }
    }
    return true
  }
}
