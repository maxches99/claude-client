#import "ObjCExceptionGuard.h"

BOOL ObjCExceptionGuardRun(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"ObjCExceptionGuard" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Objective-C exception"}];
        }
        return NO;
    }
}
