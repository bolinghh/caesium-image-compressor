#include "ImageCodec.h"
#include <QColorSpace>
#include <QFile>
#include <QImageWriter>
#include <QPainter>
#include <QTemporaryFile>
#include <QtEndian>
#include <cmath>
#include <climits>
#include <cstring>
#include <memory>
#include <stdexcept>
#ifdef CAESIUM_WITH_HEIF
#include <libheif/heif.h>
#include <libheif/heif_sequences.h>
#endif
#ifdef CAESIUM_WITH_METADATA
#include <exiv2/exiv2.hpp>
#include <mutex>
#endif

namespace {
void fail(const QString& message) { throw std::runtime_error(message.toStdString()); }
void checkDimensions(QSize size)
{
    if (size.width() <= 0 || size.height() <= 0 || quint64(size.width()) * size.height() > 128 * 1024 * 1024)
        fail(QObject::tr("Invalid image dimensions or decoded image exceeds 512 MiB"));
}
#ifdef CAESIUM_WITH_METADATA
std::mutex metadataMutex;
void readMetadata(const QString& path, DecodedImage& decoded)
{
    std::lock_guard<std::mutex> lock(metadataMutex);
    auto image = Exiv2::ImageFactory::open(path.toStdString());
    if (!image) fail(QObject::tr("Cannot read image metadata"));
    image->readMetadata();
    auto exif = image->exifData();
    if (!exif.empty()) {
        exif["Exif.Image.Orientation"] = uint16_t(1);
        exif["Exif.Photo.PixelXDimension"] = uint32_t(decoded.pixels.width());
        exif["Exif.Photo.PixelYDimension"] = uint32_t(decoded.pixels.height());
        Exiv2::ExifThumb(exif).erase();
        Exiv2::Blob bytes;
        Exiv2::ExifParser::encode(bytes, Exiv2::littleEndian, exif);
        decoded.exif = QByteArray(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    }
    std::string packet;
    if (!image->xmpData().empty()) {
        auto xmp = image->xmpData();
        xmp["Xmp.tiff.Orientation"] = "1";
        xmp["Xmp.exif.PixelXDimension"] = std::to_string(decoded.pixels.width());
        xmp["Xmp.exif.PixelYDimension"] = std::to_string(decoded.pixels.height());
        if (Exiv2::XmpParser::encode(packet, xmp) != 0) fail(QObject::tr("Cannot serialize XMP metadata"));
        decoded.xmp = QByteArray::fromStdString(packet);
    }
}
void writeMetadata(const QString& path, const DecodedImage& decoded)
{
    std::lock_guard<std::mutex> lock(metadataMutex);
    auto image = Exiv2::ImageFactory::open(path.toStdString());
    if (!image) fail(QObject::tr("Cannot write image metadata"));
    image->readMetadata();
    Exiv2::ExifData exif;
    if (!decoded.exif.isEmpty()) Exiv2::ExifParser::decode(exif,
        reinterpret_cast<const Exiv2::byte*>(decoded.exif.constData()), decoded.exif.size());
    image->setExifData(exif);
    Exiv2::XmpData xmp;
    if (!decoded.xmp.isEmpty() && Exiv2::XmpParser::decode(xmp, decoded.xmp.toStdString()) != 0)
        fail(QObject::tr("Cannot decode XMP metadata"));
    image->setXmpData(xmp);
    image->writeMetadata();
}
#endif
#ifdef CAESIUM_WITH_HEIF
void check(heif_error error)
{
    if (error.code != heif_error_Ok) fail(QString::fromUtf8(error.message));
}
using Context = std::unique_ptr<heif_context, decltype(&heif_context_free)>;
using Handle = std::unique_ptr<heif_image_handle, decltype(&heif_image_handle_release)>;
using Image = std::unique_ptr<heif_image, decltype(&heif_image_release)>;
using Encoder = std::unique_ptr<heif_encoder, decltype(&heif_encoder_release)>;
heif_compression_format compression(const QString& format)
{
    return format == "avif" ? heif_compression_AV1 : heif_compression_HEVC;
}
#endif
}

bool ImageCodec::isModern(const QString& format) { return format == "avif" || format == "heic" || format == "heif"; }

QString ImageCodec::detect(const QString& path)
{
#ifdef CAESIUM_WITH_HEIF
    QFile file(path);
    if (file.open(QIODevice::ReadOnly)) {
        const auto bytes = file.read(4096);
        const QString mime = QString::fromLatin1(heif_get_file_mime_type(reinterpret_cast<const uint8_t*>(bytes.constData()), bytes.size()));
        if (mime.contains("avif")) return "avif";
        if (mime.contains("heic") || mime.contains("heif")) return "heic";
    }
#endif
    QString format = QString::fromLatin1(QImageReader::imageFormat(path)).toLower();
    return format == "jpeg" ? "jpg" : format;
}

bool ImageCodec::canEncode(const QString& format, bool lossless)
{
    if (!isModern(format)) return QImageWriter::supportedImageFormats().contains(format.toLatin1()) || format == "jpg";
#ifdef CAESIUM_WITH_HEIF
    const heif_encoder_descriptor* descriptor = nullptr;
    if (heif_get_encoder_descriptors(compression(format), format == "avif" ? "aom" : "x265", &descriptor, 1) != 1) return false;
    return !lossless || heif_encoder_descriptor_supports_lossless_compression(descriptor);
#else
    Q_UNUSED(lossless)
    return false;
#endif
}

DecodedImage ImageCodec::decode(const QString& path)
{
    DecodedImage result;
    const QString format = detect(path);
    if (isModern(format)) {
#ifdef CAESIUM_WITH_HEIF
        Context context(heif_context_alloc(), heif_context_free);
        check(heif_context_read_from_file(context.get(), path.toUtf8().constData(), nullptr));
        if (heif_context_has_sequence(context.get()) || heif_context_get_number_of_top_level_images(context.get()) != 1)
            fail(QObject::tr("Animated or multi-photo HEIF/AVIF files are not supported"));
        heif_image_handle* rawHandle = nullptr;
        check(heif_context_get_primary_image_handle(context.get(), &rawHandle));
        Handle handle(rawHandle, heif_image_handle_release);
        checkDimensions({ heif_image_handle_get_width(handle.get()), heif_image_handle_get_height(handle.get()) });
        if (heif_image_handle_get_luma_bits_per_pixel(handle.get()) > 8 || heif_image_handle_get_chroma_bits_per_pixel(handle.get()) > 8)
            fail(QObject::tr("Only 8-bit SDR HEIF/AVIF images are supported"));
        if (heif_image_handle_get_number_of_auxiliary_images(handle.get(), LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA) > 0
            || heif_image_handle_has_depth_image(handle.get()))
            fail(QObject::tr("HDR gain maps, depth maps and auxiliary photos are not supported"));
        heif_color_profile_nclx* nclx = nullptr;
        const auto profileError = heif_image_handle_get_nclx_color_profile(handle.get(), &nclx);
        if (profileError.code == heif_error_Ok && nclx) {
            const int transfer = nclx->transfer_characteristics;
            heif_nclx_color_profile_free(nclx);
            if (transfer == 16 || transfer == 18) fail(QObject::tr("HDR HEIF/AVIF images are not supported"));
        }
        heif_image* rawImage = nullptr;
        auto* options = heif_decoding_options_alloc();
        options->strict_decoding = 1;
        auto decodeError = heif_decode_image(handle.get(), &rawImage, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options);
        heif_decoding_options_free(options);
        check(decodeError);
        Image image(rawImage, heif_image_release);
        int stride = 0;
        const uint8_t* pixels = heif_image_get_plane_readonly(image.get(), heif_channel_interleaved, &stride);
        int width = heif_image_get_width(image.get(), heif_channel_interleaved);
        int height = heif_image_get_height(image.get(), heif_channel_interleaved);
        checkDimensions({ width, height });
        result.pixels = QImage(pixels, width, height, stride, QImage::Format_RGBA8888).copy();
        QByteArray icc(heif_image_handle_get_raw_color_profile_size(handle.get()), Qt::Uninitialized);
        if (!icc.isEmpty()) {
            check(heif_image_handle_get_raw_color_profile(handle.get(), icc.data()));
            const auto space = QColorSpace::fromIccProfile(icc);
            if (!space.isValid()) fail(QObject::tr("Unsupported ICC color profile"));
            result.pixels.setColorSpace(space);
        } else {
            heif_color_profile_nclx* color = nullptr;
            if (heif_image_handle_get_nclx_color_profile(handle.get(), &color).code == heif_error_Ok && color) {
                if (color->color_primaries != 1 && color->color_primaries != 2) {
                    heif_nclx_color_profile_free(color);
                    fail(QObject::tr("Wide-gamut images require an ICC profile"));
                }
                heif_nclx_color_profile_free(color);
            }
            result.pixels.setColorSpace(QColorSpace::SRgb);
        }
#else
        fail(QObject::tr("HEIF/AVIF support is not available in this build"));
#endif
    } else {
        QImageReader reader(path);
        checkDimensions(reader.size());
        reader.setAutoTransform(true);
        result.pixels = reader.read();
        if (result.pixels.isNull()) fail(reader.errorString());
    }
#ifdef CAESIUM_WITH_METADATA
    readMetadata(path, result);
#endif
    return result;
}

bool ImageCodec::encode(const DecodedImage& sourceImage, const QString& path, const QString& format,
    int quality, bool lossless, bool keepMetadata, QString& error)
{
    error.clear();
    try {
        DecodedImage decoded = sourceImage;
#ifdef CAESIUM_WITH_METADATA
        {
            std::lock_guard<std::mutex> lock(metadataMutex);
            if (!decoded.exif.isEmpty()) {
                Exiv2::ExifData exif;
                Exiv2::ExifParser::decode(exif, reinterpret_cast<const Exiv2::byte*>(decoded.exif.constData()), decoded.exif.size());
                exif["Exif.Image.Orientation"] = uint16_t(1);
                exif["Exif.Photo.PixelXDimension"] = uint32_t(decoded.pixels.width());
                exif["Exif.Photo.PixelYDimension"] = uint32_t(decoded.pixels.height());
                Exiv2::Blob bytes;
                Exiv2::ExifParser::encode(bytes, Exiv2::littleEndian, exif);
                decoded.exif = QByteArray(reinterpret_cast<const char*>(bytes.data()), bytes.size());
            }
            if (!decoded.xmp.isEmpty()) {
                Exiv2::XmpData xmp;
                if (Exiv2::XmpParser::decode(xmp, decoded.xmp.toStdString()) != 0) fail(QObject::tr("Cannot decode XMP"));
                xmp["Xmp.tiff.Orientation"] = "1";
                xmp["Xmp.exif.PixelXDimension"] = std::to_string(decoded.pixels.width());
                xmp["Xmp.exif.PixelYDimension"] = std::to_string(decoded.pixels.height());
                std::string packet;
                if (Exiv2::XmpParser::encode(packet, xmp) != 0) fail(QObject::tr("Cannot encode XMP"));
                decoded.xmp = QByteArray::fromStdString(packet);
            }
        }
#endif
        if (isModern(format)) {
            if (decoded.pixels.depth() > 32 || decoded.pixels.colorSpace().transferFunction() == QColorSpace::TransferFunction::St2084
                || decoded.pixels.colorSpace().transferFunction() == QColorSpace::TransferFunction::Hlg)
                fail(QObject::tr("Only 8-bit SDR input can be encoded to HEIF/AVIF"));
#ifdef CAESIUM_WITH_HEIF
            if (!canEncode(format, lossless)) fail(QObject::tr("Requested encoder or lossless mode is unavailable"));
            Context context(heif_context_alloc(), heif_context_free);
            heif_encoder* rawEncoder = nullptr;
            const heif_encoder_descriptor* descriptor = nullptr;
            heif_get_encoder_descriptors(compression(format), format == "avif" ? "aom" : "x265", &descriptor, 1);
            check(heif_context_get_encoder(context.get(), descriptor, &rawEncoder));
            Encoder encoder(rawEncoder, heif_encoder_release);
            check(heif_encoder_set_lossy_quality(encoder.get(), qBound(0, quality, 100)));
            check(heif_encoder_set_lossless(encoder.get(), lossless));
            // Thread hints differ between codec backends and are not capabilities.
            if (format == "avif") heif_encoder_set_parameter_integer(encoder.get(), "threads", 1);
            else {
                heif_encoder_set_parameter_string(encoder.get(), "x265:pools", "none");
                heif_encoder_set_parameter_string(encoder.get(), "x265:frame-threads", "1");
            }
            if (lossless) check(heif_encoder_set_parameter_string(encoder.get(), "chroma", "444"));
            const QImage rgba = decoded.pixels.convertToFormat(QImage::Format_RGBA8888);
            heif_image* rawImage = nullptr;
            check(heif_image_create(rgba.width(), rgba.height(), heif_colorspace_RGB, heif_chroma_interleaved_RGBA, &rawImage));
            Image image(rawImage, heif_image_release);
            check(heif_image_add_plane(image.get(), heif_channel_interleaved, rgba.width(), rgba.height(), 8));
            int stride = 0;
            uint8_t* pixels = heif_image_get_plane(image.get(), heif_channel_interleaved, &stride);
            for (int row = 0; row < rgba.height(); ++row) std::memcpy(pixels + row * stride, rgba.constScanLine(row), rgba.width() * 4);
            const QByteArray icc = decoded.pixels.colorSpace().isValid() ? decoded.pixels.colorSpace().iccProfile() : QColorSpace(QColorSpace::SRgb).iccProfile();
            if (!icc.isEmpty()) check(heif_image_set_raw_color_profile(image.get(), "prof", icc.constData(), icc.size()));
            heif_image_handle* rawHandle = nullptr;
            auto* encodingOptions = heif_encoding_options_alloc();
            auto* profile = heif_nclx_color_profile_alloc();
            profile->color_primaries = heif_color_primaries_ITU_R_BT_709_5;
            profile->transfer_characteristics = heif_transfer_characteristic_IEC_61966_2_1;
            profile->matrix_coefficients = lossless ? heif_matrix_coefficients_RGB_GBR : heif_matrix_coefficients_ITU_R_BT_709_5;
            profile->full_range_flag = 1;
            encodingOptions->output_nclx_profile = profile;
            encodingOptions->save_two_colr_boxes_when_ICC_and_nclx_available = 1;
            auto encodingError = heif_context_encode_image(context.get(), image.get(), encoder.get(), encodingOptions, &rawHandle);
            heif_encoding_options_free(encodingOptions);
            heif_nclx_color_profile_free(profile);
            check(encodingError);
            Handle handle(rawHandle, heif_image_handle_release);
            if (keepMetadata && !decoded.exif.isEmpty()) check(heif_context_add_exif_metadata(context.get(), handle.get(), decoded.exif.constData(), decoded.exif.size()));
            if (keepMetadata && !decoded.xmp.isEmpty()) check(heif_context_add_XMP_metadata(context.get(), handle.get(), decoded.xmp.constData(), decoded.xmp.size()));
            check(heif_context_write_to_file(context.get(), path.toUtf8().constData()));
#else
            fail(QObject::tr("HEIF/AVIF encoding is not available in this build"));
#endif
        } else {
            QImage pixels = decoded.pixels;
            if ((format == "jpg" || format == "jpeg") && pixels.hasAlphaChannel()) {
                QImage background(pixels.size(), QImage::Format_RGB32);
                background.fill(Qt::white);
                background.setColorSpace(pixels.colorSpace());
                QPainter painter(&background);
                painter.drawImage(0, 0, pixels);
                painter.end();
                pixels = background;
            }
            QImageWriter writer(path, format.toLatin1());
            writer.setQuality(quality);
            if (!writer.write(pixels)) fail(writer.errorString());
#ifdef CAESIUM_WITH_METADATA
            if (keepMetadata) writeMetadata(path, decoded);
#else
            if (keepMetadata && (!decoded.exif.isEmpty() || !decoded.xmp.isEmpty())) fail(QObject::tr("Metadata writer is unavailable"));
#endif
        }
        return true;
    } catch (const std::exception& exception) {
        error = QString::fromUtf8(exception.what());
        return false;
    }
}

QSize ImageCodec::resizedSize(QSize original, const CompressionOptions& o)
{
    if (!o.resize) return original;
    QSize result = original;
    switch (o.fitTo) {
    case DIMENSIONS: result = { o.width, o.height }; break;
    case PERCENTAGE: result = { qMax(1, qRound(original.width() * o.width / 100.0)), qMax(1, qRound(original.height() * o.height / 100.0)) }; break;
    case FIXED_WIDTH: result.scale(o.width, INT_MAX, Qt::KeepAspectRatio); break;
    case FIXED_HEIGHT: result.scale(INT_MAX, o.height, Qt::KeepAspectRatio); break;
    case LONG_EDGE: result.scale(o.size, o.size, Qt::KeepAspectRatio); break;
    case SHORT_EDGE:
        result = original * (double(o.size) / qMin(original.width(), original.height())); break;
    default: break;
    }
    if (o.doNotEnlarge && (result.width() > original.width() || result.height() > original.height())) return original;
    return result.expandedTo({ 1, 1 });
}

bool ImageCodec::process(const QString& input, const QString& output, const QString& format,
    const CompressionOptions& options, QString& error, bool& targetMissed)
{
    error.clear();
    targetMissed = false;
    try {
        auto decoded = decode(input);
        const QSize size = resizedSize(decoded.pixels.size(), options);
        checkDimensions(size);
        if (decoded.pixels.size() != size) decoded.pixels = decoded.pixels.scaled(size, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
        int quality = format == "avif" ? options.avifQuality : format == "heic" ? options.heicQuality
            : format == "jpg" ? options.jpegQuality : format == "webp" ? options.webpQuality : options.pngQuality;
        if (options.compressionMode != SIZE) return encode(decoded, output, format, quality, options.lossless, options.keepMetadata, error);
        const quint64 limit = options.maxOutputSize.unit == MAX_OUTPUT_PERCENTAGE
            ? quint64(QFileInfo(input).size()) * options.maxOutputSize.maxOutputSize / 100
            : quint64(options.maxOutputSize.maxOutputSize) << (int(options.maxOutputSize.unit) * 10);
        QByteArray best, smallest;
        int low = 0, high = 100;
        for (int attempt = 0; attempt < 12 && low <= high; ++attempt) {
            const int candidate = (low + high) / 2;
            QTemporaryFile temporary;
            if (!temporary.open()) fail(QObject::tr("Cannot create encoding candidate"));
            temporary.close();
            if (!encode(decoded, temporary.fileName(), format, candidate, options.lossless, options.keepMetadata, error)) return false;
            QFile file(temporary.fileName());
            if (!file.open(QIODevice::ReadOnly)) fail(file.errorString());
            const auto bytes = file.readAll();
            if (smallest.isEmpty() || bytes.size() < smallest.size()) smallest = bytes;
            if (quint64(bytes.size()) <= limit) { best = bytes; low = candidate + 1; }
            else high = candidate - 1;
            if (options.lossless) break;
        }
        targetMissed = best.isEmpty();
        QFile file(output);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) fail(file.errorString());
        const auto& bytes = best.isEmpty() ? smallest : best;
        if (file.write(bytes) != bytes.size() || !file.flush()) fail(file.errorString());
        return true;
    } catch (const std::exception& exception) {
        error = QString::fromUtf8(exception.what());
        return false;
    }
}
