#import "NativeSession.h"
#include "NativeDefaults.h"
#include "network/NetworkOperations.h"
#include "services/CompressionParameters.h"
#include "services/CompressionTask.h"
#include "services/ImageCodec.h"
#include "services/ImportTask.h"
#include "services/OutputFiles.h"
#include "utils/LanguageManager.h"
#include "utils/PostCompressionActions.h"
#ifdef HAVE_SPARKLE
#include "updater/osx/SparkleAutoUpdater.h"
#endif
#include <QApplication>
#include <QColorSpace>
#include <QCommandLineParser>
#include <QDir>
#include <QElapsedTimer>
#include <QEvent>
#include <QJsonDocument>
#include <QSettings>
#include <QStandardPaths>
#include <QThreadPool>
#include <QTimer>
#include <QTranslator>
#include <QtConcurrent>
#include <algorithm>
#include <memory>
#include <stdexcept>

namespace {
NSString* ns(const QString& value) { return value.toNSString(); }
QString qt(NSString* value) { return QString::fromNSString(value); }

struct PreviewResult {
    QImage original;
    QImage compressed;
    QString error;
    bool generated = false;
    qint64 originalBytes = 0;
    qint64 compressedBytes = 0;
    QString originalFormat;
    QString compressedFormat;
};

NSImage* nativeImage(const QImage& source)
{
    if (source.isNull())
        return nil;
    const QImage image = source.convertToFormat(QImage::Format_RGBA8888);
    NSData* data = [NSData dataWithBytes:image.constBits() length:image.sizeInBytes()];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    const QByteArray icc = source.colorSpace().iccProfile();
    CGColorSpaceRef color = icc.isEmpty() ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
                                          : CGColorSpaceCreateWithICCData((__bridge CFDataRef)[NSData dataWithBytes:icc.constData() length:icc.size()]);
    if (!color) {
        CGDataProviderRelease(provider);
        return nil;
    }
    CGImageRef cgImage = CGImageCreate(image.width(), image.height(), 8, 32, image.bytesPerLine(), color,
        kCGImageAlphaLast, provider, nullptr, false, kCGRenderingIntentDefault);
    NSImage* result = cgImage ? [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize] : nil;
    if (cgImage)
        CGImageRelease(cgImage);
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    return result;
}

struct NativeState : QObject {
    ImportTask importer;
    CompressionTask compressor;
    QFutureWatcher<QStringList> planner;
    QList<QFutureWatcher<PreviewResult>*> previews;
    QList<CImage> images;
    QStringList errors;
    QStringList importRoots;
    QTranslator translator;
    NetworkOperations network;
    QElapsedTimer timer;
    CompressionSummary summary;
    CompressionOptions activeOptions {};
    quint64 previewRequest = 0;
    QString previewID;
    QString previewError;
    bool previewGenerated = false;
    qint64 previewOriginalBytes = 0;
    qint64 previewCompressedBytes = 0;
    QString previewOriginalFormat;
    QString previewCompressedFormat;
    bool closing = false;
    bool closeNotified = false;
    bool publishPending = false;
    bool compressAfterImport = false;
    bool planningCanceled = false;
    bool servicesStarted = false;
    int completed = 0;
    int total = 0;
    QString phase = "idle";
    std::function<void()> quitRequested;
    std::function<void()> pendingCompression;
#ifdef HAVE_SPARKLE
    std::unique_ptr<SparkleAutoUpdater> updater;
#endif
    // Watcher futures may finish before their queued result/finished signals are consumed.
    // Keep commands locked until the main-thread completion handler has applied every result.
    bool busy() const { return phase != "idle"; }
    bool active() const { return busy() || !previews.isEmpty(); }
    bool eventFilter(QObject*, QEvent* event) override
    {
        if (event->type() == QEvent::Quit && !closeNotified && quitRequested) {
            quitRequested();
            return true;
        }
        return false;
    }
    ~NativeState() override
    {
        if (qApp)
            qApp->removeEventFilter(this);
        importer.cancel();
        compressor.cancel();
        importer.watcher.waitForFinished();
        planner.waitForFinished();
        compressor.watcher.waitForFinished();
        for (auto* preview : previews) {
            preview->waitForFinished();
            delete preview;
        }
        QCoreApplication::removeTranslator(&translator);
    }
};
}

