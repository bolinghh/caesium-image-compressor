## Caesium Image Compressor  [![](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/Lymphatus)

[![Build](https://github.com/Lymphatus/caesium-image-compressor/actions/workflows/build-qt.yml/badge.svg)](https://github.com/Lymphatus/caesium-image-compressor/actions/workflows/build-qt.yml)

Try it directly on browser at [caesium.app](https://caesium.app)

> [!NOTE]
> I'm starting to work to the v3.0.0 version to address a lot of suggestions, feature requests and general improvements. You can participate in the development in this [discussion thread](https://github.com/Lymphatus/caesium-image-compressor/issues/334).

###### v2.8.5

![caesium_screenshot_280](https://github.com/user-attachments/assets/e5a6510a-58c5-4349-8563-f4e3ee84d5a0)

### Special Thanks

<a href="https://github.com/7eventech77"><img src="https://github.com/7eventech77.png" width="30px" alt="7eventech77" style="border-radius: 100%;" /></a>
<a href="https://github.com/ClearRabbit"><img src="https://github.com/ClearRabbit.png" width="30px" alt="ClearRabbit" style="border-radius: 100%;" /></a>
<a href="https://github.com/LushawnDev"><img src="https://github.com/LushawnDev.png" width="30px" alt="LushawnDev" style="border-radius: 100%;" /></a>
<a href="https://github.com/yannkost"><img src="https://github.com/yannkost.png" width="30px" alt="yannkost" style="border-radius: 100%;" /></a>
<a href="https://github.com/yannkost"><img src="https://github.com/stamminator.png" width="30px" alt="stamminator" style="border-radius: 100%;" /></a>
<a href="https://github.com/justBernhard"><img src="https://github.com/justBernhard.png" width="30px" alt="justBernhard" style="border-radius: 100%;" /></a>

----------

### What is it for

Caesium is an image compression software that helps you store, send and share digital pictures, supporting JPG, PNG, WebP and TIFF formats. macOS builds additionally support AVIF and HEIC/HEIF input and AVIF/HEIC output.
You can quickly reduce the file size (and resolution, if you want) by preserving the overall quality of the image.

### Supported Platforms

- **Windows**: 10 (build 1809 or later) (use old version v1.x for Windows 7 or
  8 - [link](https://www.fosshub.com/Caesium-Image-Compressor-old.html))
- **MacOS**: 12+
- **Linux**: tested on Ubuntu 22.04 and Manjaro

Note: only 64bit versions are supported

AVIF/HEIC support currently targets 8-bit SDR static images. HDR, gain maps, depth maps,
animated sequences and additional photos in one container are rejected explicitly. Ordinary thumbnails are allowed.
Quality, target-size and actual lossless encoding are supported; an unattainable size target is reported.
JPEG output composites transparency onto white.

### Installation

Head to the [releases' page](https://github.com/Lymphatus/caesium-image-compressor/releases) for the available
downloads.

- **Windows**: installer and portable versions are available
- **MacOS**: DMG package
- **Linux**: compile the source code yourself, or download binary
  from [third-party build](https://github.com/larygwil/caesium-image-compressor/releases)

Note that the main branch can contain unstable code. If you want to build on a stable version, use a tagged version.

### Troubleshooting and/or feature request

Please open an [issue](https://github.com/Lymphatus/caesium-image-compressor/issues).

### Build from source

##### Requirements

- [Rust](https://www.rust-lang.org/tools/install): required to
  compile [libcaesium](https://github.com/Lymphatus/libcaesium). Make sure you have `cargo` executable on you `$PATH`
- CMake 3.19 or later and a C++17 compiler
- [Qt6 SDK](https://www.qt.io/download/): active Windows and Ubuntu CI builds use 6.8.2 (open source),
  with `qtimageformats`. Include LinguistTools and Qt Test for the default test build.
  Qt6 is required. Use `-DBUILD_TESTING=OFF` to omit Qt Test.
- [Sparkle](https://sparkle-project.org/): macOS only, version 1.27.1.
- macOS AVIF/HEIC dependencies: use the pinned source build below; details and licenses are in [third-party notes](docs/third-party.md).

#### Build

##### Step 0 (macOS Only)

Build the pinned codecs for arm64 and macOS 12, and extract Sparkle locally:

```sh
python3 scripts/build-macos-deps.py
curl --fail --location https://github.com/sparkle-project/Sparkle/releases/download/1.27.1/Sparkle-1.27.1.tar.xz -o build/Sparkle.tar.xz
echo '20d729f8ca4d07911da31fe0296880cd3176b71738deaf2b7f8de2d96cf63f4e  build/Sparkle.tar.xz' | shasum -a 256 -c -
mkdir -p build/sparkle
tar -xf build/Sparkle.tar.xz -C build/sparkle
```

`ENABLE_HEIF` defaults on for macOS and off elsewhere. For an existing-format-only build,
use `-DENABLE_HEIF=OFF`. To intentionally omit Sparkle, use `-DENABLE_MACOS_UPDATER=OFF`.

##### Step 1

You need to configure CMake first and the command is slightly different for all the platforms:
Change the path in variables with the correct directories of the requirements.

###### Windows

```
cmake -B build_dir -DCMAKE_PREFIX_PATH=/path/to/Qt/version -G "MinGW Makefiles"
```

###### MacOS

```
cmake -S . -B build_dir -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_PREFIX_PATH="/path/to/Qt/6.8.2/macos;$PWD/build/dependencies/install" -DSPARKLE_FRAMEWORK="$PWD/build/sparkle/Sparkle.framework" -DSPARKLE_INCLUDE_DIR="$PWD/build/sparkle/Sparkle.framework/Headers"
```

###### Linux

Make sure you have all the requirements installed with you own package manager

```
cmake -B build_dir -DCMAKE_PREFIX_PATH=/path/to/Qt/version/gcc_64
```

##### Step 2

Then you can build with

```
cmake --build build_dir --config Release --target caesium_image_compressor
```

#### Tests and checks

After configuring with the platform-specific command above:

```sh
cmake --build build_dir --config Release --target CsTests
ctest --test-dir build_dir -C Release --output-on-failure
```

CTest is enabled at the build root. The suite covers output recovery, cancellation, parameter migration,
telemetry, import deduplication and codec behavior. macOS also runs actual Qt widget flows and generates
screenshots under the build's `test-artifacts` directory. CI builds and tests Windows, Ubuntu and macOS arm64;
only macOS enables the new codecs by default. C++ formatting is defined by `.clang-format`.

For a local self-contained macOS app (choose a fresh output directory):

```sh
python3 scripts/package-macos.py 'build_dir/Caesium Image Compressor.app' --qt /path/to/Qt/6.8.2/macos --library-path build/dependencies/install/lib --library-path build_dir/libcaesium-prefix/src/libcaesium/target/release
```

This copies runtime dependencies and uses ad-hoc signing for local execution; it does not publish,
notarize or Developer ID sign a release. Windows `setup.iss` still expects a prepared package tree.

For module responsibilities, data flow, compatibility boundaries, and known uncertainties,
see [architecture notes](docs/architecture.md). Agents should also read [AGENTS.md](AGENTS.md).

### Native macOS interface

An optional SwiftUI/AppKit frontend is available alongside the retained Qt interface.
See the [native macOS build, rollback and verification guide](docs/macos-native-ui.md).
Enable it with `-DENABLE_MACOS_NATIVE_UI=ON` in a fresh Ninja or Xcode build directory.

### Languages and translations

The 1.0 version of Caesium had a lot of community made translations, but this 2.0 release has a whole new set of strings
and no old translations can be used anymore.
Caesium 2.0 is currently available in:

| Language                                                                           | Progress |
|------------------------------------------------------------------------------------|----------|
| <img src="https://flagcdn.com/48x36/eg.png" width="24" height="18" alt="EG"> ar_EG | 77%      |
| <img src="https://flagcdn.com/48x36/de.png" width="24" height="18" alt="DE"> de_DE | 72%      |
| <img src="https://flagcdn.com/48x36/gr.png" width="24" height="18" alt="GR"> el_GR | 69%      |
| <img src="https://flagcdn.com/48x36/us.png" width="24" height="18" alt="US"> en_US | 100%     |
| <img src="https://flagcdn.com/48x36/es.png" width="24" height="18" alt="ES"> es_ES | 67%      |
| <img src="https://flagcdn.com/48x36/ir.png" width="24" height="18" alt="IR"> fa_IR | 98%      |
| <img src="https://flagcdn.com/48x36/fi.png" width="24" height="18" alt="FI"> fi_FI | 72%      |
| <img src="https://flagcdn.com/48x36/fr.png" width="24" height="18" alt="FR"> fr_FR | 68%      |
| <img src="https://flagcdn.com/48x36/in.png" width="24" height="18" alt="IN"> hi_IN | 72%      |
| <img src="https://flagcdn.com/48x36/id.png" width="24" height="18" alt="ID"> id_ID | 69%      |
| <img src="https://flagcdn.com/48x36/it.png" width="24" height="18" alt="IT"> it_IT | 100%     |
| <img src="https://flagcdn.com/48x36/jp.png" width="24" height="18" alt="JP"> ja_JP | 97%      |
| <img src="https://flagcdn.com/48x36/pl.png" width="24" height="18" alt="PL"> pl_PL | 69%      |
| <img src="https://flagcdn.com/48x36/br.png" width="24" height="18" alt="BR"> pt_BR | 95%      |
| <img src="https://flagcdn.com/48x36/ru.png" width="24" height="18" alt="RU"> ru_RU | 97%      |
| <img src="https://flagcdn.com/48x36/sk.png" width="24" height="18" alt="SK"> sk_SK | 68%      |
| <img src="https://flagcdn.com/48x36/tr.png" width="24" height="18" alt="TR"> tr_TR | 97%      |
| <img src="https://flagcdn.com/48x36/cn.png" width="24" height="18" alt="CN"> zh_CN | 100%     |
| <img src="https://flagcdn.com/48x36/tw.png" width="24" height="18" alt="TW"> zh_TW | 100%     |
| <img src="https://flagcdn.com/48x36/ro.png" width="24" height="18" alt="TW"> ro_RO | 98%      |

#### How to contribute with your translation

You can help translate by opening the `resources/i18n/caesium_en_US.ts` with QtLinguist or any XML editor. Rename it to
your language (e.g. `caesium_it_IT.ts`) and translate all the sentences. Register the locale and label in
`resources/locales.json`; append new entries to preserve legacy language indexes. CMake generates the translation resource list from this manifest. Then you can start a pull request with your
translated file.
See [this pull request](https://github.com/Lymphatus/caesium-image-compressor/pull/106) as an example.
Thanks to all the people who contributed.
