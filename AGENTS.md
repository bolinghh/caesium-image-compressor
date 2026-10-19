# Development guide for agents

## Start here

- This is a C++17 / Qt Widgets desktop application, built with CMake. There is no Node.js application or package manager workflow.
- Read [README.md](README.md) for platform setup and [docs/architecture.md](docs/architecture.md) for module boundaries, data flow, and known uncertainties.
- Start with the relevant entry point; do not read all translations, icons, or generated files to understand a change.
- Application entry: `src/main.cpp`. UI coordination: `src/MainWindow.cpp`. Forms: `views/*.ui`. Single-image processing: `src/models/CImage.cpp`.

## Build and checks

Configure using the platform-specific command in README. The active Windows and Ubuntu CI jobs use Qt 6.8.2; macOS arm64 CI also builds the pinned codecs. Qt6 is required.

```sh
cmake --build build_dir --config Release --target caesium_image_compressor
cmake --build build_dir --config Release --target CsTests
ctest --test-dir build_dir -C Release --output-on-failure
```

- CTest is enabled at the root. `BUILD_TESTING=OFF` omits test dependencies. Reliability and real-widget tests use assertions that remain active in Release.
- Match checks to the change. For image processing, use disposable fixtures and verify output files, dimensions, status, and relevant metadata. Include overwrite and failure cases when those paths change.
- For UI changes, run the application and inspect resizing, applicable themes, translations, and preview interactions. State explicitly when visual verification was not performed.
- Use `.clang-format` for C++ formatting and keep unrelated formatting out of a change. There is no configured CI formatting check.

## Compatibility boundaries

- Keep `src/include/libcaesium.h` compatible with the external library version in `libcaesium.conf`. Check struct layout, enum values, and parameter semantics when upgrading.
- Preserve the temporary-output, overwrite, skip-if-bigger, and original-file handling in `CImage::compress`. Test changes with disposable originals, including failed output writes.
- Treat QSettings keys and stored enum/combobox indexes as persisted user data. Renaming keys or reordering values needs an explicit compatibility strategy. Language settings also accept legacy numeric indexes.
- When adding a compression option, trace the UI, settings read/write, `CompressionOptions`, normalization, codec parameters, telemetry whitelist and preview-cache key together.
- Preserve EXIF orientation handling when changing resizing or metadata behavior.
- Keep `.ui` object names aligned with `on_<object>_<signal>` slots and explicit signal connections. Update the Designer custom-widget declarations when changing promoted controls.
- Map proxy indexes to source indexes before accessing image-model items. Keep model/item ownership and worker lifetimes explicit; cancellation does not interrupt a running C ABI call.
- For a new language, add the TS file and append its locale/label to `resources/locales.json`; CMake and `LanguageManager` consume that manifest; preserve legacy language-index compatibility.
- Keep platform-specific code behind the existing CMake and `Q_OS_*` conditions. Do not infer platform support from a successful build on another OS.
- Do not add credentials to source or logs. Network statistics and platform update checks are separate from local image compression.

## Scope and reporting

- Keep fixes focused; known issues in the architecture notes are context, not automatic authorization to change unrelated behavior.
- Report what changed, checks actually performed, and remaining uncertainty. Do not claim a build, test, or visual review succeeded unless it was run.
