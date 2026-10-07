#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError. AVAudioEngine raises
/// NSExceptions (which Swift cannot catch) e.g. when enabling voice processing with no mic.
BOOL XFCatchObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
