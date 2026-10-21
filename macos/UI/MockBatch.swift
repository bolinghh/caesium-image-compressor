import AppKit
import SwiftUI

// Preview data never starts Qt tasks, network requests, updates, or writes user settings.
@MainActor
enum MockBatch {
  static func make() -> BatchStore {
    let store = BatchStore(session: nil)
    store.settings = [
      "compression_options/compression/jpeg_quality": 80,
      "compression_options/compression/png_quality": 80,
      "compression_options/compression/webp_quality": 60,
      "compression_options/compression/avif_quality": 80,
      "compression_options/compression/heic_quality": 80,
      "compression_options/compression/png_optimization_level": 3,
      "compression_options/compression/tiff_method": 1,
      "compression_options/compression/tiff_deflate_level": 2,
      "compression_options/compression/keep_metadata": true,
      "compression_options/output/format_id": "same",
      "compression_options/output/skip_if_bigger": true,
      "mainwindow/previews_visible": true, "macos/inspector_visible": true,
      "application/version": "2.8.5", "application/max_threads": 8,
    ]
    store.items = [
      [
        "id": "one", "name": "Coastal landscape.jpg", "path": "/Mock/Coastal landscape.jpg",
        "bytes": 8_240_000, "outputBytes": 2_450_000, "resolution": "4032 × 3024", "saved": 70.3,
        "status": 2, "detail": "Compressed",
      ],
      [
        "id": "two", "name": "Product photograph with a very long descriptive filename.png",
        "bytes": 16_800_000, "outputBytes": 16_800_000, "resolution": "6000 × 4000", "saved": 0,
        "status": 0, "detail": "Ready",
      ],
      [
        "id": "three", "name": "Portrait.heic", "bytes": 3_200_000, "outputBytes": 3_200_000,
        "resolution": "3024 × 4032", "saved": 0, "status": 3, "detail": "Input file does not exist",
      ],
    ].map(BatchImage.init)
    return store
  }
}

struct WorkbenchPreviews: PreviewProvider {
  static var previews: some View {
    Group {
      BatchView(store: MockBatch.make()).frame(width: 1120, height: 780).preferredColorScheme(
        .light)
      BatchView(store: MockBatch.make()).frame(width: 1120, height: 780).preferredColorScheme(.dark)
      BatchView(store: BatchStore(session: nil)).frame(width: 600, height: 480)
      SettingsView(store: MockBatch.make())
    }
  }
}
