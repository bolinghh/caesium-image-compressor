#include "CompressionTask.h"
#include "OutputFiles.h"
#include <QtConcurrent>

CompressionTask::CompressionTask(QObject* parent)
    : QObject(parent), canceled(std::make_shared<std::atomic_bool>(false))
{
}

CompressionTask::~CompressionTask()
{
    cancel();
    watcher.waitForFinished();
}

void CompressionTask::start(const QList<std::pair<int, CImage>>& images,
    const CompressionOptions& options, const QStringList& allInputs)
{
    Q_ASSERT(!watcher.isRunning());
    canceled = std::make_shared<std::atomic_bool>(false);
    const QStringList outputs = OutputFiles::plan(allInputs, options);
    struct Work { int row; CImage image; CompressionOptions options; };
    QList<Work> work;
    for (const auto& entry : images) {
        CompressionOptions snapshot = options;
        snapshot.plannedOutputPath = outputs.value(entry.first);
        work.append({ entry.first, entry.second, snapshot });
    }
    const auto token = canceled;
    watcher.setFuture(QtConcurrent::mapped(work, [token](const Work& entry) {
        CompressionResult result;
        result.row = entry.row;
        if (token->load()) return result;
        result.image = std::make_shared<CImage>(entry.image);
        result.executed = true;
        result.image->setStatus(CImageStatus::COMPRESSING);
        try {
            if (!result.image->compress(entry.options)) result.image->setStatus(CImageStatus::ERROR);
            else if (result.image->getStatus() == CImageStatus::COMPRESSING) result.image->setStatus(CImageStatus::COMPRESSED);
        } catch (const std::exception& error) {
            result.image->setError(QString::fromUtf8(error.what()));
        }
        return result;
    }));
}

void CompressionTask::cancel() { canceled->store(true); }
bool CompressionTask::wasCanceled() const { return canceled->load(); }

BatchOutcome CompressionTask::outcome() const
{
    BatchOutcome result;
    result.canceled = wasCanceled();
    for (const auto& entry : watcher.future().results()) {
        if (!entry.executed) ++result.notExecuted;
        else if (entry.image->getStatus() == CImageStatus::ERROR) ++result.failed;
        else if (entry.image->getStatus() == CImageStatus::WARNING) ++result.warnings;
        else if (entry.image->getStatus() == CImageStatus::SKIPPED) ++result.skipped;
        else ++result.succeeded;
    }
    return result;
}
