#pragma once
#include "utils/Utils.h"

struct DecodedImage {
    QImage pixels;
    QByteArray exif;
    QByteArray xmp;
};

class ImageCodec {
public:
    static QString detect(const QString& path);
    static bool isModern(const QString& format);
    static bool canEncode(const QString& format, bool lossless = false);
    static DecodedImage decode(const QString& path);
    static bool encode(const DecodedImage& image, const QString& path, const QString& format,
        int quality, bool lossless, bool keepMetadata, QString& error);
    static QSize resizedSize(QSize original, const CompressionOptions& options);
    static bool process(const QString& input, const QString& output, const QString& format,
        const CompressionOptions& options, QString& error, bool& targetMissed);
};
