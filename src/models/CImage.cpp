#include "CImage.h"
#include "services/OutputFiles.h"
#include "services/CompressionParameters.h"
#include "services/ImageCodec.h"
#include "../include/libcaesium.h"

#include "./exceptions/ImageNotSupportedException.h"
#include "exceptions/ImageTooBigException.h"
#include <QDir>
#include <QImageReader>
#include <QStandardPaths>
#include <QTemporaryFile>
#include <cmath>

CImage::CImage(const QString& path)
{
    QFileInfo fileInfo = QFileInfo(path);
    this->format = ImageCodec::detect(path);
    if (!supportedFormats.contains(format)) throw ImageNotSupportedException();
    this->extension = fileInfo.suffix();
    this->size = fileInfo.size();

    if (this->size > 500 * 1024 * 1024) {
        throw ImageTooBigException();
    }

    this->fullPath = fileInfo.canonicalFilePath();
    this->directory = fileInfo.canonicalPath();
    this->fileName = fileInfo.fileName();
    this->compressedSize = this->size;

    QSize imageSize = ImageCodec::decode(path).pixels.size();
    this->width = imageSize.width();
    this->height = imageSize.height();

    this->compressedWidth = this->width;
    this->compressedHeight = this->height;

    this->hashedFullPath = hashString(this->fullPath, QCryptographicHash::Sha256);

    this->status = CImageStatus::UNCOMPRESSED;

}

bool operator==(const CImage& c1, const CImage& c2)
{
    return (c1.fullPath == c2.fullPath);
}

bool operator!=(const CImage& c1, const CImage& c2)
{
    return !(c1 == c2);
}

QString CImage::getFormattedSize() const
{
    bool needsFormatting = this->status == CImageStatus::COMPRESSED || this->status == CImageStatus::WARNING;
    size_t s = needsFormatting ? this->compressedSize : this->size;
    return toHumanSize(static_cast<double>(s));
}

QString CImage::getRichFormattedSize() const
{
    bool needsFormatting = this->status == CImageStatus::COMPRESSED || this->status == CImageStatus::WARNING;
    if (needsFormatting && this->size != this->compressedSize) {
        return "<small><s>" + toHumanSize(static_cast<double>(this->size)) + "</s></small> " + toHumanSize(static_cast<double>(this->compressedSize));
    }
    return toHumanSize(static_cast<double>(this->size));
}

QString CImage::getResolution() const
{
    if (this->status == CImageStatus::COMPRESSED || this->status == CImageStatus::WARNING) {
        return QString::number(this->compressedWidth) + "x" + QString::number(this->compressedHeight);
    }
    return QString::number(this->width) + "x" + QString::number(this->height);
}

QString CImage::getRichResolution() const
{
    bool needsFormatting = this->status == CImageStatus::COMPRESSED || this->status == CImageStatus::WARNING;
    if (needsFormatting && (this->width != this->compressedWidth || this->height != this->compressedHeight)) {
        return "<small><s>" + QString::number(this->width) + "x" + QString::number(this->height) + "</s></small> " + QString::number(this->compressedWidth) + "x" + QString::number(this->compressedHeight);
    }
    return QString::number(this->width) + "x" + QString::number(this->height);
}

QString CImage::getFileName() const
{
    return fileName;
}

QString CImage::getFullPath() const
{
    return this->fullPath;
}

bool CImage::preview(const CompressionOptions& options) const
{
    auto snapshot = CompressionParameters::normalize(options);
    snapshot.plannedOutputPath = getTemporaryPreviewFullPath(snapshot);
    if (QFileInfo::exists(snapshot.plannedOutputPath)) return true;
    snapshot.moveOriginalFile = false;
    snapshot.skipIfBigger = false;
    snapshot.sameFolderAsInput = false;
    snapshot.keepDates = false;
    CImage copy(*this);
    try { return copy.compress(snapshot) || QFileInfo::exists(snapshot.plannedOutputPath); }
    catch (const std::exception&) { return false; }
}

