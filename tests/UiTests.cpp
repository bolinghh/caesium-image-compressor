#include "MainWindow.h"
#include "services/ImageCodec.h"
#include "utils/Theme.h"
#include "utils/LanguageManager.h"
#include <QApplication>
#include <QCheckBox>
#include <QAction>
#include <QPalette>
#include <QGraphicsView>
#include <QGraphicsPixmapItem>
#include <QComboBox>
#include <QLineEdit>
#include <QSettings>
#include <QTabWidget>
#include <QTemporaryDir>
#include <QTreeView>
#include <QtTest>

class UiTests : public QObject {
    Q_OBJECT
private slots:
    void realWindowFlow()
    {
        QTemporaryDir settingsRoot;
        QTemporaryDir images;
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsRoot.path());
        QCoreApplication::setOrganizationName("CaesiumTests");
        QCoreApplication::setApplicationName("UiTests");
        QDir().mkpath(CAESIUM_TEST_ARTIFACT_DIR);
        for (int variant : { 1, 2 }) {
            QSettings settings;
            settings.clear();
            settings.setValue("preferences/general/send_usage_reports", false);
            settings.setValue("preferences/general/check_updates_at_startup", false);
            settings.setValue("preferences/general/skip_compression_dialogs", true);
            settings.setValue("preferences/general/theme", 1);
            settings.setValue("preferences/general/theme_variant", variant);
            settings.setValue("preferences/language/locale", variant == 1 ? "en_US" : "zh_CN");
            loadTheme(*qobject_cast<QApplication*>(QApplication::instance()));
            MainWindow window;
            QCOMPARE(LanguageManager::getTranslations().size(), 22);
            QCOMPARE(LanguageManager::getLocaleFromPreferences(QVariant(18)), QString("fi_FI"));
            window.resize(960, 740);
            window.show();
            QTest::qWait(40);
            auto* tree = window.findChild<QTreeView*>("imageList_TreeView");
            QVERIFY(tree);
            QImage image(200, 100, QImage::Format_ARGB32);
            image.fill(Qt::red);
            const QString input = images.filePath(QString("input-%1.png").arg(variant));
            QVERIFY(image.save(input));
            QVERIFY(QMetaObject::invokeMethod(&window, "dropFinished", Q_ARG(QStringList, QStringList { input })));
            QTRY_COMPARE(tree->model()->rowCount(), 1);
            QTRY_VERIFY(!window.findChild<ImportTask*>()->watcher.isRunning());
            tree->selectAll();
            QCOMPARE(tree->selectionModel()->selectedRows().size(), 1);
            window.findChild<QAction*>("actionShow_previews")->setChecked(true);
            QVERIFY(QMetaObject::invokeMethod(&window, "on_actionPreview_triggered"));
            auto* preview = window.findChild<QGraphicsView*>("preview_GraphicsView");
            auto loaded = [preview] {
                for (auto* item : preview->scene()->items())
                    if (auto* image = dynamic_cast<QGraphicsPixmapItem*>(item); image && !image->pixmap().isNull()) return true;
                return false;
            };
            QTRY_VERIFY_WITH_TIMEOUT(loaded(), 5000);
            window.findChild<QCheckBox*>("sameOutputFolderAsInput_CheckBox")->setChecked(false);
            window.findChild<QCheckBox*>("skipIfBigger_CheckBox")->setChecked(false);
            window.findChild<QLineEdit*>("outputFolder_LineEdit")->setText(images.path());
#ifdef CAESIUM_WITH_HEIF
            window.findChild<QComboBox*>("format_ComboBox")->setCurrentIndex(5);
#endif
            QVERIFY(QMetaObject::invokeMethod(&window, "on_actionPreview_triggered"));
            QVERIFY(QMetaObject::invokeMethod(&window, "on_actionPreview_triggered"));
            QVERIFY(QMetaObject::invokeMethod(&window, "on_actionPreview_triggered"));
            auto* compressedPreview = window.findChild<QGraphicsView*>("previewCompressed_GraphicsView");
            auto compressedLoaded = [compressedPreview] {
                for (auto* item : compressedPreview->scene()->items())
                    if (auto* image = dynamic_cast<QGraphicsPixmapItem*>(item); image && !image->pixmap().isNull()) return true;
                return false;
            };
            QTRY_VERIFY_WITH_TIMEOUT(compressedLoaded(), 10000);
            window.findChild<QTabWidget*>("parameters_TabWidget")->setCurrentIndex(3);
            if (variant == 2) QVERIFY(QApplication::palette().color(QPalette::Window).lightness() < 80);
            QVERIFY(window.grab().save(QString(CAESIUM_TEST_ARTIFACT_DIR) + QString("/window-%1.png").arg(variant)));
            QVERIFY(QMetaObject::invokeMethod(&window, "startCompression", Q_ARG(bool, false)));
            auto* task = window.findChild<CompressionTask*>();
            QVERIFY(task);
            QTRY_VERIFY_WITH_TIMEOUT(task->watcher.isFinished(), 15000);
            QCOMPARE(task->outcome().failed, 0);
#ifdef CAESIUM_WITH_HEIF
            QCOMPARE(ImageCodec::detect(images.filePath(QString("input-%1.avif").arg(variant))), QString("avif"));
#endif
            // Verify source-index mapping after the user sorts/selects/removes rows.
            QVERIFY(QMetaObject::invokeMethod(&window, "on_actionRemove_triggered"));
            QCOMPARE(tree->model()->rowCount(), 0);
            window.close();
            QTRY_VERIFY(!window.isVisible());
            // A fresh task may still be encoding when the user closes the window.
            MainWindow closingWindow;
            closingWindow.show();
            QVERIFY(QMetaObject::invokeMethod(&closingWindow, "dropFinished", Q_ARG(QStringList, QStringList { input })));
            auto* imports = closingWindow.findChild<ImportTask*>();
            QTRY_COMPARE(closingWindow.findChild<QTreeView*>("imageList_TreeView")->model()->rowCount(), 1);
            QTRY_VERIFY(!imports->watcher.isRunning());
            closingWindow.findChild<QCheckBox*>("sameOutputFolderAsInput_CheckBox")->setChecked(false);
            closingWindow.findChild<QLineEdit*>("outputFolder_LineEdit")->setText(images.path());
            QVERIFY(QMetaObject::invokeMethod(&closingWindow, "startCompression", Q_ARG(bool, false)));
            auto* closingTask = closingWindow.findChild<CompressionTask*>();
            QVERIFY(closingTask->watcher.future().isStarted());
            closingWindow.close();
            QTRY_VERIFY_WITH_TIMEOUT(!closingWindow.isVisible(), 15000);
            QVERIFY(!closingTask->watcher.isRunning());
            QVERIFY(QFileInfo::exists(input));
        }
    }
};
QTEST_MAIN(UiTests)
#include "UiTests.moc"