@interface CSNativeSession ()
- (void)publish;
- (void)finishCloseIfReady;
- (CompressionOptions)options;
@end

@implementation CSNativeSession {
    std::unique_ptr<NativeState> _state;
    NSImage* _originalPreview;
    NSImage* _compressedPreview;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _state = std::make_unique<NativeState>();
    QSettings settings;
    CompressionParameters::storedFormatIndex();
    if (!settings.contains("compression_options/output/move_original_file"))
        settings.setValue("compression_options/output/move_original_file", settings.value("compression_options/output/move_original_to_trash", false));
    if (!settings.contains("preferences/advanced_import/filename_pattern"))
        settings.setValue("preferences/advanced_import/filename_pattern", settings.value("preferences/advaced_import/filename_pattern", ""));
    for (const auto& suffix : { "enabled", "condition", "value", "unit" }) {
        const QString key = QString("preferences/advaced_import/skip_by_size/") + suffix;
        if (!settings.contains(key) && settings.contains(QString("preferences/general/skip_by_size/") + suffix))
            settings.setValue(key, settings.value(QString("preferences/general/skip_by_size/") + suffix));
    }
    LanguageManager::loadLocale(&_state->translator);
    QImageReader::setAllocationLimit(1024);
    __weak CSNativeSession* weak = self;
    auto* state = _state.get();
    state->quitRequested = [weak] { CSNativeSession* session = weak; if (session.onQuitRequested) session.onQuitRequested(); };
    qApp->installEventFilter(state);
    QObject::connect(&state->importer.watcher, &QFutureWatcher<ImportBatch>::resultReadyAt, state, [weak](int index) {
        CSNativeSession* session = weak;
        if (!session)
            return;
        auto& s = *session->_state;
        const auto batch = s.importer.watcher.resultAt(index);
        s.errors.append(batch.errors);
        for (const auto& image : batch.images)
            s.images.append(*image);
        [session publish];
    });
    QObject::connect(&state->importer.watcher, &QFutureWatcherBase::finished, state, [weak] {
        CSNativeSession* session = weak;
        if (!session)
            return;
        auto& s = *session->_state;
        s.phase = "idle";
        if (!s.closing && !s.errors.isEmpty() && session.onNotice)
            session.onNotice([session translate:@"Some images could not be imported" context:@"MainWindow"], ns(s.errors.join('\n')));
        const bool start = s.compressAfterImport && !s.importer.wasCanceled() && !s.closing;
        s.compressAfterImport = false;
        [session publish];
        [session finishCloseIfReady];
        // The native controller performs the same overwrite confirmation as a manual start.
        if (start && session.onChange)
            session.onChange(@{ @"requestCompression" : @YES });
    });
    QObject::connect(&state->compressor.watcher, &QFutureWatcher<CompressionResult>::resultReadyAt, state, [weak](int index) {
        CSNativeSession* session = weak;
        if (!session)
            return;
        auto& s = *session->_state;
        const auto result = s.compressor.watcher.resultAt(index);
        if (result.executed && result.row >= 0 && result.row < s.images.size())
            s.images[result.row] = *result.image;
        ++s.completed;
        [session publish];
    });
    QObject::connect(&state->compressor.watcher, &QFutureWatcherBase::finished, state, [weak] {
        CSNativeSession* session = weak;
        if (!session)
            return;
        auto& s = *session->_state;
        const auto outcome = s.compressor.outcome();
        s.phase = "idle";
        s.summary.totalCompressedSize = 0;
        double executedBytes = 0;
        for (const auto& result : s.compressor.watcher.future().results()) {
            if (result.executed) {
                executedBytes += result.image->getOriginalSize();
                s.summary.totalCompressedSize += result.image->getCompressedSize();
            }
        }
        s.summary.totalCompressedSize += s.summary.totalUncompressedSize - executedBytes;
        s.summary.elapsedTime = s.timer.elapsed();
        [session publish];
        if (s.closing) {
            [session finishCloseIfReady];
            return;
        }
        QSettings settings;
        if (settings.value("preferences/general/send_usage_reports", true).toBool())
            s.network.sendUsageReport(s.summary);
        if (outcome.allowsCompletionAction()) {
            const auto action = static_cast<PostCompressionAction>(settings.value("preferences/general/post_compression_action", 0).toInt());
            if (action != PostCompressionAction::NO_ACTION) {
                PostCompressionActions::runAction(action, s.activeOptions.outputPath);
                return;
            }
        }
        NSString* title = [session translate:outcome.canceled ? @"Compression canceled" : outcome.failed ? @"Compression finished with errors"
                : outcome.warnings                                                                       ? @"Compression finished with warnings"
                                                                                                         : @"Compression finished!"
                                     context:@"MainWindow"];
        NSString* detail = [NSString stringWithFormat:@"%@: %d\n%@: %d\n%@: %d\n%@: %d\n%@: %d\n%@: %@\n%@: %@",
            [session translate:@"Successful"
                       context:@"MainWindow"],
            outcome.succeeded,
            [session translate:@"Failed"
                       context:@"MainWindow"],
            outcome.failed,
            [session translate:@"Warnings"
                       context:@"MainWindow"],
            outcome.warnings,
            [session translate:@"Skipped"
                       context:@"MainWindow"],
            outcome.skipped,
            [session translate:@"Not executed"
                       context:@"MainWindow"],
            outcome.notExecuted,
            [session translate:@"Saved"
                       context:@"MainWindow"],
            ns(toHumanSize(s.summary.totalUncompressedSize - s.summary.totalCompressedSize)),
            [session translate:@"Elapsed time"
                       context:@"MainWindow"],
            ns(QString::number(s.summary.elapsedTime / 1000.0, 'f', 1) + " s")];
        if (!settings.value("preferences/general/skip_compression_dialogs", false).toBool() && session.onNotice)
            session.onNotice(title, detail);
        if (session.onChange)
            session.onChange(@{ @"batchFinished" : @YES, @"summaryTitle" : title, @"summaryDetail" : detail });
    });
    return self;
}

