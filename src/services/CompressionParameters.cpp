#include "CompressionParameters.h"
#include <QJsonDocument>
#include <QSettings>
#include <algorithm>

CompressionOptions CompressionParameters::normalize(CompressionOptions o)
{
    o.format = qBound(0, o.format, int(getOutputSupportedFormats().size()) - 1);
    o.jpegQuality = qBound(1, o.jpegQuality, 100);
    o.pngQuality = qBound(0, o.pngQuality, 100);
    o.pngOptimizationLevel = qBound(1, o.pngOptimizationLevel, 6);
    o.webpQuality = qBound(1, o.webpQuality, 100);
    o.avifQuality = qBound(0, o.avifQuality, 100);
    o.heicQuality = qBound(0, o.heicQuality, 100);
    o.tiffMethod = qBound(0, o.tiffMethod, 2);
    o.tiffDeflateLevel = qBound(1, o.tiffDeflateLevel, 9);
    o.fitTo = qBound(0, o.fitTo, 6);
    o.width = qBound(1, o.width, 100000);
    o.height = qBound(1, o.height, 100000);
    o.size = qBound(1, o.size, 100000);
    if (o.compressionMode != QUALITY && o.compressionMode != SIZE) o.compressionMode = QUALITY;
    if (o.maxOutputSize.unit < MAX_OUTPUT_BYTES || o.maxOutputSize.unit > MAX_OUTPUT_PERCENTAGE)
        o.maxOutputSize.unit = MAX_OUTPUT_KB;
    o.maxOutputSize.maxOutputSize = qBound<size_t>(1, o.maxOutputSize.maxOutputSize, 500 * 1024 * 1024);
    if (o.maxOutputSize.unit == MAX_OUTPUT_PERCENTAGE)
        o.maxOutputSize.maxOutputSize = qMin<size_t>(100, o.maxOutputSize.maxOutputSize);
    // A suffix is a filename fragment, never a relative or absolute path.
    o.suffix.replace('/', '_').replace('\\', '_');
    return o;
}

QString CompressionParameters::formatId(int index)
{
    return QStringList { "same", "jpg", "png", "webp", "tiff", "avif", "heic" }.value(index, "same");
}

int CompressionParameters::storedFormatIndex()
{
    QSettings settings;
    const QString key = "compression_options/output/format_id";
    if (!settings.contains(key))
        settings.setValue(key, formatId(qBound(0, settings.value("compression_options/output/format", 0).toInt(), 4)));
    int index = QStringList { "same", "jpg", "png", "webp", "tiff", "avif", "heic" }.indexOf(settings.value(key).toString());
    return index >= 0 && index < getOutputSupportedFormats().size() ? index : 0;
}

QString CompressionParameters::cacheKey(const QString& input, const CompressionOptions& options)
{
    const auto o = normalize(options);
    QJsonObject data {
        { "version", 2 }, { "path", QFileInfo(input).canonicalFilePath() },
        { "bytes", QString::number(QFileInfo(input).size()) },
        { "modified", QString::number(QFileInfo(input).lastModified().toMSecsSinceEpoch()) },
        { "format", formatId(o.format) }, { "lossless", o.lossless }, { "metadata", o.keepMetadata },
        { "jpeg", o.jpegQuality }, { "chroma", o.jpegChromaSubsampling }, { "progressive", o.jpegProgressive },
        { "png", o.pngQuality }, { "optimization", o.pngOptimizationLevel }, { "webp", o.webpQuality },
        { "tiff", o.tiffMethod }, { "deflate", o.tiffDeflateLevel }, { "avif", o.avifQuality }, { "heic", o.heicQuality },
        { "resize", o.resize }, { "fit", o.fitTo }, { "width", o.width }, { "height", o.height },
        { "edge", o.size }, { "noEnlarge", o.doNotEnlarge }, { "mode", o.compressionMode },
        { "limit", QString::number(o.maxOutputSize.maxOutputSize) }, { "unit", o.maxOutputSize.unit }
    };
    return hashString(QString::fromUtf8(QJsonDocument(data).toJson(QJsonDocument::Compact)), QCryptographicHash::Sha256);
}
