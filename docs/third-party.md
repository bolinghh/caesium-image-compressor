# Codec dependencies and distribution

The application remains GPL-3.0. Existing formats use libcaesium 0.17.4 through its unchanged C ABI.

macOS AVIF/HEIC builds use these dependencies, pinned in [the dependency lock](../scripts/macos-deps.lock.json):

| Dependency | Version | Purpose | Upstream license |
| --- | --- | --- | --- |
| libheif | 1.23.6 | HEIF/AVIF container, image transforms, metadata and codec integration | LGPL-3.0-or-later |
| libde265 | 1.1.3 | HEIC decoding | LGPL-3.0-or-later |
| x265 | 4.3, 8-bit build | HEIC encoding | GPL-2.0-or-later |
| libaom | 3.15.2 | AVIF encoding and decoding | BSD-2-Clause and upstream patent license |
| Exiv2 | 0.28.9 | EXIF/XMP conversion and normalization | GPL-2.0-or-later |
| Sparkle | 1.27.1 | Existing macOS updater | Upstream permissive license in release archive |

Qt 6.8.2 is used under its applicable open-source licenses. Consult the exact upstream source license files for authoritative terms and attribution. When distributing binaries, include required notices and corresponding source/build information; the local packaging script is not a release-compliance or publication workflow.

The lock contains SHA-256 values for archives and exact Git revisions for source checkouts. Codecs are built into libheif rather than loaded from external plugin directories. Exiv2 is built without network support, NLS, Brotli, or inih dependencies. The source build targets macOS 12 and arm64; Homebrew bottles are not suitable substitutes for verifying that deployment target.

The packaging script copies available dependency licenses into `Contents/Resources/ThirdPartyLicenses` and uses ad-hoc signing only to make rewritten Apple Silicon binaries executable locally. Developer ID signing, notarization, DMG creation, and publication are not performed.
