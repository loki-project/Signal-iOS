//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/TSOutgoingMessage.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSProfileKeyMessage : TSOutgoingMessage

- (instancetype)initOutgoingMessageWithTimestamp:(uint64_t)timestamp
                                        inThread:(nullable TSThread *)thread
                                     messageBody:(nullable NSString *)body
                                   attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                                expiresInSeconds:(uint32_t)expiresInSeconds
                                 expireStartedAt:(uint64_t)expireStartedAt
                                  isVoiceMessage:(BOOL)isVoiceMessage
                                groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
                                    contactShare:(nullable OWSContact *)contactShare
                                     linkPreview:(nullable OWSLinkPreview *)linkPreview NS_UNAVAILABLE;

- (instancetype)initWithTimestamp:(uint64_t)timestamp inThread:(nullable TSThread *)thread NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
