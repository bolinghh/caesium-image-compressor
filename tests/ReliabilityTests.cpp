#include "ReliabilityTests.h"
#include "services/CompressionParameters.h"
#include "services/CompressionTask.h"
#include "services/ImageCodec.h"
#include "services/ImportTask.h"
#include "services/OutputFiles.h"
#include <QColorSpace>
#include <cstring>
#include <stdexcept>
#include <QSettings>
#include <QJsonDocument>
#include <QTcpServer>
#include <QTcpSocket>
#include "network/NetworkOperations.h"
#ifdef CAESIUM_WITH_HEIF
#include <libheif/heif.h>
#include <exiv2/exiv2.hpp>
#endif
#include <QTemporaryDir>

namespace {
void write(const QString& path, const QByteArray& data)
{
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write(data), data.size());
}
QByteArray read(const QString& path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return file.readAll();
}
QString fixture(const QString& directory, const QString& name = "input.png")
{
    QImage image(48, 32, QImage::Format_RGBA8888);
    image.fill(QColor(20, 90, 170, 100));
    image.setColorSpace(QColorSpace::SRgb);
    const QString path = directory + '/' + name;
    if (!image.save(path)) return {};
    return path;
}
CompressionOptions options(const QString& directory)
{
    CompressionOptions o {};
    o.outputPath = directory;
    o.jpegQuality = o.pngQuality = o.webpQuality = 80;
    o.avifQuality = o.heicQuality = 80;
    o.maxOutputSize = { MAX_OUTPUT_KB, 100 };
    return CompressionParameters::normalize(o);
}
}

void ReliabilityTests::outputPlanning()
{
    QTemporaryDir root;
    QDir().mkpath(root.path() + "/one");
    QDir().mkpath(root.path() + "/two");
    auto first = fixture(root.path() + "/one");
    auto second = fixture(root.path() + "/two");
    const auto o = options(root.path());
    auto outputs = OutputFiles::plan({ first, second }, o);
    QCOMPARE(outputs[0], root.path() + "/input.png");
    QCOMPARE(outputs[1], root.path() + "/input_2.png");
    write(outputs[0], "existing");
    outputs = OutputFiles::plan({ first, second }, o);
    QVERIFY(outputs[0] != root.path() + "/input.png");
    QVERIFY(outputs[0] != outputs[1]);
    auto overwrite = o;
    overwrite.sameFolderAsInput = true;
    QCOMPARE(OutputFiles::plan({ first }, overwrite)[0], first);
}

void ReliabilityTests::failedReplacementRestoresOriginal()
{
    QTemporaryDir root;
    const auto destination = root.filePath("original");
    const auto temporary = root.filePath("temporary");
    write(destination, "original"); write(temporary, "replacement");
    auto operations = FileOperations::native();
    operations.rename = [temporary](const QString& from, const QString& to) {
        return from != temporary && QFile::rename(from, to);
    };
    auto result = OutputFiles::commit(temporary, destination, true, operations);
    QVERIFY(!result.success);
    QCOMPARE(read(destination), QByteArray("original"));
    QVERIFY(result.backup.isEmpty());
    QCOMPARE(read(temporary), QByteArray("replacement"));
}

void ReliabilityTests::failedRecoveryRetainsBackup()
{
    QTemporaryDir root;
    const auto destination = root.filePath("original");
    const auto temporary = root.filePath("temporary");
    write(destination, "original"); write(temporary, "replacement");
    auto operations = FileOperations::native();
    operations.rename = [destination](const QString& from, const QString& to) {
        return from == destination && QFile::rename(from, to);
    };
    auto result = OutputFiles::commit(temporary, destination, true, operations);
    QVERIFY(!result.success);
    QVERIFY(!result.backup.isEmpty());
    QCOMPARE(read(result.backup), QByteArray("original"));
    QVERIFY(result.error.contains(result.backup));
}

void ReliabilityTests::existingOutputIsNeverOverwritten()
{
    QTemporaryDir root;
    auto destination = root.filePath("output");
    auto temporary = root.filePath("temporary");
    write(destination, "existing"); write(temporary, "new");
    QVERIFY(!OutputFiles::commit(temporary, destination, false).success);
    QCOMPARE(read(destination), QByteArray("existing"));
    QFile::remove(destination);
    auto denied = FileOperations::native();
    denied.rename = [](const QString&, const QString&) { return false; };
    QVERIFY(!OutputFiles::commit(temporary, destination, false, denied).success);
    QVERIFY(QFileInfo::exists(temporary));
    QVERIFY(OutputFiles::commit(temporary, destination, false).success);
    QCOMPARE(read(destination), QByteArray("new"));
    write(temporary, "replacement");
    auto retain = FileOperations::native();
    retain.remove = [](const QString&) { return false; };
    auto retained = OutputFiles::commit(temporary, destination, true, retain);
    QVERIFY(retained.success);
    QCOMPARE(read(retained.backup), QByteArray("new"));
    QCOMPARE(read(destination), QByteArray("replacement"));
}

