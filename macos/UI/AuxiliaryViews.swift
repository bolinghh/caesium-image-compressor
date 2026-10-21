import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var store: BatchStore
  @NativeViewState private var tab = 0
  @NativeViewState private var showUsage = false
  private let prefix = "preferences/general/"
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Picker(store.t("Preferences..."), selection: $tab) {
        Text(store.t("General", "PreferencesDialog")).tag(0)
        Text(store.t("Performance", "PreferencesDialog")).tag(1)
        Text(store.t("Updates & Privacy", "PreferencesDialog")).tag(2)
      }.pickerStyle(.segmented).labelsHidden()
      if tab == 0 {
        Form {
          Picker(
            store.t("Language", "PreferencesDialog"),
            selection: store.textBinding("preferences/language/locale")
          ) {
            ForEach(store.session?.locales ?? [["id": "default", "label": "Default"]], id: \.self) {
              locale in
              Text(locale["label"] ?? "").tag(locale["id"] ?? "default")
            }
          }
          Picker(
            store.t("Appearance", "PreferencesDialog"),
            selection: store.intBinding(prefix + "theme_variant")
          ) {
            Text(store.t("Auto", "PreferencesDialog")).tag(0)
            Text(store.t("Light", "PreferencesDialog")).tag(1)
            Text(store.t("Dark", "PreferencesDialog")).tag(2)
          }
          Toggle(
            store.t("Import files in subfolders when opening a directory", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "import_subfolders"))
          Picker(
            store.t("When opening files", "PreferencesDialog"),
            selection: store.intBinding(prefix + "args_behaviour")
          ) {
            Text(store.t("Import only", "PreferencesDialog")).tag(0)
            Text(store.t("Import and compress", "PreferencesDialog")).tag(1)
          }
          Toggle(
            store.t("Prompt before exit", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "prompt_before_exit"))
          Toggle(
            store.t("Skip message and warning dialogs during compression", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "skip_compression_dialogs"))
          Picker(
            store.t("After compression", "PreferencesDialog"),
            selection: store.intBinding(prefix + "post_compression_action")
          ) {
            ForEach(
              Array(
                ["No action", "Close the application", "Sleep", "Shutdown", "Open output folder"]
                  .enumerated()), id: \.offset
            ) { index, title in
              Text(store.t(title, "PreferencesDialog")).tag(index)
            }
          }
        }
      }
      if tab == 1 {
        Form {
          Toggle(
            store.t("Multithreading", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "multithreading"))
          NumberSetting(
            store: store, title: "Maximum threads", key: prefix + "multithreading_max_threads",
            range: 1...max(1, store.number("application/max_threads", 8))
          )
          .disabled(!store.flag(prefix + "multithreading"))
          Picker(
            store.t("Thread priority", "PreferencesDialog"),
            selection: store.intBinding(prefix + "threads_priority")
          ) {
            ForEach(
              Array(
                ["Idle", "Lowest", "Low", "Normal", "High", "Highest", "Time critical"].enumerated()
              ), id: \.offset
            ) { index, title in
              Text(store.t(title, "PreferencesDialog")).tag(index)
            }
          }
        }
      }
      if tab == 2 {
        Form {
          Toggle(
            store.t("Check updates at startup", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "check_updates_at_startup")
          )
          .disabled(store.session?.updaterAvailable != true)
          Button(store.t("Check for updates", "AboutDialog")) { store.session?.checkForUpdates() }
            .disabled(store.session?.updaterAvailable != true)
          Divider()
          Toggle(
            store.t("Send anonymous usage reports", "PreferencesDialog"),
            isOn: store.boolBinding(prefix + "send_usage_reports"))
          Button(store.t("Show usage data", "PreferencesDialog")) { showUsage = true }
          Button(store.t("Enable completion notifications")) { store.enableNotifications() }
            .disabled(Bundle.main.bundleIdentifier == nil)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(20).frame(width: 540, height: 360)
    .disabled(store.busy || store.closing)
    .preferredColorScheme(store.appearance)
    .environment(\.layoutDirection, store.layoutDirection)
    .sheet(isPresented: $showUsage) { UsageView(store: store) }
  }
}

