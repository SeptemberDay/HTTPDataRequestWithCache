//
//  HTTPDataRequest.h
//  HTTPDataRequest
//
//  Created by yosemite on 16/5/9.
//  Copyright © 2016年 organization. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface HTTPDataRequest : NSObject
+ (BOOL)startTaskWithURLString:(NSString *)URLString completion:(void (^)(NSData *data))completion failure:(void (^)(NSError *error))failure;
+ (void)cancelTaskWithURLString:(NSString *)URLString completion:(void (^)(NSInteger isCancel))completion;
+ (void)emptyCache;
+ (NSUInteger)sizeOfCacheFile;
@end