- (NSDictionary*)settings
{
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    QSettings settings;
    const auto defaults = nativeDefaults();
    for (auto it = defaults.cbegin(); it != defaults.cend(); ++it) {
        const QVariant value = settings.value(it.key(), it.value());
        result[ns(it.key())] = it.value().typeId() == QMetaType::QString ? (id)ns(value.toString()) : (id) @(value.toInt());
    }
    result[@"preferences/language/locale"] = ns(LanguageManager::getLocaleFromPreferences(settings.value("preferences/language/locale", "default")));
    // Preserve a stored unavailable format ID; Swift disables starting until a supported format is chosen.
    result[@"application/version"] = ns(QCoreApplication::applicationVersion());
    result[@"application/uuid"] = ns(settings.value("uuid").toString());
    result[@"application/max_threads"] = @(qMax(1, QThread::idealThreadCount()));
    return result;
}

- (void)setSetting:(NSString*)key value:(id)value
{
    const QString name = qt(key);
    const auto defaults = nativeDefaults();
    if (_state->closing || !defaults.contains(name))
        return;
    // Processing/preferences remain immutable while a batch is running, as in the Qt UI.
    if (_state->busy() && !name.startsWith("mainwindow/") && !name.startsWith("macos/"))
        return;
    QSettings().setValue(name, defaults.value(name).typeId() == QMetaType::QString ? QVariant(qt([value description])) : QVariant([value intValue]));
    if (name == "preferences/language/locale") {
        QCoreApplication::removeTranslator(&_state->translator);
        LanguageManager::loadLocale(&_state->translator);
    }
    if (name == "preferences/general/send_usage_reports" && [value boolValue]) {
        if (!QSettings().contains("access_token"))
            _state->network.requestToken();
        else
            _state->network.updateSystemInfo();
    }
    if (name == "preferences/general/check_updates_at_startup") {
#ifdef HAVE_SPARKLE
        if (_state->updater)
            _state->updater->setCheckForUpdatesAutomatically([value boolValue]);
#endif
    }
}

