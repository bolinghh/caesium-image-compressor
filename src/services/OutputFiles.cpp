#include "OutputFiles.h"
#include "CompressionParameters.h"
#include <QDir>
#include <QFile>
#include <QUuid>

FileOperations FileOperations::native()
{
    return { [](const QString& from, const QString& to) { return QFile::rename(from, to); },
        [](const QString& path) { return QFile::remove(path); } };
}

QString OutputFiles::key(const QString& path)
{
    QFileInfo info(path);
    QString parent = QFileInfo(info.absolutePath()).canonicalFilePath();
    QString result = QDir::cleanPath((parent.isEmpty() ? info.absolutePath() : parent) + '/' + info.fileName()).normalized(QString::NormalizationForm_C);
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    result = result.toCaseFolded();
#endif
    return result;
}

QStringList OutputFiles::plan(const QStringList& inputs, const CompressionOptions& options)
{
    QSet<QString> occupied;
    for (const auto& input : inputs)
        occupied.insert(key(input));
    QStringList result;
    for (const auto& input : inputs) {
        QFileInfo info(input);
        QString directory = options.sameFolderAsInput ? info.absolutePath() : options.outputPath;
        if (options.keepStructure && !options.sameFolderAsInput) {
            QString relative = QDir(options.basePath).relativeFilePath(info.absolutePath());
            if (QDir::isAbsolutePath(relative) || relative == ".." || relative.startsWith("../"))
                relative = info.absolutePath().mid(QDir::rootPath().size()).replace(':', '_');
            directory = QDir(directory).filePath(relative);
        }
        QString extension = options.format == 0 ? info.suffix() : CompressionParameters::formatId(options.format);
        QString stem = info.completeBaseName() + options.suffix;
        QString destination = QDir(directory).absoluteFilePath(stem + '.' + extension);
        const bool overwriteOwnInput = options.sameFolderAsInput && options.suffix.isEmpty() && key(destination) == key(input);
        if (!overwriteOwnInput) {
            QSet<QString> existing;
            for (const auto& entry : QDir(directory).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot))
                existing.insert(key(QDir(directory).filePath(entry)));
            int number = 2;
            while (occupied.contains(key(destination)) || existing.contains(key(destination)) || QFileInfo::exists(destination))
                destination = QDir(directory).absoluteFilePath(stem + '_' + QString::number(number++) + '.' + extension);
        }
        occupied.insert(key(destination));
        result.append(destination);
    }
    return result;
}

OutputCommit OutputFiles::commit(const QString& temporary, const QString& destination,
    bool replaceOriginal, const FileOperations& operations)
{
    OutputCommit result;
    if (QFileInfo::exists(destination)) {
        if (!replaceOriginal) {
            result.error = QObject::tr("Output already exists: %1").arg(destination);
            return result;
        }
        result.backup = destination + ".caesium-backup-" + QUuid::createUuid().toString(QUuid::WithoutBraces);
        if (!operations.rename(destination, result.backup)) {
            result.error = QObject::tr("Cannot back up original: %1").arg(destination);
            return result;
        }
    }
    if (!operations.rename(temporary, destination)) {
        result.error = QObject::tr("Cannot commit output: %1").arg(destination);
        if (!result.backup.isEmpty()) {
            if (operations.rename(result.backup, destination))
                result.backup.clear();
            else
                result.error += QObject::tr(". Recovery failed; original preserved at %1").arg(result.backup);
        }
        return result;
    }
    result.success = true;
    if (!result.backup.isEmpty()) {
        if (operations.remove(result.backup))
            result.backup.clear();
        else
            result.error = QObject::tr("Output saved; backup retained at %1").arg(result.backup);
    }
    return result;
}