void ReliabilityTests::parametersAndCache()
{
    QTemporaryDir root;
    auto input = fixture(root.path());
    auto o = options(root.path());
    o.jpegQuality = -20; o.webpQuality = 300;
    auto normalized = CompressionParameters::normalize(o);
    QCOMPARE(normalized.jpegQuality, 1); QCOMPARE(normalized.webpQuality, 100);
    const auto key = CompressionParameters::cacheKey(input, o);
    o.outputPath = "/different"; o.suffix = "_new";
    QCOMPARE(CompressionParameters::cacheKey(input, o), key);
    o.avifQuality = 10;
    QVERIFY(CompressionParameters::cacheKey(input, o) != key);
    o.avifQuality = 80;
    QFile file(input); QVERIFY(file.open(QIODevice::Append)); file.write("changed"); file.close();
    QVERIFY(CompressionParameters::cacheKey(input, o) != key);
    QSettings settings; settings.clear(); settings.setValue("compression_options/output/format", 3);
    QCOMPARE(CompressionParameters::storedFormatIndex(), 3);
    QCOMPARE(settings.value("compression_options/output/format_id").toString(), QString("webp"));
}

void ReliabilityTests::telemetryHasNoPaths()
{
    QSettings settings; settings.clear();
    settings.setValue("compression_options/output/output_folder", "/private/secret-name");
    settings.setValue("compression_options/output/output_suffix", "secret");
    settings.setValue("compression_options/compression/jpeg_quality", 72);
    const auto json = getCompressionOptionsAsJSON();
    QCOMPARE(json.value("compression/jpeg_quality").toInt(), 72);
    QVERIFY(!QJsonDocument(json).toJson().contains("secret"));
    QVERIFY(!json.contains("output/output_folder"));
}

void ReliabilityTests::canceledBatch()
{
    QTemporaryDir root;
    const auto input = fixture(root.path());
    CImage image(input);
    CompressionTask task;
    QList<std::pair<int, CImage>> work;
    QStringList inputs;
    for (int row = 0; row < 64; ++row) { work.append({ row, image }); inputs << input; }
    task.start(work, options(root.path()), inputs);
    task.cancel();
    task.watcher.waitForFinished();
    QVERIFY(task.outcome().canceled);
    QVERIFY(!task.outcome().allowsCompletionAction());
    BatchOutcome partial; partial.failed = 1; QVERIFY(!partial.allowsCompletionAction());
    BatchOutcome warning; warning.warnings = 1; QVERIFY(!warning.allowsCompletionAction());
}

void ReliabilityTests::asyncImportDeduplicates()
{
    QTemporaryDir root;
    const auto input = fixture(root.path());
    ImportTask task;
    task.start({ input, input, root.path() }, true, {}, {});
    task.watcher.waitForFinished();
    int count = 0;
    for (const auto& batch : task.watcher.future().results()) count += batch.images.size();
    QCOMPARE(count, 1);
}

void ReliabilityTests::legacyCompression()
{
    QTemporaryDir root;
    const auto input = fixture(root.path());
    auto o = options(root.path()); o.suffix = "_compressed";
    CImage image(input);
    QVERIFY2(image.compress(o), qPrintable(image.getFormattedStatus()));
    QVERIFY(QFileInfo::exists(image.getCompressedFullPath()));
    QCOMPARE(ImageCodec::decode(image.getCompressedFullPath()).pixels.size(), QSize(48, 32));
    QVERIFY(QFileInfo::exists(input));
}

void ReliabilityTests::modernFormats()
{
#ifndef CAESIUM_WITH_HEIF
    QSKIP("Modern codecs are disabled for this platform/build");
#else
    QTemporaryDir root;
    const auto input = fixture(root.path());
    const auto decoded = ImageCodec::decode(input);
    for (const auto& format : { QString("avif"), QString("heic") }) {
        QVERIFY2(ImageCodec::canEncode(format), qPrintable(format));
        QString error;
        const QString path = root.filePath("encoded." + format);
        QVERIFY2(ImageCodec::encode(decoded, path, format, 80, false, false, error), qPrintable(error));
        QCOMPARE(ImageCodec::detect(path), format);
        const auto modern = ImageCodec::decode(path);
        QCOMPARE(modern.pixels.size(), decoded.pixels.size());
        QVERIFY(modern.pixels.hasAlphaChannel());
        QVERIFY(modern.pixels.pixelColor(1, 1).alpha() < 200);
        QVERIFY(modern.pixels.colorSpace().isValid());
        for (const auto& output : { QString("jpg"), QString("png"), QString("webp"), QString("tiff"), QString("avif"), QString("heic") }) {
            const auto target = root.filePath(format + "-to-" + output + '.' + output);
            auto o = options(root.path());
            o.resize = true; o.fitTo = FIXED_WIDTH; o.width = 24;
            bool missed = false;
            QVERIFY2(ImageCodec::process(path, target, output, o, error, missed), qPrintable(error));
            QCOMPARE(ImageCodec::decode(target).pixels.size(), QSize(24, 16));
        }
        auto o = options(root.path()); o.compressionMode = SIZE; o.maxOutputSize = { MAX_OUTPUT_BYTES, 1 };
        bool missed = false;
        QVERIFY2(ImageCodec::process(input, root.filePath("size." + format), format, o, error, missed), qPrintable(error));
        QVERIFY(missed);
    }
#endif
}

