# Native macOS UI

The optional SwiftUI/AppKit frontend retains the Qt/C++ services, codecs, QSettings compatibility and macOS 12 deployment target. Other platforms keep the Qt interface.

## Build and rollback

Prepare Qt, codecs and Sparkle as described in README, plus Swift 5.9 or later (Xcode 15 or later). Use a fresh Ninja or Xcode CMake build directory:

```sh
cmake -S . -B build-native -G Ninja \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PREFIX_PATH="/path/to/Qt/6.8.2/macos;$PWD/build/dependencies/install" \
  -DSPARKLE_FRAMEWORK="$PWD/build/sparkle/Sparkle.framework" \
  -DSPARKLE_INCLUDE_DIR="$PWD/build/sparkle/Sparkle.framework/Headers" \
  -DENABLE_MACOS_NATIVE_UI=ON
cmake --build build-native --config Release
```

The option defaults OFF, preserving existing Qt build commands. Enabled builds open the native frontend; `--qt-ui` selects the retained Qt interface. `--native-ui-preview` shows mock data without external services or setting writes. Build one architecture at a time; a universal native bundle is not validated.

The Swift sources contain a PreviewProvider. Interactive Xcode canvas previews require a full Xcode installation and are separate from command-line build validation.

## Boundaries

| Files | Responsibility |
| --- | --- |
| `macos/UI/NativeWindow.swift` | Window, menus, status item, settings window and command routing |
| `macos/UI/BatchView.swift` | Table, parameter inspectors, progress, comparison and shared layout constants |
| `macos/UI/BatchStore.swift` | Main-actor state, selection, settings bindings and user commands |
| `macos/UI/LinkedImageView.swift` | AppKit viewports with linked magnification and normalized center |
| `macos/UI/AuxiliaryViews.swift` | Settings, advanced import, about and usage details |
| `macos/Bridge/NativeSession.*` | Foundation boundary, Qt task ownership, settings and results |
| `macos/Bridge/NativeDefaults.h` | Existing setting names/defaults; no second settings store |
| `macos/Bridge/NativeBootstrap.mm` | SwiftUI launch under Qt's application/event-loop ownership |

The approved visual contract is [macos/DESIGN.md](../macos/DESIGN.md).

Swift receives value snapshots and images, never QModelIndex, CImage pointers or worker-owned mutable objects. Stable IDs survive sorting; the bridge preserves original input order for destination planning and retry. Main-thread completion handlers apply results before unlocking commands; a worker future finishing alone is insufficient. Snapshot publication is coalesced.

Import uses ImportTask. OutputFiles plans destinations in a worker; CompressionTask's `startPlanned` accepts that input-order plan. The existing `start` API remains. Compression keeps worker-owned CImage copies, codec behavior, temporary outputs, commit/recovery rules and cancellation tokens.

Previews debounce rapid requests, reject stale generations and allow at most one running decode/encode. Compression asynchronously drains active previews before moving/replacing originals. CGImage owns its copied pixel data and preserves decoded ICC information; AppKit objects are created on the main thread.

Closing locks commands, requests cancellation and drains all tasks before settings sync, cache cleanup and Qt shutdown. A running codec is not forcibly interrupted. The normal close path does not wait synchronously on the main thread.

Settings retain application identity, keys, language-index migration, format IDs, percentage/aspect linkage, TIFF slider scaling and date-selection state. AppKit window geometry has a separate autosave name; Qt geometry remains untouched. The old Native/Fusion choice is preserved for Qt; native controls use the existing Auto/Light/Dark preference. QM translations are looked up explicitly; native-only text without a translation falls back to English.

Existing usage reporting, opt-out, completion-action guards and Sparkle are retained. Mock/test sessions disable external services. Tests do not execute sleep/shutdown or install updates.

Completion notifications use UserNotifications when system permission is granted. Settings provides an explicit permission request button; neither startup nor tests prompt for permission. Clicking a notification reveals the main window. Delivery and authorization still need manual system-level acceptance.

## Verification and packaging

```sh
ctest --test-dir build-native -C Release --output-on-failure
QT_QPA_PLATFORM=cocoa build-native/macos/NativeUiTests
```

NativeBridgeTests uses isolated settings and disposable inputs to check migration, deduplication, preview generations, compression, stable-ID removal, failed-only retry, overwrite predicates and close/cancel. Existing core and Qt widget tests remain enabled.

NativeUiTests exercises native window/controller/store paths with real C++ processing and writes PNG captures to `build-native/test-artifacts`. It requires WindowServer. Add `-DENABLE_MACOS_NATIVE_GUI_TESTS=ON` to register it with CTest on a GUI-capable host. Screenshots do not establish full mouse/keyboard/VoiceOver acceptance.

Use the existing packaging script with the new app path and a fresh output directory. It creates a local ad-hoc-signed bundle. Release signing/notarization, independent clean-machine launch, macOS 12 hardware, Intel/universal builds and the Xcode preview canvas need separate validation.