bool CImage::compress(const CompressionOptions& inputOptions)
{
    const auto compressionOptions = CompressionParameters::normalize(inputOptions);
    this->additionalInfo.clear();
    const QFileInfo input(this->fullPath);
    if (!input.exists()) {
        this->additionalInfo = QIODevice::tr("Input file does not exist");
        return false;
    }
    QString output = compressionOptions.plannedOutputPath;
    if (output.isEmpty())
        output = OutputFiles::plan({ this->fullPath }, compressionOptions).value(0);
    if (output.isEmpty() || !QDir().mkpath(QFileInfo(output).absolutePath())) {
        this->additionalInfo = QIODevice::tr("Cannot make output path, check your permissions");
        return false;
    }
    QTemporaryFile temporary(QFileInfo(output).absolutePath() + "/.caesium-XXXXXX");
    if (!temporary.open()) {
        this->additionalInfo = QIODevice::tr("Temporary file creation failed");
        return false;
    }
    const QString temporaryPath = temporary.fileName();
    temporary.close();
    CCSParameters parameters = getCSParameters(compressionOptions);
    const QString outputFormat = compressionOptions.format == 0 ? format : CompressionParameters::formatId(compressionOptions.format);
    QTemporaryFile converted;
    QString source = this->fullPath;
    const bool modern = ImageCodec::isModern(format) || ImageCodec::isModern(outputFormat);
    if (!modern && outputFormat.compare(format, Qt::CaseInsensitive) != 0) {
        if (!converted.open()) {
            this->additionalInfo = QIODevice::tr("Temporary file creation failed");
            return false;
        }
        converted.close();
        const auto image = ImageCodec::decode(source);
        if (!ImageCodec::encode(image, converted.fileName(), outputFormat, 100, false, compressionOptions.keepMetadata, additionalInfo)) {
            this->additionalInfo = QIODevice::tr("File conversion failed");
            return false;
        }
        source = converted.fileName();
    }
    bool targetMissed = false;
    if (modern) {
        if (!ImageCodec::process(source, temporaryPath, outputFormat, compressionOptions, additionalInfo, targetMissed)) return false;
    } else {
        CCSResult result = compressionOptions.compressionMode == SIZE
            ? c_compress_to_size(source.toUtf8().constData(), temporaryPath.toUtf8().constData(), parameters,
                  getMaxOutputSizeInBytes(compressionOptions.maxOutputSize, input.size()), true)
            : c_compress(source.toUtf8().constData(), temporaryPath.toUtf8().constData(), parameters);
        if (!result.success) {
            this->additionalInfo = QString::fromUtf8(result.error_message ? result.error_message : "Compression failed");
            return false;
        }
    }
    try {
        const QImage decoded = ImageCodec::decode(temporaryPath).pixels;
        if (decoded.isNull() || ImageCodec::detect(temporaryPath) != outputFormat) {
            this->additionalInfo = QIODevice::tr("Output validation failed");
            return false;
        }
    } catch (const std::exception& error) {
        additionalInfo = QString::fromUtf8(error.what());
        return false;
    }
    // A larger result never removes the original or changes the requested extension.
    if (compressionOptions.skipIfBigger && QFileInfo(temporaryPath).size() >= input.size()) {
        this->status = CImageStatus::SKIPPED;
        this->additionalInfo = QIODevice::tr("Skipped: compressed file is bigger than original");
        setCompressedInfo(input);
        return true;
    }
    const bool replacingOriginal = OutputFiles::key(output) == OutputFiles::key(this->fullPath);
    auto operations = FileOperations::native();
    if (replacingOriginal && compressionOptions.moveOriginalFile && compressionOptions.moveOriginalFileDestination == 0)
        operations.remove = [](const QString& path) { return QFile::moveToTrash(path); };
    const OutputCommit commit = OutputFiles::commit(temporaryPath, output, replacingOriginal, operations);
    this->additionalInfo = commit.error;
    if (targetMissed) { additionalInfo += QIODevice::tr("Target size could not be reached; smallest result returned"); status = CImageStatus::WARNING; }
    if (!commit.success) return false;
    if (!commit.error.isEmpty()) this->status = CImageStatus::WARNING;
    if (compressionOptions.keepDates) {
        setFileDates(QFileInfo(output), compressionOptions.datesMap,
            { input.birthTime(), input.lastModified(), input.lastRead() });
    }
    if (compressionOptions.moveOriginalFile && !replacingOriginal) {
        bool removed = compressionOptions.moveOriginalFileDestination == 0
            ? QFile::moveToTrash(this->fullPath) : QFile::remove(this->fullPath);
        if (!removed) {
            this->additionalInfo = QIODevice::tr("Output saved, but original could not be removed");
            this->status = CImageStatus::WARNING;
        }
    }
    setCompressedInfo(QFileInfo(output));
    return true;
}

