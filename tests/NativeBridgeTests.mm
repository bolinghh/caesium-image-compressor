#import "NativeSession.h"
#include "services/ImageCodec.h"
#include <QApplication>
#include <QElapsedTimer>
#include <QImage>
#include <QSettings>
#include <QTemporaryDir>
#include <QtTest>
#include <functional>
#include <memory>
#include <stdexcept>

namespace {
void check(bool value, const char* message)
{
    if (!value)
        throw std::runtime_error(message);
}
void waitUntil(const std::function<bool()>& ready)
{
    QElapsedTimer timer;
    timer.start();
    while (!ready() && timer.elapsed() < 30000)
        QTest::qWait(10);
    check(ready(), "Timed out waiting for a bridge task");
}
}

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    QTemporaryDir directory;
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, directory.path());
    QCoreApplication::setOrganizationName("CaesiumNativeTests");
    QCoreApplication::setApplicationName("Bridge");
    QCoreApplication::setApplicationVersion("2.8.5");
    try {
        QSettings settings;
        settings.setValue("preferences/general/send_usage_reports", false);
        settings.setValue("preferences/general/check_updates_at_startup", false);
        settings.setValue("preferences/general/skip_compression_dialogs", true);
        settings.setValue("preferences/language/locale", 18);
        settings.setValue("compression_options/output/format", 1);
        settings.setValue("preferences/advaced_import/filename_pattern", "sample");
        @autoreleasepool {
            CSNativeSession* session = [[CSNativeSession alloc] init];
            __block int notices = 0;
            auto closeReady = std::make_shared<bool>(false);
            session.onNotice = ^(NSString*, NSString*) {
                ++notices;
            };
            session.onCloseReady = ^{
                *closeReady = true;
            };
            check([session.settings[@"preferences/language/locale"] isEqual:@"fi_FI"], "Legacy language index was not preserved");
            check([session.settings[@"compression_options/output/format_id"] isEqual:@"jpg"], "Legacy output index was not migrated");
            check([session.settings[@"preferences/advanced_import/filename_pattern"] isEqual:@"sample"], "Legacy filename pattern was not migrated");
            [session setSetting:@"unknown/key" value:@"ignored"];
            check(!settings.contains("unknown/key"), "Bridge accepted an unknown setting");
            [session setSetting:@"compression_options/compression/jpeg_quality" value:@72];
            check(settings.value("compression_options/compression/jpeg_quality").toInt() == 72, "Bridge did not write the compatible settings key");
            [session setSetting:@"compression_options/output/format_id" value:@"png"];
            [session setSetting:@"compression_options/output/output_folder" value:directory.path().toNSString()];
            [session setSetting:@"compression_options/output/output_suffix" value:@"-compressed"];
            [session setSetting:@"compression_options/output/skip_if_bigger" value:@NO];
            QImage image(96, 64, QImage::Format_RGBA8888);
            image.fill(QColor(30, 100, 180, 120));
            const QString first = directory.filePath("sample-one.png");
            const QString second = directory.filePath("sample-two.png");
            check(image.save(first) && image.save(second), "Could not create disposable fixtures");
            NSArray* paths = @[ first.toNSString(), second.toNSString(), first.toNSString() ];
            [session importPaths:paths advanced:NO fromArguments:NO];
            waitUntil([&] { return ![session.snapshot[@"busy"] boolValue]; });
            NSArray* items = session.snapshot[@"items"];
            check(items.count == 2, "Import did not deduplicate");
            NSString* firstID = items[0][@"id"];
            NSString* secondID = items[1][@"id"];
            [session previewID:firstID generate:YES];
            [session previewID:secondID generate:YES];
            waitUntil([&] { return [session.snapshot[@"previewID"] isEqual:secondID] && session.compressedPreview != nil; });
            check(session.originalPreview != nil, "Original preview was not decoded");
            check([session.snapshot[@"previewCompressedBytes"] longLongValue] > 0, "Live preview did not return an estimated file size");
            check([session.snapshot[@"previewCompressedFormat"] isEqual:@"PNG"], "Live preview lost its output format");
            // Render into a known sRGB space; NSBitmapImageRep.colorAt returns a calibrated
            // NSColor whose numerical components are not the original sRGB byte values.
            unsigned char pixel[4] {};
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, srgb, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGContextSetBlendMode(context, kCGBlendModeCopy);
            CGContextSetInterpolationQuality(context, kCGInterpolationNone);
            CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), [session.originalPreview CGImageForProposedRect:nil context:nil hints:nil]);
            CGContextRelease(context);
            CGColorSpaceRelease(srgb);
            check(pixel[3] != 0, "Native image bridge lost alpha");
            const double scale = 255.0 / pixel[3];
            check(std::abs(pixel[0] * scale - 30) < 2 && std::abs(pixel[1] * scale - 100) < 2
                    && std::abs(pixel[2] * scale - 180) < 2 && std::abs(pixel[3] - 120) < 2,
                "Native image bridge changed RGBA channels");
            check([session.snapshot[@"previewError"] length] == 0, "Preview returned an error");
            check(![session requiresOverwriteConfirmation], "Safe output unexpectedly requires overwrite");
            [session compressFailedOnly:NO];
            waitUntil([&] { return ![session.snapshot[@"busy"] boolValue]; });
            items = session.snapshot[@"items"];
            for (NSDictionary* item in items) {
                check([item[@"status"] intValue] == 2, "Single/batch compression failed");
                const auto output = QString::fromNSString(item[@"output"]);
                check(ImageCodec::decode(output).pixels.size() == QSize(96, 64), "Output dimensions changed");
            }
            check(QFileInfo::exists(first) && QFileInfo::exists(second), "Original inputs were modified");
            [session removeIDs:@[ firstID ]];
            items = session.snapshot[@"items"];
            check(items.count == 1 && [items[0][@"id"] isEqual:secondID], "Stable-ID removal addressed the wrong image");
            // A missing input must become a result error and remain eligible for failed-only retry.
            check(QFile::remove(second), "Could not remove fixture");
            [session compressFailedOnly:NO];
            waitUntil([&] { return ![session.snapshot[@"busy"] boolValue]; });
            check([session.snapshot[@"items"][0][@"status"] intValue] == 3, "Missing input was not reported");
            check(image.save(second), "Could not restore fixture");
            [session compressFailedOnly:YES];
            waitUntil([&] { return ![session.snapshot[@"busy"] boolValue]; });
            check([session.snapshot[@"items"][0][@"status"] intValue] == 2, "Failed-only retry did not recover");
            [session setSetting:@"compression_options/output/same_folder_as_input" value:@YES];
            [session setSetting:@"compression_options/output/output_suffix" value:@""];
            check([session requiresOverwriteConfirmation], "Overwrite confirmation predicate was lost");
            [session setSetting:@"compression_options/output/same_folder_as_input" value:@NO];
            [session compressFailedOnly:NO];
            [session requestClose];
            waitUntil([&] { return *closeReady; });
            check(![session.snapshot[@"busy"] boolValue], "Close released an active task");
            check(QFileInfo::exists(second), "Cancel/close removed an original");
            check(notices == 0, "Unexpected modal notice in the bridge flow");
        }
        qInfo() << "Native bridge integration checks passed";
        return 0;
    } catch (const std::exception& error) {
        qCritical() << error.what();
        return 1;
    }
}
