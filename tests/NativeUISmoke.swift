import AppKit
import SwiftUI

@_silgen_name("CaesiumNativeUITestsFinished")
private func testsFinished(_ status: Int32)

@MainActor private var smoke: NativeSmoke?

@MainActor
@_cdecl("CaesiumFinishNativeUITests")
func finishNativeUITests() {
  if let observer = smoke?.closeObserver { NotificationCenter.default.removeObserver(observer) }
  smoke?.host.shutdown()
  smoke = nil
}

@MainActor
@_cdecl("CaesiumRunNativeUITests")
func runNativeUITests(_ fixture: UnsafePointer<CChar>, _ artifacts: UnsafePointer<CChar>) {
  smoke = NativeSmoke(fixture: String(cString: fixture), artifacts: String(cString: artifacts))
  smoke?.run()
}

@MainActor
private final class NativeSmoke {
  let fixture: String
  let artifacts: URL
  let store = BatchStore()
  lazy var host = NativeWindowController(store: store)
  var failed = false
  var closeObserver: NSObjectProtocol?

  init(fixture: String, artifacts: String) {
    self.fixture = fixture
    self.artifacts = URL(fileURLWithPath: artifacts)
  }
  func require(_ condition: Bool, _ message: String) -> Bool {
    guard condition else {
      fputs("Native UI check failed: \(message)\n", stderr)
      failed = true
      store.onCloseReady = { testsFinished(1) }
      _ = store.session?.requestClose()
      return false
    }
    return true
  }
  func later(_ action: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
  }
  func wait(
    _ condition: @escaping @MainActor @Sendable () -> Bool,
    deadline: Date = Date().addingTimeInterval(30),
    then action: @escaping @MainActor @Sendable () -> Void
  ) {
    if failed { return }
    if condition() {
      later(action)
      return
    }
    guard
      require(
        Date() < deadline,
        "Timed out: phase=\(store.phase), items=\(store.items.count), previewLoading=\(store.previewLoading), previewError=\(store.previewError)"
      )
    else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.wait(condition, deadline: deadline, then: action)
    }
  }
  func capture(_ name: String, window: NSWindow? = nil) {
    guard !failed, let view = (window ?? host.window)?.contentView?.superview else {
      _ = require(false, "No window content")
      return
    }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      _ = require(false, "Could not capture window")
      return
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      _ = require(false, "Could not encode screenshot")
      return
    }
    do { try png.write(to: artifacts.appendingPathComponent(name + ".png")) } catch {
      _ = require(false, error.localizedDescription)
    }
  }
  func run() {
    store.set("compression_options/output/keep_dates", 2)
    guard
      require(
        store.flag("compression_options/output/keep_creation_date")
          && store.flag("compression_options/output/keep_last_modified_date")
          && store.flag("compression_options/output/keep_last_access_date"),
        "Date master selection was not propagated")
    else { return }
    store.set("compression_options/output/keep_creation_date", false)
    guard
      require(
        store.number("compression_options/output/keep_dates") == 1,
        "Partial date state was not preserved")
    else { return }
    store.set("compression_options/output/keep_dates", 0)
    store.set("compression_options/compression/max_output_size_unit", 3)
    store.set("compression_options/compression/max_output_size", 500)
    guard
      require(
        store.number("compression_options/compression/max_output_size") == 100,
        "Percentage size was not clamped")
    else { return }
    store.set("compression_options/compression/max_output_size_unit", 0)
    host.showWindow(nil)
    host.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    later {
      self.capture("native-empty")
      self.store.importPaths([self.fixture, self.fixture])
      self.wait({ !self.store.busy && self.store.items.count == 1 }) {
        guard self.require(self.store.items.count == 1, "Duplicate imports") else { return }
        self.store.selection = [self.store.items[0].id]
        self.later {
          self.host.preview()
          self.wait({ self.store.original != nil && self.store.compressed != nil }) {
            self.checkPreviewInteraction()
          }
        }
      }
    }
  }
  func checkPreviewInteraction() {
    @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    guard let content = host.window?.contentView else {
      _ = require(false, "Missing content")
      return
    }
    let views = descendants(content).compactMap { $0 as? NSScrollView }.filter {
      $0.documentView is NSImageView
    }
    guard require(views.count == 2, "Expected two native image viewports") else { return }
    views[0].magnification = 1.25
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveMagnifyNotification, object: views[0])
    later {
      guard
        self.require(
          abs(views[1].magnification - 1.25) < 0.01, "Linked magnification did not synchronize")
      else { return }
      self.lightAndDark()
    }
  }
  func lightAndDark() {
    store.set("preferences/general/theme_variant", 1)
    later {
      self.capture("native-light")
      self.store.set("preferences/general/theme_variant", 2)
      self.later {
        self.capture("native-dark")
        self.host.window?.setContentSize(NSSize(width: 600, height: 480))
        self.later {
          self.capture("native-minimum")
          if let root = self.host.window?.contentView {
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let imageViews = descendants(root).compactMap { $0 as? NSScrollView }.filter { $0.documentView is NSImageView }
            for imageView in imageViews {
              let bounds = imageView.convert(imageView.bounds, to: root)
              guard self.require(bounds.minX >= -1 && bounds.maxX <= root.bounds.maxX + 1, "A preview viewport overflowed the minimum window width") else { return }
            }
          }
          self.host.window?.setContentSize(NSSize(width: 1120, height: 780))
          self.host.preferences()
          self.later {
            self.capture("native-settings", window: NSApp.keyWindow)
            NSApp.keyWindow?.orderOut(nil)
            self.host.window?.makeKeyAndOrderFront(nil)
            self.store.showAdvancedImport = true
            self.later {
              self.capture("native-advanced-import", window: self.host.window?.attachedSheet)
              self.store.showAdvancedImport = false
              self.later { self.languages() }
            }
          }
        }
      }
    }
  }
  func languages() {
    store.set("preferences/language/locale", "zh_CN")
    later {
      self.capture("native-chinese")
      self.store.set("preferences/language/locale", "ar_EG")
      self.later {
        guard
          self.require(self.store.layoutDirection == .rightToLeft, "RTL locale did not propagate")
        else { return }
        self.capture("native-rtl")
        self.store.set("preferences/language/locale", "en_US")
        self.later { self.compress() }
      }
    }
  }
  func compress() {
    host.compress()
    wait({ !self.store.busy && self.store.items.first?.status == 2 }) {
      guard let image = self.store.items.first,
        self.require(FileManager.default.fileExists(atPath: image.output), "No compressed output"),
        self.require(FileManager.default.fileExists(atPath: self.fixture), "Original was removed")
      else { return }
      self.capture("native-completed")
      self.store.showUsage = true
      self.later {
        self.capture("native-usage", window: self.host.window?.attachedSheet)
        self.store.showUsage = false
        self.later {
          self.store.showAbout = true
          self.later {
            self.capture("native-about", window: self.host.window?.attachedSheet)
            self.store.showAbout = false
            self.later {
              self.host.removeItems()
              self.wait({ self.store.items.isEmpty }) {
                self.closeObserver = NotificationCenter.default.addObserver(
                  forName: Notification.Name("CaesiumNativeCloseReady"), object: nil, queue: .main
                ) { _ in testsFinished(0) }
                self.host.closeMain()
              }
            }
          }
        }
      }
    }
  }
}