CCSParameters CImage::getCSParameters(const CompressionOptions& compressionOptions) const
{
    CCSParameters r_parameters = {};
    r_parameters.keep_metadata = compressionOptions.keepMetadata;
    r_parameters.jpeg_quality = static_cast<unsigned int>(compressionOptions.jpegQuality);
    r_parameters.jpeg_chroma_subsampling = compressionOptions.jpegChromaSubsampling;
    r_parameters.jpeg_progressive = compressionOptions.jpegProgressive;
    r_parameters.png_quality = static_cast<unsigned int>(compressionOptions.pngQuality);
    r_parameters.png_optimization_level = static_cast<unsigned int>(compressionOptions.pngOptimizationLevel);
    r_parameters.png_force_zopfli = false;
    r_parameters.gif_quality = 20;
    r_parameters.webp_quality = static_cast<unsigned int>(compressionOptions.webpQuality);
    r_parameters.tiff_compression = static_cast<unsigned int>(compressionOptions.tiffMethod);
    r_parameters.tiff_deflate_level = static_cast<unsigned int>(compressionOptions.tiffDeflateLevel);
    r_parameters.optimize = compressionOptions.lossless;
    r_parameters.width = 0;
    r_parameters.height = 0;

    // Resize
    if (compressionOptions.resize && !ImageCodec::isModern(format)) {
        QImageReader imageReader(this->getFullPath());
        QSize originalSize = imageReader.size();

        std::tuple<unsigned int, unsigned int> dimensions = cResize(&imageReader, compressionOptions);

        if (std::get<0>(dimensions) != originalSize.width() || std::get<1>(dimensions) != originalSize.height()) {
            r_parameters.width = static_cast<int>(std::get<0>(dimensions));
            r_parameters.height = static_cast<int>(std::get<1>(dimensions));
        }
    }
    return r_parameters;
}

void CImage::setCompressedInfo(const QFileInfo& fileInfo)
{
    QSize imageSize = ImageCodec::decode(fileInfo.canonicalFilePath()).pixels.size();
    this->compressedDirectory = fileInfo.canonicalPath();
    this->compressedSize = fileInfo.size();
    this->compressedFullPath = fileInfo.canonicalFilePath();
    this->compressedWidth = imageSize.width();
    this->compressedHeight = imageSize.height();
}

void CImage::setFileDates(const QFileInfo& fileInfo, FileDatesOutputOption datesMap, const FileDates& inputFileDates)
{
    QFile outputFile(fileInfo.canonicalFilePath());
    outputFile.open(QIODevice::ReadWrite);
    if (datesMap.keepCreation) {
        outputFile.setFileTime(inputFileDates.creation, QFileDevice::FileBirthTime);
    }
    if (datesMap.keepLastModified) {
        outputFile.setFileTime(inputFileDates.lastModified, QFileDevice::FileModificationTime);
    }
    if (datesMap.keepLastAccess) {
        outputFile.setFileTime(inputFileDates.lastAccess, QFileDevice::FileAccessTime);
    }
    outputFile.close();
}

QString CImage::getCompressedFullPath() const
{
    return compressedFullPath;
}

double CImage::getRatio() const
{
    return static_cast<double>(this->compressedSize) / static_cast<double>(this->size);
}

QString CImage::getFormattedSavedRatio() const
{
    return QString::number(round(100 - (this->getRatio() * 100))) + "%";
}

QString CImage::getRichFormattedSavedRatio() const
{
    return this->getFormattedSavedRatio();
}

CImageStatus CImage::getStatus() const
{
    return status;
}

void CImage::setStatus(const CImageStatus& value)
{
    status = value;
}

size_t CImage::getOriginalSize() const
{
    return this->size;
}

size_t CImage::getCompressedSize() const
{
    return this->compressedSize;
}

size_t CImage::getTotalPixels() const
{
    return this->width * this->height;
}

QString CImage::getFormattedStatus() const
{
    switch (this->status) {
    case CImageStatus::COMPRESSING:
        return QIODevice::tr("Compressing...");
    case CImageStatus::ERROR:
        return QIODevice::tr("Error:") + " " + this->additionalInfo;
    case CImageStatus::SKIPPED:
    case CImageStatus::WARNING:
        return this->additionalInfo;
    case CImageStatus::COMPRESSED:
    case CImageStatus::UNCOMPRESSED:
    default:
        return "";
    }
}

QString CImage::getDirectory() const
{
    return this->directory;
}

QString CImage::getCompressedDirectory() const
{
    return this->compressedDirectory;
}

QString CImage::getHashedFullPath() const
{
    return this->hashedFullPath;
}

QString CImage::getTemporaryPreviewFullPath() const
{
    return getTemporaryPreviewFullPath(CompressionOptions {});
}

QString CImage::getTemporaryPreviewFullPath(const CompressionOptions& options) const
{
    const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/previews-v2";
    if (!QDir().mkpath(cache)) return {};
    return cache + '/' + CompressionParameters::cacheKey(fullPath, options);
}

QString CImage::getPreviewFullPath() const
{
    if (!this->compressedFullPath.isEmpty()) {
        return this->compressedFullPath;
    }

    return this->getTemporaryPreviewFullPath();
}

QString CImage::getFormat() const
{
    return this->format;
}

size_t CImage::getMaxOutputSizeInBytes(MaxOutputSize maxOutputSize, size_t originalSize)
{
    if (maxOutputSize.unit == MAX_OUTPUT_PERCENTAGE) {
        return std::floor(originalSize * maxOutputSize.maxOutputSize / 100);
    }

    return maxOutputSize.maxOutputSize << (maxOutputSize.unit * 10);
}
