#include "MainWindow.h"
#include "utils/Logger.h"
#include "utils/Theme.h"
#include "services/ImageCodec.h"
#include <QTemporaryDir>
#include <QColorSpace>

#include <QApplication>
#include <QCommandLineParser>
#include <QSettings>
#include <QStyle>
#include <QStyleFactory>
#include <QStyleHints>
#include <QUuid>

QString loadInstallationId()
{
    if (!QSettings().contains("uuid")) {
        QString newUUID = QUuid::createUuid().toString(QUuid::WithoutBraces);
        QSettings().setValue("uuid", newUUID);
        return newUUID;
    } else {
        return QSettings().value("uuid").toString();
    }
}


int main(int argc, char* argv[])
{
    QCoreApplication::setOrganizationName("SaeraSoft");
    QCoreApplication::setOrganizationDomain("saerasoft.com");
    QCoreApplication::setApplicationName("Caesium Image Compressor");
    QCoreApplication::setApplicationVersion("2.8.5");

#ifdef NDEBUG
    qInstallMessageHandler(Logger::messageHandler);
#endif

    QApplication a(argc, argv);

    QCommandLineParser parser;
    parser.addVersionOption();
    parser.addOption({ "verify-codecs", "Verify bundled image codecs without opening a window or contacting services." });
    parser.process(a);

    if (parser.isSet("verify-codecs")) {
        QTemporaryDir directory;
        DecodedImage input;
        input.pixels = QImage(32, 24, QImage::Format_RGBA8888);
        input.pixels.fill(QColor(40, 90, 160, 120));
        input.pixels.setColorSpace(QColorSpace::SRgb);
        QStringList formats { "jpg", "png", "webp", "tiff" };
#ifdef CAESIUM_WITH_HEIF
        formats << "avif" << "heic";
#endif
        for (const auto& format : formats) {
            QString error;
            const QString path = directory.filePath("verify." + format);
            if (!ImageCodec::canEncode(format) || !ImageCodec::encode(input, path, format, 80, false, false, error)) {
                qCritical() << format << error;
                return 1;
            }
            try {
                if (ImageCodec::detect(path) != format || ImageCodec::decode(path).pixels.size() != input.pixels.size()) return 1;
            } catch (const std::exception& exception) { qCritical() << exception.what(); return 1; }
        }
        return 0;
    }
    loadTheme(a);

    qInfo() << "---- Starting application ----";
    QString uuid = loadInstallationId();
    qInfo() << "UUID:" << uuid;
    MainWindow w;

    QScreen* spawnScreen = w.screen();
    if (!QGuiApplication::screens().contains(spawnScreen)) {
        QScreen* cursorScreen = QApplication::screenAt(QCursor::pos());
        w.move(cursorScreen->availableGeometry().center() - w.rect().center());
        w.setScreen(cursorScreen);
    } else if (!spawnScreen->availableGeometry().contains(w.pos())) {
        w.move(spawnScreen->availableGeometry().center() - w.rect().center());
    }

    w.show();

    return QApplication::exec();
}
