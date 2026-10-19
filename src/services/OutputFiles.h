#pragma once

#include "utils/Utils.h"
#include <QSet>
#include <functional>

// File operations are replaceable so failures can be tested without damaging files.
struct FileOperations {
    std::function<bool(const QString&, const QString&)> rename;
    std::function<bool(const QString&)> remove;
    static FileOperations native();
};

struct OutputCommit {
    bool success = false;
    QString error;
    QString backup;
};

class OutputFiles {
public:
    static QStringList plan(const QStringList& inputs, const CompressionOptions& options);
    static OutputCommit commit(const QString& temporary, const QString& destination,
        bool replaceOriginal, const FileOperations& operations = FileOperations::native());
    static QString key(const QString& path);
};
