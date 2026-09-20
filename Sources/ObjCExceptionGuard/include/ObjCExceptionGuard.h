#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError instead of letting it unwind
/// through Swift frames (which aborts the process). Swift cannot catch NSException on its own.
BOOL ObjCExceptionGuardRun(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
