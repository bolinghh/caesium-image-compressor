#include "ImporterTests.h"

#include <services/Importer.h>

ImporterTests::ImporterTests()
= default;
ImporterTests::~ImporterTests()
= default;

void ImporterTests::initTestCase()
{
    QVERIFY(true);
}

void ImporterTests::cleanupTestCase()
{
    QVERIFY(true);
}

void ImporterTests::rootFolderTestCase()
{
    QStringList folderMap = QStringList() << "/";
    QString rootFolder = Importer::getRootFolder(folderMap);
    QVERIFY(rootFolder == QString("/"));

    folderMap = QStringList() << "/1" << "/1/1-1";
    rootFolder = Importer::getRootFolder(folderMap);
    QVERIFY(rootFolder == QString("/1"));

    folderMap = QStringList() << "/1/1-1" << "/1/1-2";
    rootFolder = Importer::getRootFolder(folderMap);
    QVERIFY(rootFolder == QString("/1"));

    folderMap = QStringList() << "/1/1-1" << "/1/1-2";
    rootFolder = Importer::getRootFolder(folderMap);
    QVERIFY(rootFolder == QString("/1"));
}