- (NSArray*)locales
{
    NSMutableArray* result = [NSMutableArray array];
    for (const auto& locale : LanguageManager::getSortedTranslations())
        [result addObject:@{ @"id" : ns(locale.locale), @"label" : ns(locale.label) }];
    return result;
}

- (NSArray*)formats
{
    NSMutableArray* result = [NSMutableArray array];
    for (int index = 0; index < getOutputSupportedFormats().size(); ++index)
        [result addObject:ns(CompressionParameters::formatId(index))];
    return result;
}

- (NSArray*)launchPaths
{
    QCommandLineParser parser;
    parser.addVersionOption();
    parser.addOption({ "verify-codecs", "Verify codecs" });
    parser.addOption({ "qt-ui", "Qt interface" });
    parser.addOption({ "native-ui-preview", "Mock interface" });
    parser.parse(QCoreApplication::arguments());
    NSMutableArray* result = [NSMutableArray array];
    for (const auto& path : parser.positionalArguments())
        [result addObject:ns(path)];
    return result;
}

- (NSString*)translate:(NSString*)text context:(NSString*)context
{
    QString translated = QCoreApplication::translate(context.UTF8String, text.UTF8String);
    if (translated == qt(text)) {
        for (const auto* fallback : { "MainWindow", "QIODevice", "PreferencesDialog", "AdvancedImportDialog", "AboutDialog", "CImageTreeModel" }) {
            translated = QCoreApplication::translate(fallback, text.UTF8String);
            if (translated != qt(text))
                break;
        }
    }
    return ns(translated);
}

- (NSDictionary*)snapshot
{
    NSMutableArray* items = [NSMutableArray array];
    for (const auto& image : _state->images) {
        [items addObject:@{ @"id" : ns(image.getHashedFullPath()), @"name" : ns(image.getFileName()), @"path" : ns(image.getFullPath()), @"output" : ns(image.getCompressedFullPath()), @"bytes" : @(image.getOriginalSize()), @"outputBytes" : @(image.getCompressedSize()), @"resolution" : ns(image.getResolution()), @"saved" : @(100 - image.getRatio() * 100), @"status" : @(int(image.getStatus())), @"detail" : ns(image.getFormattedStatus()) }];
    }
    return @{ @"items" : items, @"busy" : @(_state->busy()), @"phase" : ns(_state->phase), @"closing" : @(_state->closing), @"completed" : @(_state->completed), @"total" : @(_state->total), @"previewID" : ns(_state->previewID), @"previewLoading" : @(!_state->previews.isEmpty()), @"previewGenerated" : @(_state->previewGenerated), @"previewError" : ns(_state->previewError),
        @"previewOriginalBytes" : @(_state->previewOriginalBytes), @"previewCompressedBytes" : @(_state->previewCompressedBytes),
        @"previewOriginalFormat" : ns(_state->previewOriginalFormat), @"previewCompressedFormat" : ns(_state->previewCompressedFormat) };
}

- (void)publish
{
    if (_state->publishPending)
        return;
    _state->publishPending = true;
    __weak CSNativeSession* weak = self;
    QTimer::singleShot(40, _state.get(), [weak] {
        CSNativeSession* session = weak;
        if (!session)
            return;
        session->_state->publishPending = false;
        if (session.onChange)
            session.onChange(session.snapshot);
    });
}

