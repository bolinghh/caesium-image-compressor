import AppKit
import SwiftUI

// Select the macOS 12 property wrapper explicitly, including SDKs that also export a State macro.
typealias NativeViewState<Value> = SwiftUI.State<Value>

// The approved workbench: system typography/colors, thin separators, compact controls.
// Content stays opaque; the system owns toolbar materials on each supported macOS release.
enum NativeDesign {
  static let inspectorWidth: CGFloat = 320
  static let padding: CGFloat = 16
  static let spacing: CGFloat = 12
}

struct BatchView: View {
  @ObservedObject var store: BatchStore
  @NativeViewState private var inspectorTab = 0
  @StateObject private var viewport = PreviewViewport()
  @NativeViewState private var dragTarget = false
  @NativeViewState private var showNarrowInspector = false

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if geometry.size.width < 760 {
          // Recreate the split hierarchy when collapsing the inspector. An existing
          // NSSplitView can otherwise retain its previous pane minimum on resize.
          workArea.frame(width: geometry.size.width)
        } else {
          HSplitView {
            workArea.frame(minWidth: 350)
            if store.flag("macos/inspector_visible", true) {
              inspector.frame(minWidth: 300, idealWidth: NativeDesign.inspectorWidth, maxWidth: 380)
            }
          }
        }
        Divider()
        statusBar
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .popover(isPresented: $showNarrowInspector) {
        inspector.frame(width: NativeDesign.inspectorWidth, height: 480)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button {
          store.chooseFiles()
        } label: {
          Label(store.t("Add files..."), systemImage: "plus")
        }
        .disabled(store.busy || store.closing).help(store.t("Add files..."))
        Button {
          store.chooseFiles(folder: true)
        } label: {
          Label(store.t("Add folder..."), systemImage: "folder.badge.plus")
        }
        .disabled(store.busy || store.closing)
        Button {
          store.requestPreview(force: true)
        } label: {
          Label(store.t("Preview"), systemImage: "magnifyingglass")
        }
        .disabled(store.selection.isEmpty || store.busy || store.closing)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          if (NSApp.keyWindow?.contentView?.bounds.width ?? 1120) < 760 {
            showNarrowInspector.toggle()
          } else {
            store.set("macos/inspector_visible", !store.flag("macos/inspector_visible", true))
          }
        } label: {
          Label(store.t("Parameters"), systemImage: "sidebar.right")
        }.help(store.t("Parameters"))
        Button {
          store.compress()
        } label: {
          Label(store.t("Compress"), systemImage: "arrow.down.to.line")
        }
        .disabled(!store.canCompress)
      }
    }
    .onChange(of: store.selection) { _ in store.requestPreview() }
    .onChange(of: store.sortOrder) { _ in store.persistSort() }
    .sheet(isPresented: $store.showAdvancedImport) { AdvancedImportView(store: store) }
    .sheet(isPresented: $store.showAbout) { AboutView(store: store) }
    .sheet(isPresented: $store.showUsage) { UsageView(store: store) }
    .alert(item: $store.notice) { notice in
      Alert(
        title: Text(notice.title), message: Text(notice.detail),
        dismissButton: .default(Text(store.t("Ok", "QIODevice"))))
    }
    .preferredColorScheme(store.appearance)
    .environment(\.layoutDirection, store.layoutDirection)
  }

  private var workArea: some View {
    VSplitView {
      imageList.frame(minHeight: 160)
      if store.flag("mainwindow/previews_visible", true) {
        comparison.frame(minHeight: 160, idealHeight: 260)
      }
    }
  }

  private var imageList: some View {
    ZStack {
      Table(
        store.items.sorted(using: store.sortOrder), selection: $store.selection,
        sortOrder: $store.sortOrder
      ) {
        TableColumn(store.t("Name", "CImageTreeModel"), value: \.name) { image in
          Label(image.name, systemImage: image.symbol)
            .foregroundColor(image.status == 3 ? .red : .primary)
            .help(image.path + "\n" + image.detail)
        }.width(min: 150, ideal: 260)
        TableColumn(store.t("Size", "CImageTreeModel"), value: \.outputBytes) { image in
          Text(image.sizeText).monospacedDigit().help(
            ByteCountFormatter.string(fromByteCount: image.bytes, countStyle: .binary))
        }.width(min: 65, ideal: 90)
        TableColumn(store.t("Resolution", "CImageTreeModel"), value: \.resolution).width(
          min: 70, ideal: 90)
        TableColumn(store.t("Saved", "CImageTreeModel"), value: \.saved) { image in
          Text("\(image.saved, specifier: "%.0f")%")
            .monospacedDigit().foregroundColor(image.saved < 0 ? .red : .secondary)
        }.width(min: 50, ideal: 65)
        TableColumn(store.t("Info", "CImageTreeModel"), value: \.detail) { image in
          Text(image.detail).lineLimit(1).help(image.detail)
        }.width(min: 80, ideal: 140)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: false))
      .contextMenu {
        Button(store.t("Add files...")) { store.chooseFiles() }.disabled(store.busy)
        Button(store.t("Add folder...")) { store.chooseFiles(folder: true) }.disabled(store.busy)
        Divider()
        Button(store.t("Show original in file manager")) { store.reveal(output: false) }.disabled(
          store.selection.isEmpty)
        Button(store.t("Show compressed in file manager")) { store.reveal(output: true) }.disabled(
          store.selectedImage?.output.isEmpty != false)
        Divider()
        Button(store.t("Remove")) { store.remove() }.disabled(store.selection.isEmpty || store.busy)
        Button(store.t("Clear")) { store.remove(all: true) }.disabled(
          store.items.isEmpty || store.busy)
        Button(store.t("Recompress failed")) { store.compress(failedOnly: true) }.disabled(
          !store.canCompress || !store.items.contains { $0.status == 3 })
      }
      if store.items.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "photo.on.rectangle").font(.system(size: 32)).foregroundColor(
            .secondary)
          Text(store.t("Add images to get started")).font(.headline)
          Text(store.t("Drop images or folders here")).foregroundColor(.secondary)
          Button(store.t("Add files...")) { store.chooseFiles() }.disabled(store.busy)
        }.padding(24).allowsHitTesting(!store.busy)
      }
      if dragTarget { Rectangle().stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
    }
    .onDrop(of: ["public.file-url"], isTargeted: $dragTarget) { store.drop($0) }
    .accessibilityLabel(store.t("Images"))
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      Picker(store.t("Parameters"), selection: $inspectorTab) {
        Text(store.t("Compression")).tag(0)
        Text(store.t("Resize")).tag(1)
        Text(store.t("Output")).tag(2)
      }.pickerStyle(.segmented).controlSize(.small).labelsHidden().padding(12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(store.t("Applies to the entire batch")).font(.caption).foregroundColor(.secondary)
          if inspectorTab == 0 { CompressionInspector(store: store) }
          if inspectorTab == 1 { ResizeInspector(store: store) }
          if inspectorTab == 2 { OutputInspector(store: store) }
        }.padding(NativeDesign.padding).frame(maxWidth: .infinity, alignment: .leading)
      }.disabled(store.busy || store.closing)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var comparison: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.selectedImage?.name ?? store.t("Preview")).lineLimit(1).truncationMode(.middle)
          .font(.callout)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
        if store.previewLoading {
          ProgressView().controlSize(.small).accessibilityLabel(store.t("Loading"))
        }
        Toggle(store.t("Auto preview"), isOn: store.boolBinding("mainwindow/auto_preview"))
          .toggleStyle(.checkbox).fixedSize().disabled(store.busy)
        Button("100%") { viewport.reset(scale: 1) }.fixedSize().help(store.t("Actual size"))
        Button(store.t("Fit")) { viewport.reset(scale: 0) }.fixedSize()
      }.padding(.horizontal, 12).padding(.vertical, 8)
      Divider()
      GeometryReader { geometry in
        HStack(spacing: 0) {
          previewPanel(store.t("Original"), image: store.original, bytes: store.previewOriginalBytes, format: store.previewOriginalFormat)
            .frame(width: max(0, (geometry.size.width - 1) / 2)).clipped()
          Divider()
          previewPanel(
            store.t("Compressed") + (store.previewGenerated ? " · " + store.t("Preview") : ""),
            image: store.compressed, bytes: store.previewCompressedBytes, format: store.previewCompressedFormat
          )
          .frame(width: max(0, (geometry.size.width - 1) / 2)).clipped()
        }.frame(width: geometry.size.width, height: geometry.size.height)
      }
      if !store.previewError.isEmpty {
        Text(store.previewError).font(.caption).foregroundColor(.red).textSelection(.enabled)
          .padding(8)
      }
    }
  }

  private func previewPanel(_ title: String, image: NSImage?, bytes: Int64, format: String) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text(title + (format.isEmpty ? "" : " · " + format)).lineLimit(1).truncationMode(.middle).frame(
          minWidth: 0, maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .trailing, spacing: 2) {
          if let image = image { Text("\(Int(image.size.width)) × \(Int(image.size.height))").monospacedDigit().fixedSize() }
          if bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)).monospacedDigit().fixedSize() }
        }
      }.font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
      if let image = image {
        LinkedImageView(image: image, viewport: viewport).accessibilityLabel(title)
      } else {
        Text(
          store.selection.isEmpty ? store.t("Select an image to preview") : store.t("No preview")
        )
        .font(.callout).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      if store.busy || store.closing {
        if store.phase == "compressing" {
          ProgressView(value: Double(store.completed), total: Double(max(1, store.total))).frame(
            width: 120)
          Text("\(store.completed) / \(store.total)").monospacedDigit()
        } else {
          ProgressView().controlSize(.small)
        }
        Text(
          store.t(
            store.phase == "importing"
              ? "Importing files..."
              : store.phase == "planning"
                ? "Preparing output..."
                : store.phase == "canceling" || store.closing
                  ? "Finishing active tasks..." : "Compressing..."))
        Spacer()
        Button(store.t("Cancel")) { store.session?.cancel() }.disabled(
          store.phase == "canceling" || store.closing)
      } else {
        Text("\(store.items.count) " + store.t("Images"))
        Text(
          ByteCountFormatter.string(
            fromByteCount: store.items.reduce(0) { $0 + $1.bytes }, countStyle: .binary)
        ).monospacedDigit()
        Spacer()
        Text(store.summary.replacingOccurrences(of: "\n", with: " · ")).lineLimit(1).help(
          store.summary)
      }
    }.font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).frame(height: 36)
  }
}

