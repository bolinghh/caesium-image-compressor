#include "LanguageManager.h"
#include <QApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSettings>

QList<CsLocale> LanguageManager::getTranslations()
{
    QFile resource(":/locales.json");
    QList<CsLocale> translations;
    if (!resource.open(QIODevice::ReadOnly)) return { { "default", "Default" }, { "en_US", "English (US)" } };
    const auto entries = QJsonDocument::fromJson(resource.readAll()).array();
    for (const auto& value : entries) {
        const auto entry = value.toObject();
        translations.append({ entry.value("locale").toString(), entry.value("label").toString() });
    }
    return translations;
}

QList<CsLocale> LanguageManager::getSortedTranslations()
{
    QList<CsLocale> sortedList = getTranslations();
    std::sort(sortedList.begin(), sortedList.end(), [](const CsLocale& a, const CsLocale& b) {
        if (a.locale == "default" || b.locale == "default") return a.locale == "default" && b.locale != "default";
        return a.label < b.label;
    });
    return sortedList;
}

int LanguageManager::findSortedIndex(const QString& languageId)
{
    QList<CsLocale> sortedList = LanguageManager::getSortedTranslations();
    int index = 0;
    for (const CsLocale& locale : sortedList) {
        if (locale.locale == languageId) {
            return index;
        }
        index++;
    }
    return index;
}

QString LanguageManager::getLocaleFromPreferences(const QVariant& preference)
{
    if (preference.typeId() == QVariant::Int || preference.typeId() == QVariant::LongLong) {
        int localeIndex = preference.toInt();
        return LanguageManager::getTranslations().value(localeIndex, { "default", "Default" }).locale;
    } else if (preference.typeId() == QVariant::String) {
        return preference.toString();
    } else {
        return "default";
    }
}

void LanguageManager::loadLocale(QTranslator* translator)
{
    QString localeId = LanguageManager::getLocaleFromPreferences(QSettings().value("preferences/language/locale", "default"));
    QLocale locale = QLocale();
    if (localeId != "default") {
        locale = QLocale(localeId);
    }
    if (translator->load(locale, QLatin1String("caesium"), QLatin1String("_"), QLatin1String(":/i18n"))) {
        QCoreApplication::installTranslator(translator);
        QApplication::setLayoutDirection(locale.textDirection());
    }
}