- (CompressionOptions)options
{
    QSettings settings;
    auto value = [&](const char* name) { return settings.value(name, nativeDefaults().value(name)); };
    CompressionOptions o {};
    o.outputPath = value("compression_options/output/output_folder").toString();
    o.suffix = value("compression_options/output/output_suffix").toString();
    o.basePath = Importer::getRootFolder(_state->importRoots);
    o.format = CompressionParameters::storedFormatIndex();
    o.lossless = value("compression_options/compression/lossless").toBool();
    o.keepMetadata = value("compression_options/compression/keep_metadata").toBool();
    o.keepStructure = value("compression_options/compression/keep_structure").toBool();
    o.fitTo = value("compression_options/resize/fit_to").toInt();
    o.resize = o.fitTo != NO_RESIZE;
    o.width = value("compression_options/resize/width").toInt();
    o.height = value("compression_options/resize/height").toInt();
    o.size = value("compression_options/resize/size").toInt();
    o.doNotEnlarge = value("compression_options/resize/do_not_enlarge").toBool();
    o.sameFolderAsInput = value("compression_options/output/same_folder_as_input").toBool();
    o.skipIfBigger = value("compression_options/output/skip_if_bigger").toBool();
    o.moveOriginalFile = value("compression_options/output/move_original_file").toBool();
    o.moveOriginalFileDestination = value("compression_options/output/move_original_file_destination").toInt();
    o.jpegQuality = value("compression_options/compression/jpeg_quality").toInt();
    o.jpegChromaSubsampling = value("compression_options/compression/jpeg_chroma_subsampling").toInt();
    o.jpegProgressive = value("compression_options/compression/jpeg_progressive").toBool();
    o.pngQuality = value("compression_options/compression/png_quality").toInt();
    o.pngOptimizationLevel = value("compression_options/compression/png_optimization_level").toInt();
    o.webpQuality = value("compression_options/compression/webp_quality").toInt();
    o.tiffMethod = value("compression_options/compression/tiff_method").toInt();
    // The persisted Qt slider uses 1..3, whereas codec parameters use 3..9.
    o.tiffDeflateLevel = value("compression_options/compression/tiff_deflate_level").toInt() * 3;
    o.avifQuality = value("compression_options/compression/avif_quality").toInt();
    o.heicQuality = value("compression_options/compression/heic_quality").toInt();
    o.keepDates = value("compression_options/output/keep_dates").toInt() != 0;
    o.datesMap = { value("compression_options/output/keep_creation_date").toBool(), value("compression_options/output/keep_last_modified_date").toBool(), value("compression_options/output/keep_last_access_date").toBool() };
    o.compressionMode = static_cast<CompressionMode>(value("compression_options/compression/mode").toInt());
    o.maxOutputSize = { static_cast<MaxOutputSizeUnit>(value("compression_options/compression/max_output_size_unit").toInt()), size_t(value("compression_options/compression/max_output_size").toULongLong()) };
    return CompressionParameters::normalize(o);
}

- (void)importPaths:(NSArray<NSString*>*)paths advanced:(BOOL)advanced fromArguments:(BOOL)fromArguments
{
    if (_state->busy() || _state->closing || paths.count == 0)
        return;
    [self invalidatePreview];
    QStringList inputs;
    for (NSString* path in paths) {
        inputs.append(qt(path));
        QFileInfo info(qt(path));
        _state->importRoots.append(info.isDir() ? info.absoluteFilePath() : info.absolutePath());
    }
    QSet<QString> known;
    for (const auto& image : _state->images)
        known.insert(OutputFiles::key(image.getFullPath()));
    QSettings settings;
    ImportFilters filters {};
    if (advanced) {
        filters.skipBySizeFilter = { settings.value("preferences/advaced_import/skip_by_size/enabled", false).toBool(), settings.value("preferences/advaced_import/skip_by_size/unit", 1).toInt(), settings.value("preferences/advaced_import/skip_by_size/condition", 0).toInt(), settings.value("preferences/advaced_import/skip_by_size/value", 500).toInt() };
        const QString pattern = settings.value("preferences/advanced_import/filename_pattern", "").toString();
        filters.filenameRegexFilter = { !pattern.isEmpty(), pattern };
    }
    _state->errors.clear();
    _state->phase = "importing";
    _state->compressAfterImport = fromArguments && settings.value("preferences/general/args_behaviour", 0).toInt() == IMPORT_AND_COMPRESS;
    _state->importer.start(inputs, settings.value(advanced ? "preferences/advaced_import/import_subfolders" : "preferences/general/import_subfolders", !advanced).toBool(), filters, known);
    [self publish];
}