struct ParameterGroup<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct NumberSetting: View {
  @ObservedObject var store: BatchStore
  let title: String
  let key: String
  var range: ClosedRange<Int> = 1...99999
  var body: some View {
    HStack {
      Text(store.t(title))
      Spacer()
      TextField("", value: store.intBinding(key), formatter: Self.formatter(range))
        .multilineTextAlignment(.trailing).frame(width: 65).accessibilityLabel(store.t(title))
      Stepper("", value: store.intBinding(key), in: range).labelsHidden()
    }
  }
  static func formatter(_ range: ClosedRange<Int>) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.allowsFloats = false
    formatter.minimum = NSNumber(value: range.lowerBound)
    formatter.maximum = NSNumber(value: range.upperBound)
    return formatter
  }
}

struct QualitySetting: View {
  @ObservedObject var store: BatchStore
  let format: String
  var minimum = 0
  private var key: String {
    "compression_options/compression/\(format == "jpg" ? "jpeg" : format)_quality"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      NumberSetting(store: store, title: "Quality", key: key, range: minimum...100)
      Slider(
        value: Binding(
          get: { Double(store.number(key, 80)) }, set: { store.set(key, Int($0.rounded())) }),
        in: Double(minimum)...100, step: 1
      )
      .accessibilityLabel(format.uppercased() + " " + store.t("Quality"))
    }
  }
}

