#include "Theme.h"
#include "Utils.h"
#include <QApplication>
#include <QPalette>
#include <QSettings>
#include <QStyleFactory>
#include <QStyleHints>
#include <QStyle>

void loadTheme(QApplication& a)
{
    int themeIndex = QSettings().value("preferences/general/theme", 0).toInt();
    int themeVariantIndex = QSettings().value("preferences/general/theme_variant").toInt();
    if (themeVariantIndex == 1) {
        QApplication::styleHints()->setColorScheme(Qt::ColorScheme::Light);
    } else if (themeVariantIndex == 2) {
        QApplication::styleHints()->setColorScheme(Qt::ColorScheme::Dark);
    }

    // From 2.4.1 and Qt 6.5, the framework can handle the switch between dark and light
    if (themeIndex > 1) {
        themeIndex = 1;
    }

#ifdef Q_OS_WIN
    if (themeIndex == 0) {
        a.setStyleSheet("QSplitter::handle:horizontal{image:url(:/icons/ui/v_handle.png);}QSplitter::handle:vertical{image:url(:/icons/ui/h_handle.png);}QStatusBar::item{border: none;}");
    }
#endif

    if (themeIndex == 1) {
        QApplication::setStyle(QStyleFactory::create(THEMES[themeIndex].theme));
        auto palette = QApplication::style()->standardPalette();
        const bool dark = themeVariantIndex == 2 || (themeVariantIndex == 0
            && QApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark);
        if (dark) {
            const QColor window(25, 25, 25), muted(82, 82, 82), text(241, 245, 249);
            palette.setColor(QPalette::Window, window);
            palette.setColor(QPalette::WindowText, text);
            palette.setColor(QPalette::Base, Qt::black);
            palette.setColor(QPalette::AlternateBase, window);
            palette.setColor(QPalette::ToolTipBase, QColor(37, 99, 235));
            palette.setColor(QPalette::ToolTipText, text);
            palette.setColor(QPalette::Text, text);
            palette.setColor(QPalette::Button, window);
            palette.setColor(QPalette::ButtonText, text);
            palette.setColor(QPalette::Link, QColor(37, 99, 235));
            palette.setColor(QPalette::Highlight, QColor(168, 85, 247));
            palette.setColor(QPalette::HighlightedText, Qt::black);
            for (auto role : { QPalette::ButtonText, QPalette::WindowText, QPalette::Text, QPalette::Light })
                palette.setColor(QPalette::Disabled, role, muted);
        }
        QApplication::setPalette(palette);
    }
}
