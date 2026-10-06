#import "ObjCCatch.h"

BOOL BuddyCatchObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"BuddyObjCException"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}