struct CompressionInspector: View {
  @ObservedObject var store: BatchStore
  private let prefix = "compression_options/compression/"
  var body: some View {
    ParameterGroup(title: store.t("Compression")) {
      Picker(store.t("Mode"), selection: store.intBinding(prefix + "mode")) {
        Text(store.t("Quality")).tag(0)
        Text(store.t("Size")).tag(1)
      }
      if store.number(prefix + "mode") == 1 {
        NumberSetting(
          store: store, title: "Maximum size", key: prefix + "max_output_size",
          range: 1...(store.number(prefix + "max_output_size_unit") == 3 ? 100 : 524_288_000))
        Picker(store.t("Unit"), selection: store.intBinding(prefix + "max_output_size_unit")) {
          Text("bytes").tag(0)
          Text("KB").tag(1)
          Text("MB").tag(2)
          Text("%").tag(3)
        }
      }
      Toggle(store.t("Lossless"), isOn: store.boolBinding(prefix + "lossless")).disabled(
        !store.supportsLossless)
      Toggle(store.t("Keep Metadata"), isOn: store.boolBinding(prefix + "keep_metadata"))
      if store.flag(prefix + "lossless") && store.number(prefix + "mode") == 1 {
        Text(store.t("Lossless compression may not reach the target size.")).font(.caption)
          .foregroundColor(.secondary)
      }
    }
    Divider()
    ForEach(store.formats.filter { $0 != "same" }, id: \.self) { format in
      DisclosureGroup(format.uppercased(), isExpanded: expansion(format)) {
        VStack(alignment: .leading, spacing: 10) {
          if format != "tiff" {
            QualitySetting(
              store: store, format: format, minimum: format == "jpg" || format == "webp" ? 1 : 0
            )
            .disabled(store.flag(prefix + "lossless") || store.number(prefix + "mode") == 1)
          }
          if format == "jpg" {
            Picker(
              store.t("Chroma subsampling"),
              selection: store.intBinding(prefix + "jpeg_chroma_subsampling")
            ) {
              Text(store.t("Auto")).tag(0)
              Text("4:4:4").tag(444)
              Text("4:2:2").tag(422)
              Text("4:2:0").tag(420)
              Text("4:1:1").tag(411)
            }
            Toggle(store.t("Progressive"), isOn: store.boolBinding(prefix + "jpeg_progressive"))
          }
          if format == "png" {
            NumberSetting(
              store: store, title: "Optimization level", key: prefix + "png_optimization_level",
              range: 1...6)
          }
          if format == "tiff" {
            Picker(
              store.t("Compression method"), selection: store.intBinding(prefix + "tiff_method")
            ) {
              Text("Uncompressed").tag(0)
              Text("LZW").tag(1)
              Text("Deflate").tag(2)
              Text("Packbits").tag(3)
            }
            NumberSetting(
              store: store, title: "Deflate level", key: prefix + "tiff_deflate_level", range: 1...3
            )
            .disabled(store.number(prefix + "tiff_method") != 2)
          }
          if format == "avif" || format == "heic",
            store.session?.canEncode(format, lossless: false) == false
          {
            Text(store.t("Encoder unavailable")).font(.caption).foregroundColor(.secondary)
          }
        }.padding(.top, 8)
      }
    }
  }
  private func expansion(_ format: String) -> Binding<Bool> {
    let id = format == "jpg" ? "jpeg" : format
    let key = "mainwindow/compression/\(id)_options_visible"
    return Binding(get: { store.flag(key, true) }, set: { store.set(key, $0) })
  }
}