- (void)removeIDs:(NSArray<NSString*>*)identifiers
{
    if (_state->busy() || _state->closing)
        return;
    [self invalidatePreview];
    QSet<QString> ids;
    for (NSString* identifier in identifiers)
        ids.insert(qt(identifier));
    for (qsizetype index = _state->images.size(); index-- > 0;)
        if (ids.contains(_state->images[index].getHashedFullPath()))
            _state->images.removeAt(index);
    _state->importRoots.clear();
    for (const auto& image : _state->images)
        _state->importRoots.append(image.getDirectory());
    [self publish];
}

- (BOOL)requiresOverwriteConfirmation
{
    const auto o = [self options];
    if (!o.sameFolderAsInput || !o.suffix.isEmpty())
        return NO;
    for (const auto& image : _state->images)
        if (o.format == 0 || CompressionParameters::formatId(o.format) == image.getFormat())
            return YES;
    return NO;
}

- (void)compressFailedOnly:(BOOL)failedOnly
{
    if (_state->busy() || _state->closing || _state->images.isEmpty())
        return;
    const auto o = [self options];
    const QString format = CompressionParameters::formatId(o.format);
    if (!o.sameFolderAsInput && o.outputPath.isEmpty()) {
        if (self.onNotice)
            self.onNotice([self translate:@"Output" context:@"MainWindow"], [self translate:@"Please select an output folder" context:@"MainWindow"]);
        return;
    }
    if (![self.formats containsObject:self.settings[@"compression_options/output/format_id"]] || (format != "same" && !ImageCodec::canEncode(format, o.lossless))) {
        if (self.onNotice)
            self.onNotice(@"Unsupported format", @"Choose an available output format and encoding mode.");
        return;
    }
    QList<std::pair<int, CImage>> work;
    QStringList inputs;
    _state->summary = {};
    for (int row = 0; row < _state->images.size(); ++row) {
        const auto& image = _state->images[row];
        inputs.append(image.getFullPath());
        if (!failedOnly || image.getStatus() == CImageStatus::ERROR) {
            work.append({ row, image });
            _state->summary.totalUncompressedSize += image.getOriginalSize();
        }
    }
    if (work.isEmpty())
        return;
    [self invalidatePreview];
    QSettings settings;
    auto* pool = QThreadPool::globalInstance();
    pool->setMaxThreadCount(settings.value("preferences/general/multithreading", true).toBool() ? qBound(1, settings.value("preferences/general/multithreading_max_threads", QThread::idealThreadCount()).toInt(), 64) : 1);
    pool->setThreadPriority(static_cast<QThread::Priority>(qBound(0, settings.value("preferences/general/threads_priority", int(QThread::NormalPriority)).toInt(), int(QThread::TimeCriticalPriority))));
    _state->activeOptions = o;
    _state->completed = 0;
    _state->total = work.size();
    _state->summary.totalImages = work.size();
    _state->planningCanceled = false;
    _state->phase = "planning";
    _state->timer.start();
    __weak CSNativeSession* weak = self;
    QObject::disconnect(&_state->planner, nullptr, _state.get(), nullptr);
    QObject::connect(&_state->planner, &QFutureWatcherBase::finished, _state.get(), [weak, work, o] {
        CSNativeSession* session = weak;
        if (!session)
            return;
        auto& s = *session->_state;
        if (s.closing || s.planningCanceled) {
            s.phase = "idle";
            [session publish];
            [session finishCloseIfReady];
            return;
        }
        try {
            const auto outputs = s.planner.result();
            s.pendingCompression = [weak, work, o, outputs] {
                CSNativeSession* current = weak;
                if (!current)
                    return;
                auto& state = *current->_state;
                if (state.closing || state.planningCanceled)
                    state.phase = "idle";
                else {
                    state.compressor.startPlanned(work, o, outputs);
                    state.phase = "compressing";
                }
                [current publish];
                [current finishCloseIfReady];
            };
            // A preview may still be reading an original which this batch will move/replace.
            // Drain that read before starting compression, without blocking the main thread.
            if (s.previews.isEmpty()) {
                auto start = std::move(s.pendingCompression);
                start();
            }
        } catch (const std::exception& error) {
            s.phase = "idle";
            if (session.onNotice)
                session.onNotice(@"Compression failed", ns(QString::fromUtf8(error.what())));
        }
        [session publish];
    });
    _state->planner.setFuture(QtConcurrent::run([inputs, o] { return OutputFiles::plan(inputs, o); }));
    [self publish];
}

