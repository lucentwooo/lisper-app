#import <Foundation/Foundation.h>
// Runs block; returns the ObjC exception reason if one was raised, else nil.
NSString * _Nullable lisperCatch(void (NS_NOESCAPE ^ _Nonnull block)(void));
