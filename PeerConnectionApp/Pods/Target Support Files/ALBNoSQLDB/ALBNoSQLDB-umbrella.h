#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "ALBNoSQLDB.h"
#import "sqlite3.h"

FOUNDATION_EXPORT double ALBNoSQLDBVersionNumber;
FOUNDATION_EXPORT const unsigned char ALBNoSQLDBVersionString[];

