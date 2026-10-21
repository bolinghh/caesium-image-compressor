import AppKit
import Combine
import SwiftUI

@MainActor
final class PreviewViewport: ObservableObject {
  @Published var scale: CGFloat = 0  // zero requests fit-to-window
  @Published var center = CGPoint(x: 0.5, y: 0.5)
  @Published var revision = 0
  func reset(scale: CGFloat) {
    self.scale = scale
    center = CGPoint(x: 0.5, y: 0.5)
    revision += 1
  }
}

struct LinkedImageView: NSViewRepresentable {
  let image: NSImage
  @ObservedObject var viewport: PreviewViewport

  func makeCoordinator() -> Coordinator { Coordinator(viewport: viewport) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.01
    scroll.maxMagnification = 16
    scroll.backgroundColor = .underPageBackgroundColor
    let document = NSImageView()
    document.imageScaling = .scaleProportionallyUpOrDown
    scroll.documentView = document
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.attach(scroll)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(scroll, image: image, viewport: viewport)
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject {
    let viewport: PreviewViewport
    weak var scroll: NSScrollView?
    var observations: [NSObjectProtocol] = []
    var applying = false
    var lastImage: NSImage?
    var revision = -1
    init(viewport: PreviewViewport) { self.viewport = viewport }
    func attach(_ scroll: NSScrollView) {
      self.scroll = scroll
      for (name, object) in [
        (NSView.boundsDidChangeNotification, scroll.contentView as AnyObject),
        (NSScrollView.didEndLiveMagnifyNotification, scroll as AnyObject),
      ] {
        observations.append(
          NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
          })
      }
    }
    func detach() {
      observations.forEach { NotificationCenter.default.removeObserver($0) }
      observations.removeAll()
    }
    func update(_ scroll: NSScrollView, image: NSImage, viewport: PreviewViewport) {
      guard let document = scroll.documentView as? NSImageView else { return }
      applying = true
      defer { applying = false }
      let newImage = lastImage !== image
      if newImage {
        lastImage = image
        document.image = image
        document.frame = NSRect(origin: .zero, size: image.size)
      }
      let fit = max(
        0.01,
        min(
          scroll.contentSize.width / max(1, image.size.width),
          scroll.contentSize.height / max(1, image.size.height)))
      let scale = viewport.scale == 0 ? fit : viewport.scale
      scroll.magnification = min(16, max(0.01, scale))
      let visible = scroll.documentVisibleRect.size
      let origin = CGPoint(
        x: max(
          0,
          min(
            image.size.width - visible.width,
            image.size.width * viewport.center.x - visible.width / 2)),
        y: max(
          0,
          min(
            image.size.height - visible.height,
            image.size.height * viewport.center.y - visible.height / 2)))
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
      revision = viewport.revision
    }
    func changed() {
      guard !applying, let scroll = scroll, let image = lastImage else { return }
      let rect = scroll.documentVisibleRect
      let center = CGPoint(
        x: rect.midX / max(1, image.size.width), y: rect.midY / max(1, image.size.height))
      let scale = scroll.magnification
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        if abs(self.viewport.scale - scale) > 0.0001 { self.viewport.scale = scale }
        if abs(self.viewport.center.x - center.x) > 0.001
          || abs(self.viewport.center.y - center.y) > 0.001
        {
          self.viewport.center = center
        }
      }
    }
  }
}
