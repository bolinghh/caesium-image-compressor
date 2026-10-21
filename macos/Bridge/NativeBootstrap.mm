#import "NativeSession.h"
#include <QApplication>
#include "utils/Logger.h"

static id closeObserver;

void startNativeInterface()
{
    // Qt continues to own NSApplication and the event loop. Do not install a second app delegate.
    QApplication::setQuitOnLastWindowClosed(false);
    closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"CaesiumNativeCloseReady"
                                                                      object:nil
                                                                       queue:[NSOperationQueue mainQueue]
                                                                  usingBlock:^(NSNotification*) {
                                                                      QCoreApplication::quit();
                                                                  }];
    (void)closeObserver;
    CaesiumShowNativeUI();
}

void stopNativeInterface()
{
    CaesiumCloseNativeUI();
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    closeObserver = nil;
    if (!QCoreApplication::arguments().contains("--native-ui-preview")) {
        qInfo() << "---- Closing application ----";
        Logger::closeLogFile();
        Logger::cleanOldLogs();
    }
}
