# Architecture and maintenance notes

This map describes the working-tree reliability and AVIF/HEIC changes. See [README](../README.md) for setup, [AGENTS](../AGENTS.md) for development rules, and [third-party dependencies](third-party.md) for codec provenance.

## Modules and flow

An optional macOS SwiftUI/AppKit frontend lives in `macos/`; see [its architecture and validation guide](macos-native-ui.md). It reuses these services through an Objective-C++ adapter, retains Qt's runtime/event loop and keeps the original Qt interface as a rollback path. `ENABLE_MACOS_NATIVE_UI` defaults OFF.

| Entry | Responsibility |
| --- | --- |
| `src/main.cpp`, `src/utils/Theme.cpp` | Application identity, logging, theme and window startup |
| `src/MainWindow.cpp`, `views/` | Qt Widgets forms, settings restoration and UI coordination |
| `src/services/Importer.*`, `ImportTask.*` | Format filters, directory scanning, background metadata loading, deduplication and streaming batches |
| `src/models/CImage.*` | Image information, per-image processing, output validation and file dates |
| `src/services/OutputFiles.*` | Whole-batch destination planning, collision numbering, backup/commit/restore |
| `src/services/CompressionTask.*` | Worker snapshots, atomic cancellation and batch outcome |
| `src/services/CompressionParameters.*` | Parameter bounds, format-index migration and preview-cache identity |
| `src/services/ImageCodec.*` | Content detection, decoding, capabilities, modern encoding and metadata conversion |
| `src/models/CImageTreeModel.*`, `CImageTreeItem.*` | Main-thread image state and owned list entries |
| `src/models/CImageSortFilterProxyModel.*` | Sorting; selections must map back to source rows |
| `src/widgets/`, `src/delegates/`, `src/filters/` | Reusable drag/drop, linked preview, loading, rich text and scroll handling |
| `src/network/NetworkOperations.*` | Installation registration and aggregate usage reports |
| `src/updater/`, `src/utils/PostCompressionActions.*` | Updates and post-batch platform operations |
| `tests/` | Importer, reliability, format, network and real-widget regression checks |

```text
File chooser / drop / command-line / advanced import
  → ImportTask scans and decodes in a worker
  → batches of image snapshots → main-thread model → sorting proxy → list

UI → normalized CompressionOptions → OutputFiles batch plan
  → CompressionTask workers own image copies
  → CImage → libcaesium or ImageCodec → temporary output → validate → commit
  → resultReadyAt → main-thread model update → batch outcome

Preview selection → request number + image/option snapshot
  → worker produces QImage → main thread produces QPixmap
  → stale request results are ignored
```

`MainWindow` still coordinates the forms; no web router or separate state framework is used. Worker tasks do not access QWidget objects or mutate live model images. Model entries can be removed without freeing worker-owned copies. Closing stops new work, requests cancellation, and waits for active work before releasing models or clearing previews. A running codec call is not forcibly interrupted.

## Output invariants

- Destinations are planned before starting workers, in input order. Canonical parent paths, Unicode normalization and platform case-folding prevent collisions with inputs, existing destinations and other batch outputs.
- Ordinary conflicts use `_2`, `_3`, etc. An explicitly requested same-folder, empty-suffix overwrite can replace only that item's own input and still requires confirmation.
- Temporary output is created in the destination directory and decoded before commit. New destinations cannot overwrite existing files.
- Original replacement first creates a unique same-directory backup. Failed commit restores it; failed restoration leaves the backup and reports its path. Original removal happens only after output succeeds. Failed trashing never falls back to permanent deletion.
- A larger output under skip-if-bigger leaves the original in place and reports a normal skip. Warnings such as failed original removal or an unattainable target size prevent automatic completion actions.

`FileOperations` provides an internal test seam for deterministic rename/remove failures. `CImageTreeItem` owns its image and children; removing a row now deletes the owned entry.

## Parameters and persistence

QSettings remains the persistence layer. Controls collect an immutable normalized options snapshot for each job. Stable output IDs (`same`, `jpg`, `png`, `webp`, `tiff`, `avif`, `heic`) replace persisted combobox positions, with migration of legacy indexes 0–4. Disabled formats fall back to the existing-format UI without changing the ID during initial restoration.

Preview cache version 2 includes canonical input path, byte size, modification time and normalized pixel-processing options. Destination paths, suffixes and window state do not affect cache identity. Cache files are under the application's `previews-v2` cache directory. A source changed without changing either size or modification time is not detected; content hashing is not currently performed.

Legacy language numeric indexes keep their original meaning. Korean, Romanian and Persian are appended to the single `resources/locales.json` manifest, which drives runtime choices and generated build resources. CMake validates uniqueness and source-file presence. The translation build compiles existing TS files without running lupdate; builds must not rewrite translation sources. Advanced-import filename-pattern preferences migrate the old misspelling while retaining compatibility.

## Formats and color

Existing JPEG, PNG, WebP and TIFF compression continues through pinned libcaesium 0.17.4, without changing its C ABI. HEIC/HEIF and AVIF content is handled by libheif, independently of Qt image plugins. Modern input or output uses decoded pixels directly; JPEG is not used as an intermediate.

Modern support defaults on for macOS and off elsewhere (`ENABLE_HEIF`). Both decode and encode capabilities are checked. Each new format has quality 0–100, default 80. Lossless uses the encoder's actual lossless capability, RGB identity matrix and 4:4:4 chroma. Size mode searches quality with at most 12 encoding attempts and explicitly warns when only the smallest oversized result is available.

The first version supports 8-bit SDR static primary images, transparency and ICC profiles. It rejects high bit depths, PQ/HLG HDR, auxiliary/depth/gain-map images, sequences and multiple top-level photos. Thumbnails are allowed. Wide-gamut images without an interpretable ICC profile are rejected rather than silently assigned sRGB. JPEG conversion composites transparency onto white.

EXIF/XMP can be preserved or removed independently of color information. Orientation is normalized after image transforms; pixel-dimension metadata is updated after resizing. The decoder retains libheif safety limits and additionally rejects decoded dimensions above the application's memory bound. Unsupported content becomes a visible import or processing error.

## Results, networking and platform behavior

`BatchOutcome` records successful, failed, warning, skipped and unexecuted items plus cancellation. Automatic close/sleep/shutdown actions require a non-canceled batch without failures or unexecuted work. Failed-only retry continues to select error items.

Usage reporting retains its existing opt-out setting and endpoint/wire envelope. The options payload is a whitelist of numeric processing parameters and stable format ID; local paths, names, suffixes and filters are excluded. Tokens and full server replies are not logged. The endpoint can be injected for loopback-only network tests; normal defaults still use `https://caesium.app/api/v1` or the existing local endpoint override.

macOS minimum version is declared as 12 in CMake and Info.plist. Qt6 is required. Sparkle integration is retained, with an explicit `ENABLE_MACOS_UPDATER=OFF` option for builds that intentionally omit it. Windows WinSparkle and portable-update behavior remain. Linux installs respect the installation prefix and do not create `/usr/lib` symlinks.

## Build and validation boundaries

CTest is enabled at the root under `BUILD_TESTING`; tests and application use C++17. Windows and Ubuntu CI build existing formats and run tests; macOS arm64 CI also builds pinned codecs, runs real-widget tests, and prepares a self-contained local bundle. CI configuration must still be executed by its respective hosts before claiming cross-platform verification.

Local validation results and remaining limitations are recorded in [validation notes](validation.md). A declared macOS 12 deployment target is not proof of a launch on macOS 12. Release signing, notarization and publication are outside this change.
