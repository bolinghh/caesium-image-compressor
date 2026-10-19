#include <QtTest>

#include "ImporterTests.h"
#include "ReliabilityTests.h"
#include <QApplication>

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("CaesiumTests");
    QCoreApplication::setApplicationName("Reliability");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QTemporaryDir settings;
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settings.path());
    int status = 0;
    auto ASSERT_TEST = [&status, argc, argv](QObject* obj) {
        status |= QTest::qExec(obj, argc, argv);
        delete obj;
    };

    ASSERT_TEST(new ImporterTests());
    ASSERT_TEST(new ReliabilityTests());

    return status;
}