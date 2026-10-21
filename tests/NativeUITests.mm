#include <QApplication>
#include <QDir>
#include <QImage>
#include <QSettings>
#include <QTemporaryDir>
#include <QTimer>

extern "C" void CaesiumRunNativeUITests(const char* fixture, const char* artifacts);
extern "C" void CaesiumFinishNativeUITests();
extern "C" void CaesiumNativeUITestsFinished(int status) { QCoreApplication::exit(status); }

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    QApplication::setQuitOnLastWindowClosed(false);
    QTemporaryDir directory;
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, directory.path());
    QCoreApplication::setOrganizationName("CaesiumNativeTests");
    QCoreApplication::setApplicationName("NativeUI");
    QCoreApplication::setApplicationVersion("2.8.5");
    QSettings settings;
    settings.setValue("preferences/general/send_usage_reports", false);
    settings.setValue("preferences/general/check_updates_at_startup", false);
    settings.setValue("preferences/general/skip_compression_dialogs", true);
    settings.setValue("preferences/language/locale", "en_US");
    settings.setValue("compression_options/output/output_folder", directory.path());
    settings.setValue("compression_options/output/output_suffix", "-compressed");
    settings.setValue("compression_options/output/format_id", "jpg");
    settings.setValue("compression_options/output/skip_if_bigger", false);
    QImage image(1200, 800, QImage::Format_RGB32);
    for (int y = 0; y < image.height(); ++y)
        for (int x = 0; x < image.width(); ++x)
            image.setPixelColor(x, y, QColor(x * 255 / image.width(), y * 255 / image.height(), 150));
    const QString fixture = directory.filePath("Landscape with a long filename for native table overflow checks.png");
    if (!image.save(fixture))
        return 1;
    QDir().mkpath(CAESIUM_NATIVE_ARTIFACT_DIR);
    QTimer::singleShot(90000, &app, [] { QCoreApplication::exit(2); });
    CaesiumRunNativeUITests(fixture.toUtf8().constData(), CAESIUM_NATIVE_ARTIFACT_DIR);
    const int result = QApplication::exec();
    CaesiumFinishNativeUITests();
    return result;
}
