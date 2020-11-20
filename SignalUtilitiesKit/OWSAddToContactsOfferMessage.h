//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/TSInfoMessage.h>

NS_ASSUME_NONNULL_BEGIN

// This is a deprecated class, we're keeping it around to avoid YapDB serialization errors
// TODO - remove this class, clean up existing instances, ensure any missed ones don't explode (UnknownDBObject)
__attribute__((deprecated)) @interface OWSAddToContactsOfferMessage : TSInfoMessage

+ (instancetype)addToContactsOfferMessageWithTimestamp:(uint64_t)timestamp
                                                thread:(TSThread *)thread
                                             contactId:(NSString *)contactId;

@property (nonatomic, readonly) NSString *contactId;

@end

NS_ASSUME_NONNULL_END
