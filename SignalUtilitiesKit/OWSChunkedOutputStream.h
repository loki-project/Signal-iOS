//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSChunkedOutputStream : NSObject

// Indicates whether any write failed.
@property (nonatomic, readonly) BOOL hasError;

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithOutputStream:(NSOutputStream *)outputStream;

// Returns NO on error.
- (BOOL)writeData:(NSData *)data;
- (BOOL)writeUInt32:(UInt32)value;
- (BOOL)writeVariableLengthUInt32:(UInt32)value;

@end

NS_ASSUME_NONNULL_END