struct AdvancedImportView: View {
  @ObservedObject var store: BatchStore
  @Environment(\.dismiss) private var dismiss
  @NativeViewState private var paths: [String] = []
  @NativeViewState private var selection = Set<String>()
  @NativeViewState private var listError = ""
  private let prefix = "preferences/advaced_import/"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.t("Advanced import...")).font(.title2)
      List(paths, id: \.self, selection: $selection) { path in
        Text(path).lineLimit(1).truncationMode(.middle).help(path)
      }.frame(minHeight: 140)
        .onDrop(of: ["public.file-url"], isTargeted: nil) {
          store.drop($0) { append($0, expandLists: true) }
        }
      HStack {
        Menu(store.t("Add", "AdvancedImportDialog")) {
          Button(store.t("Add files...")) { store.chooseFiles { append($0) } }
          Button(store.t("Add folder...")) { store.chooseFiles(folder: true) { append($0) } }
          Button(store.t("Import from list...", "AdvancedImportDialog")) {
            store.chooseFiles { append($0, expandLists: true, forceList: true) }
          }
        }
        Button(store.t("Remove")) {
          paths.removeAll { selection.contains($0) }
          selection.removeAll()
        }.disabled(selection.isEmpty)
        Spacer()
      }
      Toggle(
        store.t("Import files in subfolders when opening a directory", "AdvancedImportDialog"),
        isOn: store.boolBinding(prefix + "import_subfolders"))
      Toggle(
        store.t("Do not import if size is", "AdvancedImportDialog"),
        isOn: store.boolBinding(prefix + "skip_by_size/enabled"))
      HStack {
        Picker("", selection: store.intBinding(prefix + "skip_by_size/condition")) {
          Text(store.t("greater than", "AdvancedImportDialog")).tag(0)
          Text(store.t("equal to", "AdvancedImportDialog")).tag(1)
          Text(store.t("less than", "AdvancedImportDialog")).tag(2)
        }.labelsHidden()
        NumberSetting(
          store: store, title: "Size", key: prefix + "skip_by_size/value", range: 1...524_288_000)
        Picker("", selection: store.intBinding(prefix + "skip_by_size/unit")) {
          Text("bytes").tag(0)
          Text("KB").tag(1)
          Text("MB").tag(2)
        }.labelsHidden()
      }.disabled(!store.flag(prefix + "skip_by_size/enabled"))
      TextField(
        store.t("Filename pattern", "AdvancedImportDialog"),
        text: store.textBinding("preferences/advanced_import/filename_pattern"))
      if !listError.isEmpty {
        Text(listError).font(.caption).foregroundColor(.red).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button(store.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(store.t("Import", "AdvancedImportDialog")) {
          store.importPaths(paths, advanced: true)
          dismiss()
        }
        .keyboardShortcut(.defaultAction).disabled(paths.isEmpty || store.busy)
      }
    }.padding(20).frame(width: 600, height: 500)
  }

  private func append(_ newPaths: [String], expandLists: Bool = false, forceList: Bool = false) {
    var additions: [String] = []
    for path in newPaths {
      let url = URL(fileURLWithPath: path)
      let plainText =
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .plainText))
        == true
      if forceList
        || (expandLists && (plainText || ["txt", "list"].contains(url.pathExtension.lowercased())))
      {
        do {
          additions += try String(contentsOfFile: path, encoding: .utf8).components(
            separatedBy: .newlines
          )
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        } catch { listError = error.localizedDescription }
      } else {
        additions.append(path)
      }
    }
    for path in additions where !paths.contains(path) { paths.append(path) }
  }
}

struct UsageView: View {
  @ObservedObject var store: BatchStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.t("Show usage data", "PreferencesDialog")).font(.title2)
      ScrollView {
        Text(store.session?.usageData() ?? "{}").font(.system(.body, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button(store.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(20).frame(width: 580, height: 440)
  }
}

struct AboutView: View {
  @ObservedObject var store: BatchStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(
        width: 72, height: 72)
      Text("Caesium Image Compressor").font(.title2)
      Text("v" + store.string("application/version", "2.8.5")).foregroundColor(.secondary)
      Text("UUID: " + store.string("application/uuid")).font(.caption).textSelection(.enabled)
      Link("saerasoft.com", destination: URL(string: "https://saerasoft.com/caesium")!)
      Text("GNU General Public License v3").font(.caption).foregroundColor(.secondary)
      Text(store.t("Copyright © 2023 Matteo Paonessa.\nAll rights reserved.", "AboutDialog"))
        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
      Button(store.t("Check for updates", "AboutDialog")) { store.session?.checkForUpdates() }
        .disabled(store.session?.updaterAvailable != true)
      Button(store.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding(28).frame(width: 390)
  }
}