void ReliabilityTests::localUsageRequest()
{
    QTcpServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost));
    QByteArray received;
    connect(&server, &QTcpServer::newConnection, &server, [&] {
        auto* socket = server.nextPendingConnection();
        connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
            received += socket->readAll();
            if (received.contains("compressionOptions")) {
                socket->write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
                socket->disconnectFromHost();
            }
        });
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
    });
    QSettings settings;
    settings.setValue("access_token", "test-only-token");
    settings.setValue("compression_options/output/output_folder", "/private/hidden-user");
    settings.setValue("compression_options/output/output_suffix", "hidden-suffix");
    NetworkOperations client(QString("http://127.0.0.1:%1/api/v1").arg(server.serverPort()));
    client.sendUsageReport({});
    QTRY_VERIFY_WITH_TIMEOUT(received.contains("compressionOptions"), 5000);
    QVERIFY(received.contains("POST /api/v1/desktopInstallation/summary"));
    QVERIFY(!received.contains("hidden-user"));
    QVERIFY(!received.contains("hidden-suffix"));
}

void ReliabilityTests::unsupportedModernImages()
{
#ifndef CAESIUM_WITH_HEIF
    QSKIP("Modern codecs disabled");
#else
    QTemporaryDir root;
    for (int mode = 0; mode < 3; ++mode) {
        auto* context = heif_context_alloc();
        heif_encoder* encoder = nullptr;
        QCOMPARE(heif_context_get_encoder_for_format(context, heif_compression_AV1, &encoder).code, heif_error_Ok);
        for (int count = 0; count < (mode == 2 ? 2 : 1); ++count) {
            heif_image* image = nullptr;
            const int depth = mode == 0 ? 10 : 8;
            QCOMPARE(heif_image_create(16, 16, heif_colorspace_YCbCr, heif_chroma_420, &image).code, heif_error_Ok);
            for (auto channel : { heif_channel_Y, heif_channel_Cb, heif_channel_Cr }) {
                const int size = channel == heif_channel_Y ? 16 : 8;
                QCOMPARE(heif_image_add_plane(image, channel, size, size, depth).code, heif_error_Ok);
                int stride = 0;
                auto* data = heif_image_get_plane(image, channel, &stride);
                std::memset(data, 0, stride * size);
            }
            if (mode == 1) {
                auto* profile = heif_nclx_color_profile_alloc();
                heif_nclx_color_profile_set_color_primaries(profile, 9);
                heif_nclx_color_profile_set_transfer_characteristics(profile, 16);
                heif_nclx_color_profile_set_matrix_coefficients(profile, 9);
                QCOMPARE(heif_image_set_nclx_color_profile(image, profile).code, heif_error_Ok);
                heif_nclx_color_profile_free(profile);
            }
            heif_image_handle* handle = nullptr;
            auto* encodingOptions = heif_encoding_options_alloc();
            heif_color_profile_nclx* outputProfile = nullptr;
            if (mode == 1) {
                QCOMPARE(heif_image_get_nclx_color_profile(image, &outputProfile).code, heif_error_Ok);
                encodingOptions->output_nclx_profile = outputProfile;
            }
            QCOMPARE(heif_context_encode_image(context, image, encoder, encodingOptions, &handle).code, heif_error_Ok);
            heif_encoding_options_free(encodingOptions);
            if (outputProfile) heif_nclx_color_profile_free(outputProfile);
            heif_image_handle_release(handle);
            heif_image_release(image);
        }
        auto path = root.filePath(QString("rejected-%1.avif").arg(mode));
        QCOMPARE(heif_context_write_to_file(context, path.toUtf8().constData()).code, heif_error_Ok);
        heif_encoder_release(encoder);
        heif_context_free(context);
        bool rejected = false;
        try { ImageCodec::decode(path); } catch (const std::runtime_error&) { rejected = true; }
        QVERIFY2(rejected, qPrintable(QString("Unsupported fixture mode %1 was accepted").arg(mode)));
    }
    DecodedImage highDepth;
    highDepth.pixels = QImage(16, 16, QImage::Format_RGBA64);
    highDepth.pixels.fill(Qt::red);
    QString error;
    QVERIFY(!ImageCodec::encode(highDepth, root.filePath("high-depth.avif"), "avif", 80, false, false, error));
    QVERIFY(!QFileInfo::exists(root.filePath("high-depth.avif")));
    const auto corrupt = root.filePath("corrupt.avif");
    write(corrupt, "not an image");
    QVERIFY_EXCEPTION_THROWN(ImageCodec::decode(corrupt), std::runtime_error);
#endif
}

