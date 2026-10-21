#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Foundation-only boundary. All methods and callbacks run on the application main thread.
// C++ objects and task snapshots remain owned by the implementation.
@interface CSNativeSession : NSObject
@property (nonatomic, copy, nullable) void (^onChange)(NSDictionary<NSString*, id>* snapshot);
@property (nonatomic, copy, nullable) void (^onNotice)(NSString* title, NSString* detail);
@property (nonatomic, copy, nullable) void (^onCloseReady)(void);
@property (nonatomic, copy, nullable) void (^onQuitRequested)(void);
@property (nonatomic, readonly, copy) NSDictionary<NSString*, id>* settings;
@property (nonatomic, readonly, copy) NSArray<NSDictionary<NSString*, NSString*>*>* locales;
@property (nonatomic, readonly, copy) NSArray<NSString*>* formats;
@property (nonatomic, readonly, copy) NSArray<NSString*>* launchPaths;
@property (nonatomic, readonly, copy) NSDictionary<NSString*, id>* snapshot;
@property (nonatomic, readonly, nullable) NSImage* originalPreview;
@property (nonatomic, readonly, nullable) NSImage* compressedPreview;
@property (nonatomic, readonly) BOOL updaterAvailable;
@property (nonatomic, readonly) BOOL rightToLeft;
- (void)setSetting:(NSString*)key value:(id)value;
- (NSString*)translate:(NSString*)text context:(NSString*)context;
- (void)importPaths:(NSArray<NSString*>*)paths advanced:(BOOL)advanced fromArguments:(BOOL)fromArguments;
- (void)removeIDs:(NSArray<NSString*>*)identifiers;
- (BOOL)requiresOverwriteConfirmation;
- (void)compressFailedOnly:(BOOL)failedOnly;
- (void)cancel;
- (void)previewID:(NSString*)identifier generate:(BOOL)generate;
- (void)invalidatePreview;
- (BOOL)canEncode:(NSString*)format lossless:(BOOL)lossless;
- (BOOL)requestClose;
- (void)checkForUpdates;
- (void)startPlatformServices;
- (NSString*)usageData;
@end

#ifdef __cplusplus
extern "C" {
#endif
void CaesiumShowNativeUI(void);
void CaesiumCloseNativeUI(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
