#pragma once
#include "Importer.h"
#include "models/CImage.h"
#include <QFutureWatcher>
#include <QSet>
#include <atomic>
#include <memory>

struct ImportBatch {
    QList<std::shared_ptr<CImage>> images;
    QStringList errors;
};

class ImportTask : public QObject {
    Q_OBJECT
public:
    explicit ImportTask(QObject* parent = nullptr) : QObject(parent) { }
    ~ImportTask() override { cancel(); watcher.waitForFinished(); }
    QFutureWatcher<ImportBatch> watcher;
    void start(QStringList paths, bool recursive, ImportFilters filters, QSet<QString> known);
    void cancel() { canceled->store(true); }
    bool wasCanceled() const { return canceled->load(); }
private:
    std::shared_ptr<std::atomic_bool> canceled = std::make_shared<std::atomic_bool>(false);
};
