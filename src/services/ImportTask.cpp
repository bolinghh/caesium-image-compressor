#include "ImportTask.h"
#include "OutputFiles.h"
#include <QDirIterator>
#include <QPromise>
#include <QtConcurrent>

void ImportTask::start(QStringList paths, bool recursive, ImportFilters filters, QSet<QString> known)
{
    canceled = std::make_shared<std::atomic_bool>(false);
    const auto token = canceled;
    watcher.setFuture(QtConcurrent::run([paths, recursive, filters, known, token](QPromise<ImportBatch>& promise) mutable {
        ImportBatch batch;
        auto flush = [&] {
            if (!batch.images.isEmpty() || !batch.errors.isEmpty()) { promise.addResult(batch); batch = {}; }
        };
        auto add = [&](const QString& path) {
            if (token->load()) return;
            QFileInfo info(path);
            const QString identity = OutputFiles::key(info.canonicalFilePath());
            if (!info.isFile() || known.contains(identity) || !Importer::passesFilters(info, filters)) return;
            known.insert(identity);
            try { batch.images.append(std::make_shared<CImage>(path)); }
            catch (const std::exception& e) { batch.errors.append(info.fileName() + ": " + QString::fromUtf8(e.what())); }
            if (batch.images.size() + batch.errors.size() >= 64) flush();
        };
        for (const auto& path : paths) {
            if (token->load()) break;
            if (QFileInfo(path).isDir()) {
                QDirIterator it(path, Importer::nameFilters(), QDir::Files,
                    recursive ? QDirIterator::Subdirectories : QDirIterator::NoIteratorFlags);
                while (!token->load() && it.hasNext()) add(it.next());
            } else add(path);
        }
        flush();
    }));
}