struct ResizeInspector: View {
  @ObservedObject var store: BatchStore
  private let prefix = "compression_options/resize/"
  var body: some View {
    ParameterGroup(title: store.t("Resize")) {
      Picker(store.t("Fit to"), selection: store.intBinding(prefix + "fit_to")) {
        ForEach(
          Array(
            ["No resize", "Dimensions", "Percentage", "Short edge", "Long edge", "Width", "Height"]
              .enumerated()), id: \.offset
        ) { index, label in
          Text(store.t(label)).tag(index)
        }
      }
      let mode = store.number(prefix + "fit_to")
      if mode != 0 {
        let limit = mode == 2 ? (store.flag(prefix + "do_not_enlarge") ? 100 : 999) : 99999
        if [1, 2, 5].contains(mode) {
          NumberSetting(
            store: store, title: mode == 2 ? "Width (%)" : "Width", key: prefix + "width",
            range: 1...limit)
        }
        if [1, 2, 6].contains(mode) {
          NumberSetting(
            store: store, title: mode == 2 ? "Height (%)" : "Height", key: prefix + "height",
            range: 1...limit)
        }
        if [3, 4].contains(mode) {
          NumberSetting(store: store, title: "Edge", key: prefix + "size")
        }
        Toggle(store.t("Keep aspect ratio"), isOn: store.boolBinding(prefix + "keep_aspect_ratio"))
          .disabled(mode != 2)
        Toggle(store.t("Do not enlarge"), isOn: store.boolBinding(prefix + "do_not_enlarge"))
      }
    }
  }
}