- (void)cancel
{
    _state->importer.cancel();
    _state->compressor.cancel();
    _state->planningCanceled = true;
    _state->compressAfterImport = false;
    if (_state->busy())
        _state->phase = "canceling";
    [self publish];
}

- (void)invalidatePreview
{
    ++_state->previewRequest;
    _state->previewID.clear();
    _state->previewError.clear();
    _state->previewOriginalBytes = 0;
    _state->previewCompressedBytes = 0;
    _state->previewOriginalFormat.clear();
    _state->previewCompressedFormat.clear();
    _originalPreview = nil;
    _compressedPreview = nil;
    [self publish];
}

- (void)previewID:(NSString*)identifier generate:(BOOL)generate
{
    if (_state->closing || _state->busy())
        return;
    const auto found = std::find_if(_state->images.cbegin(), _state->images.cend(), [&](const CImage& image) { return image.getHashedFullPath() == qt(identifier); });
    if (found == _state->images.cend()) {
        [self invalidatePreview];
        return;
    }
    // Coalesce rapid selections; keep at most one image decode/encode task alive.
    const quint64 request = ++_state->previewRequest;
    const CImage image = *found;
    const auto o = [self options];
    _state->previewID = qt(identifier);
    _state->previewError.clear();
    _state->previewGenerated = generate;
    _state->previewOriginalBytes = image.getOriginalSize();
    _state->previewCompressedBytes = 0;
    _state->previewOriginalFormat = image.getFormat().toUpper();
    _state->previewCompressedFormat.clear();
    _originalPreview = nil;
    _compressedPreview = nil;
    __weak CSNativeSession* weak = self;
    QTimer::singleShot(120, _state.get(), [weak, request, image, o, generate] {
        CSNativeSession* session = weak;
        if (!session || session->_state->closing || request != session->_state->previewRequest)
            return;
        if (!session->_state->previews.isEmpty()) {
            auto* pending = session->_state->previews.last();
            QObject::connect(pending, &QFutureWatcherBase::finished, session->_state.get(), [weak, request, image, generate] {
                CSNativeSession* current = weak;
                if (current && request == current->_state->previewRequest && !current->_state->closing)
                    [current previewID:ns(image.getHashedFullPath()) generate:generate];
            });
            return;
        }
        auto* watcher = new QFutureWatcher<PreviewResult>(session->_state.get());
        session->_state->previews.append(watcher);
        QObject::connect(watcher, &QFutureWatcherBase::finished, session->_state.get(), [weak, watcher, request] {
            CSNativeSession* current = weak;
            if (!current)
                return;
            auto& s = *current->_state;
            s.previews.removeOne(watcher);
            if (request == s.previewRequest && !s.closing) {
                const auto result = watcher->result();
                current->_originalPreview = nativeImage(result.original);
                current->_compressedPreview = nativeImage(result.compressed);
                s.previewError = result.error;
                s.previewGenerated = result.generated;
                s.previewOriginalBytes = result.originalBytes;
                s.previewCompressedBytes = result.compressedBytes;
                s.previewOriginalFormat = result.originalFormat;
                s.previewCompressedFormat = result.compressedFormat;
            }
            watcher->deleteLater();
            if (s.previews.isEmpty() && s.pendingCompression) {
                auto start = std::move(s.pendingCompression);
                start();
            }
            [current publish];
            [current finishCloseIfReady];
        });
        watcher->setFuture(QtConcurrent::run([image, o, generate] {
            PreviewResult result;
            try {
                result.original = ImageCodec::decode(image.getFullPath()).pixels;
                result.originalBytes = image.getOriginalSize();
                result.originalFormat = image.getFormat().toUpper();
                QString output = image.getCompressedFullPath();
                if (generate) {
                    if (!image.preview(o))
                        throw std::runtime_error("Preview generation failed");
                    output = image.getTemporaryPreviewFullPath(o);
                    result.generated = true;
                }
                if (!output.isEmpty()) {
                    result.compressed = ImageCodec::decode(output).pixels;
                    result.compressedBytes = QFileInfo(output).size();
                    result.compressedFormat = ImageCodec::detect(output).toUpper();
                }
            } catch (const std::exception& error) {
                result.error = QString::fromUtf8(error.what());
            }
            return result;
        }));
        [session publish];
    });
    [self publish];
}