void ReliabilityTests::metadataAndLossless()
{
#ifndef CAESIUM_WITH_HEIF
    QSKIP("Modern codecs disabled");
#else
    QTemporaryDir root;
    auto decoded = ImageCodec::decode(fixture(root.path()));
    for (int y = 0; y < decoded.pixels.height(); ++y)
        for (int x = 0; x < decoded.pixels.width(); ++x)
            decoded.pixels.setPixelColor(x, y, QColor(x * 5, y * 7, (x + y) * 3, (x * 7 + y) % 256));
    Exiv2::ExifData exif;
    exif["Exif.Image.Make"] = "CaesiumFixture";
    exif["Exif.Image.Orientation"] = uint16_t(1);
    Exiv2::Blob bytes;
    Exiv2::ExifParser::encode(bytes, Exiv2::littleEndian, exif);
    decoded.exif = QByteArray(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    Exiv2::XmpData xmp;
    xmp["Xmp.dc.description"] = "metadata fixture";
    std::string packet;
    QCOMPARE(Exiv2::XmpParser::encode(packet, xmp), 0);
    decoded.xmp = QByteArray::fromStdString(packet);
    const QString rotated = root.filePath("rotated.jpg");
    QVERIFY(decoded.pixels.save(rotated));
    {
        auto metadata = Exiv2::ImageFactory::open(rotated.toStdString());
        metadata->readMetadata();
        metadata->exifData()["Exif.Image.Orientation"] = uint16_t(6);
        metadata->writeMetadata();
    }
    QCOMPARE(ImageCodec::decode(rotated).pixels.size(), QSize(32, 48));
    for (auto format : { QString("avif"), QString("heic") }) {
        QString error;
        auto path = root.filePath("lossless." + format);
        QVERIFY(ImageCodec::canEncode(format, true));
        bool orientationMissed = false;
        auto rotationOptions = options(root.path()); rotationOptions.keepMetadata = true;
        auto rotatedTarget = root.filePath("rotated." + format);
        QVERIFY2(ImageCodec::process(rotated, rotatedTarget, format, rotationOptions, error, orientationMissed), qPrintable(error));
        QCOMPARE(ImageCodec::decode(rotatedTarget).pixels.size(), QSize(32, 48));
        QVERIFY2(ImageCodec::encode(decoded, path, format, 20, true, true, error), qPrintable(error));
        auto roundtrip = ImageCodec::decode(path);
        QCOMPARE(roundtrip.pixels.convertToFormat(QImage::Format_RGBA8888), decoded.pixels.convertToFormat(QImage::Format_RGBA8888));
        QVERIFY(!roundtrip.exif.isEmpty());
        QVERIFY(!roundtrip.xmp.isEmpty());
        auto o = options(root.path()); o.keepMetadata = true; o.resize = true; o.fitTo = FIXED_WIDTH; o.width = 24;
        bool missed = false;
        for (auto output : { QString("jpg"), QString("png"), QString("webp"), QString("tiff"), QString("avif"), QString("heic") }) {
            auto target = root.filePath(format + "-metadata." + output);
            QVERIFY2(ImageCodec::process(path, target, output, o, error, missed), qPrintable(error));
            auto result = ImageCodec::decode(target);
            Exiv2::ExifData metadata;
            Exiv2::ExifParser::decode(metadata, reinterpret_cast<const Exiv2::byte*>(result.exif.constData()), result.exif.size());
            QCOMPARE(metadata["Exif.Image.Make"].toString(), std::string("CaesiumFixture"));
            QCOMPARE(metadata["Exif.Photo.PixelXDimension"].toInt64(), int64_t(24));
            QCOMPARE(metadata["Exif.Image.Orientation"].toInt64(), int64_t(1));
        }
        QVERIFY2(ImageCodec::encode(decoded, path, format, 80, false, false, error), qPrintable(error));
        auto clean = ImageCodec::decode(path);
        QVERIFY(clean.exif.isEmpty()); QVERIFY(clean.xmp.isEmpty());
        QVERIFY(clean.pixels.colorSpace().isValid());
    }
#endif
}
