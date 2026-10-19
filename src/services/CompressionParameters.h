#pragma once
#include "utils/Utils.h"

class CompressionParameters {
public:
    static CompressionOptions normalize(CompressionOptions options);
    static QString formatId(int index);
    static int storedFormatIndex();
    static QString cacheKey(const QString& input, const CompressionOptions& options);
};