- (NSImage*)originalPreview
{
    return _originalPreview;
}
- (NSImage*)compressedPreview
{
    return _compressedPreview;
}
- (BOOL)canEncode:(NSString*)format lossless:(BOOL)lossless
{
    return [format isEqualToString:@"same"] || ImageCodec::canEncode(qt(format), lossless);
}

- (void)finishCloseIfReady
{
    if (!_state->closing || _state->active() || _state->closeNotified)
        return;
    _state->closeNotified = true;
    QSettings().sync();
    QDir(QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/previews-v2").removeRecursively();
    if (self.onCloseReady)
        self.onCloseReady();
}

- (BOOL)requestClose
{
    _state->closing = true;
    ++_state->previewRequest;
    [self cancel];
    [self finishCloseIfReady];
    return !_state->active();
}

- (BOOL)updaterAvailable
{
#ifdef HAVE_SPARKLE
    return YES;
#else
    return NO;
#endif
}

- (BOOL)rightToLeft
{
    const QString locale = LanguageManager::getLocaleFromPreferences(QSettings().value("preferences/language/locale", "default"));
    return (locale == "default" ? QLocale::system() : QLocale(locale)).textDirection() == Qt::RightToLeft;
}

- (void)checkForUpdates
{
#ifdef HAVE_SPARKLE
    if (!_state->updater)
        _state->updater = std::make_unique<SparkleAutoUpdater>("https://saerasoft.com/repository/com.saerasoft.caesium/osx/appcast.xml");
    _state->updater->checkForUpdates();
#endif
}

- (void)startPlatformServices
{
    if (_state->servicesStarted)
        return;
    _state->servicesStarted = true;
    QSettings settings;
    if (settings.value("preferences/general/send_usage_reports", true).toBool()) {
        if (!settings.contains("access_token"))
            _state->network.requestToken();
        else
            _state->network.updateSystemInfo();
    }
    if (settings.value("preferences/general/check_updates_at_startup", true).toBool()) {
#ifdef HAVE_SPARKLE
        _state->updater = std::make_unique<SparkleAutoUpdater>("https://saerasoft.com/repository/com.saerasoft.caesium/osx/appcast.xml");
        _state->updater->setCheckForUpdatesAutomatically(true);
        _state->updater->checkForUpdates();
#endif
    }
}

- (NSString*)usageData
{
    QJsonObject compression {
        { "uuid", QSettings().value("uuid").toString() }, { "totalFiles", "..." }, { "uncompressedSize", "..." },
        { "compressedSize", "..." }, { "elapsedTime", "..." }, { "compressionOptions", getCompressionOptionsAsJSON() }
    };
    return ns(QJsonDocument(getSystemData()).toJson(QJsonDocument::Indented) + '\n' + QJsonDocument(compression).toJson(QJsonDocument::Indented));
}
@end