struct OutputInspector: View {
  @ObservedObject var store: BatchStore
  private let prefix = "compression_options/output/"
  var body: some View {
    ParameterGroup(title: store.t("Output")) {
      Picker(store.t("Format"), selection: store.textBinding(prefix + "format_id")) {
        ForEach(store.formats, id: \.self) { format in
          Text(format == "same" ? store.t("Same as input") : format.uppercased()).tag(format)
            .disabled(store.session?.canEncode(format, lossless: false) == false)
        }
        if !store.formats.contains(store.string(prefix + "format_id")) {
          Text(store.string(prefix + "format_id").uppercased() + " · " + store.t("Unavailable"))
            .tag(store.string(prefix + "format_id"))
        }
      }
      Toggle(
        store.t("Same folder as input"), isOn: store.boolBinding(prefix + "same_folder_as_input"))
      HStack {
        TextField(store.t("Output folder"), text: store.textBinding(prefix + "output_folder"))
        Button {
          store.chooseOutput()
        } label: {
          Image(systemName: "folder")
        }.help(store.t("Output folder"))
      }.disabled(store.flag(prefix + "same_folder_as_input"))
      TextField(store.t("Suffix"), text: store.textBinding(prefix + "output_suffix"))
      Toggle(
        store.t("Keep folder structure"),
        isOn: store.boolBinding("compression_options/compression/keep_structure")
      )
      .disabled(store.flag(prefix + "same_folder_as_input"))
      Toggle(
        store.t("Skip if output size is bigger than the original"),
        isOn: store.boolBinding(prefix + "skip_if_bigger"))
      Text(store.t("JPEG output composites transparency on white.")).font(.caption).foregroundColor(
        .secondary)
    }
    Divider()
    ParameterGroup(title: store.t("Keep dates")) {
      DateSelectionToggle(store: store)
      Group {
        Toggle(store.t("Creation"), isOn: store.boolBinding(prefix + "keep_creation_date"))
        Toggle(
          store.t("Last modified"), isOn: store.boolBinding(prefix + "keep_last_modified_date"))
        Toggle(store.t("Last access"), isOn: store.boolBinding(prefix + "keep_last_access_date"))
      }.disabled(store.number(prefix + "keep_dates") == 0)
    }
    Divider()
    ParameterGroup(title: store.t("Original files")) {
      Toggle(
        store.t("Move the original file"), isOn: store.boolBinding(prefix + "move_original_file"))
      Picker(
        store.t("Destination"),
        selection: store.intBinding(prefix + "move_original_file_destination")
      ) {
        Text(store.t("To Trash")).tag(0)
        Text(store.t("Delete Permanently")).tag(1)
      }.disabled(!store.flag(prefix + "move_original_file"))
      if store.flag(prefix + "move_original_file"),
        store.number(prefix + "move_original_file_destination") == 1
      {
        Label(store.t("Delete Permanently"), systemImage: "exclamationmark.triangle").font(.caption)
          .foregroundColor(.red)
      }
    }
  }
}

// AppKit preserves the existing three-state date selection, including partial selections.
struct DateSelectionToggle: NSViewRepresentable {
  @ObservedObject var store: BatchStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(checkboxWithTitle: store.t("Keep dates"), target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    button.allowsMixedState = true
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    button.title = store.t("Keep dates")
    button.isEnabled = !store.busy && !store.closing
    switch store.number("compression_options/output/keep_dates") {
    case 0: button.state = .off
    case 2: button.state = .on
    default: button.state = .mixed
    }
  }
  @MainActor final class Coordinator: NSObject {
    let store: BatchStore
    init(store: BatchStore) { self.store = store }
    @objc func changed(_ sender: NSButton) {
      store.set("compression_options/output/keep_dates", sender.state == .off ? 0 : 2)
    }
  }
}
