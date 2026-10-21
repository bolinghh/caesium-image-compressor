#pragma once

#include "models/CImage.h"
#include <QFutureWatcher>
#include <atomic>
#include <memory>

struct CompressionResult {
    int row = -1;
    std::shared_ptr<CImage> image;
    bool executed = false;
};

struct BatchOutcome {
    int succeeded = 0;
    int failed = 0;
    int warnings = 0;
    int skipped = 0;
    int notExecuted = 0;
    bool canceled = false;
    bool allowsCompletionAction() const { return !canceled && failed == 0 && warnings == 0 && notExecuted == 0 && succeeded + skipped > 0; }
};

class CompressionTask : public QObject {
    Q_OBJECT
public:
    explicit CompressionTask(QObject* parent = nullptr);
    ~CompressionTask() override;
    QFutureWatcher<CompressionResult> watcher;
    void start(const QList<std::pair<int, CImage>>& images, const CompressionOptions& options, const QStringList& allInputs);
    // A UI adapter may plan destinations off the main thread, retaining the same input-order mapping.
    void startPlanned(const QList<std::pair<int, CImage>>& images, const CompressionOptions& options, const QStringList& outputs);
    void cancel();
    bool wasCanceled() const;
    BatchOutcome outcome() const;
private:
    std::shared_ptr<std::atomic_bool> canceled;
};
