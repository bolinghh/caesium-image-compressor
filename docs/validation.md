# Implementation validation — 2026-10-16

This records checks actually run for the reliability and AVIF/HEIC changes. Architecture and dependency choices are described in [architecture.md](architecture.md) and [third-party.md](third-party.md).

## Environment and results

Host: macOS 27.2, Apple Silicon; Qt 6.8.2; Release builds using C++17. The full build uses libcaesium 0.17.4 and the pinned dependencies in [macos-deps.lock.json](../scripts/macos-deps.lock.json).

| Check | Actual result |
| --- | --- |
| Full application build, including Sparkle and modern codecs | Passed |
| `ctest --test-dir build --output-on-failure` | 2/2 executables passed; ImporterTests 3, ReliabilityTests 15, UiTests 3 QtTest results, including setup/cleanup; no failures or skips |
| Native widget run with `QT_QPA_PLATFORM=cocoa build/tests/UiTests` | 3 passed, no failures or skips |
| Application build with `ENABLE_HEIF=OFF`, `ENABLE_MACOS_UPDATER=OFF` | Passed on the same macOS host |
| `ctest --test-dir build-legacy --output-on-failure` | 2/2 executables passed; three modern-codec cases skipped as intended |
| Python script syntax, locale manifest and translation XML parsing | Passed |
| `git diff --check` | Passed |
| External libcaesium source checkout | No source changes |

QtTest totals include initialization and cleanup; they are not counts of independent acceptance scenarios.

## Coverage by implementation stage

1. **Output safety:** tests cover batch naming, case collisions, occupied targets, input reservations, replacement failure, successful rollback and failed recovery retaining a backup. File-operation injection exercises failure paths without relying on actual disk exhaustion. Temporary outputs are decoded before commit. Trash failure does not fall back to permanent deletion.
2. **Task lifecycle:** tests cover cancellation and unexecuted work. Native widget tests close a window after processing has started and wait for task shutdown; workers return results to the main thread.
3. **Results:** batch results distinguish failed, skipped, canceled and unexecuted items. Completion actions are guarded against cancellation, failures and warnings. The tests do not execute real shutdown or sleep commands.
4. **Statistics:** whitelist assertions and a loopback HTTP server verify request structure and exclusion of sensitive path/suffix values. No production statistics service was contacted by these tests.
5. **Build assurance:** both CTest executables run in Release. Windows, Ubuntu and macOS arm64 CI definitions now build and execute tests; remote CI has not been run in this session.
6. **Parameters/cache:** tests verify bounds, stable format identifiers, legacy index migration and cache invalidation when input metadata or processing parameters change.
7. **Import/preview:** tests exercise asynchronous import and duplicate suppression. Native widget tests exercise repeated preview requests, successful compression, selection/removal and closing during processing.
8. **Maintenance:** the locale manifest and TS files parse, both codec-enabled and disabled builds pass, and model selection/removal is exercised through real widgets. Platform installation paths were reviewed; no Linux installation was performed.

## Format and UI checks

Generated fixtures cover AVIF and HEIC encoding/decoding, their conversions to and from JPEG/PNG/WebP/TIFF, resize dimensions, content detection, alpha, ICC, EXIF/XMP retention/removal, orientation normalization and target-size-missed status. Lossless fixtures compare decoded RGBA pixels exactly. Rejection fixtures cover corrupt data, high bit depth, HDR transfer characteristics and multiple photos. These fixtures do not establish coverage of every camera/vendor variant.

The native UI run covers English/light and Chinese/dark themes, window resizing and both original/compressed previews. Screenshots are saved by the tests to `build/test-artifacts/window-1.png` and `window-2.png`. An existing PNG icon emits a non-fatal ICC-profile warning; no test failure resulted.

## Local application package

The final local review artifact is `build/review-app/Caesium Image Compressor.app`, produced by [package-macos.py](../scripts/package-macos.py). Required codec libraries, Qt and Sparkle are bundled, with available third-party license files. This is an ad-hoc-signed local artifact.

The packaged executable completed `--verify-codecs` with an otherwise cleared environment (`env -i`, system-only `PATH`, disposable `HOME`). It successfully encoded and decoded JPEG, PNG, WebP, TIFF, AVIF and HEIC. Dynamic-loader output contained no Homebrew, temporary Qt/codec SDK or build dependency installation paths. `codesign --verify --deep --strict` passed. The five source-built codec/metadata dylibs declare macOS 12.0 as their minimum OS.

## Remaining verification limits

- Windows and Linux were not built or run locally; CI configuration is not a completed CI result. Modern codecs remain disabled by default there.
- macOS 12 was not available for an actual launch. The deployment target and Mach-O headers alone do not prove runtime compatibility.
- The cleared-environment package check ran on the development host, not a separate clean machine.
- Real iPhone HDR/gain-map collections, animation variants, unusual auxiliary images and missing-encoder runtime environments need a broader fixture corpus. Explicit rejection/capability checks exist, but not every rejection branch has an independent fixture.
- Injected file failures do not replace physical full-disk, network-volume, power-loss or OS trash-service tests. Recovery backups are deliberately retained when restoration fails.
- Native UI verification is targeted, not an exhaustive accessibility or display-scale review. Other translations retain their existing coverage.
- Developer ID signing, notarization, distribution and publication were not performed. No commit was created.
