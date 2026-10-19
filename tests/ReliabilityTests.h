#pragma once
#include <QtTest>

class ReliabilityTests : public QObject {
    Q_OBJECT
private slots:
    void outputPlanning();
    void failedReplacementRestoresOriginal();
    void failedRecoveryRetainsBackup();
    void existingOutputIsNeverOverwritten();
    void parametersAndCache();
    void telemetryHasNoPaths();
    void canceledBatch();
    void asyncImportDeduplicates();
    void legacyCompression();
    void modernFormats();
    void localUsageRequest();
    void unsupportedModernImages();
    void metadataAndLossless();
};
