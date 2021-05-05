//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <SessionMessagingKit/OWSReadTracking.h>
#import <SessionMessagingKit/TSMessage.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSInfoMessage : TSMessage <OWSReadTracking>

typedef NS_ENUM(NSInteger, TSInfoMessageType) {
    TSInfoMessageTypeGroupCreated,
    TSInfoMessageTypeGroupUpdated,
    TSInfoMessageTypeGroupCurrentUserLeft,
    TSInfoMessageTypeDisappearingMessagesUpdate,
    TSInfoMessageTypeScreenshotNotification,
    TSInfoMessageTypeMediaSavedNotification
};

@property (atomic, readonly) TSInfoMessageType messageType;
@property (atomic, readonly, nullable) NSString *customMessage;
@property (atomic, readonly, nullable) NSString *unregisteredRecipientId;

- (instancetype)initMessageWithTimestamp:(uint64_t)timestamp
                                inThread:(nullable TSThread *)thread
                             messageBody:(nullable NSString *)body
                           attachmentIds:(NSArray<NSString *> *)attachmentIds
                        expiresInSeconds:(uint32_t)expiresInSeconds
                         expireStartedAt:(uint64_t)expireStartedAt
                           quotedMessage:(nullable TSQuotedMessage *)quotedMessage
                            contactShare:(nullable OWSContact *)contact
                             linkPreview:(nullable OWSLinkPreview *)linkPreview NS_UNAVAILABLE;

- (instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)contact
                      messageType:(TSInfoMessageType)infoMessage NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)thread
                      messageType:(TSInfoMessageType)infoMessage
                    customMessage:(NSString *)customMessage;

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)thread
                      messageType:(TSInfoMessageType)infoMessage
          unregisteredRecipientId:(NSString *)unregisteredRecipientId;

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
                    attachmentIds:(NSArray<NSString *> *)attachmentIds
                 expiresInSeconds:(uint32_t)expiresInSeconds
                  expireStartedAt:(uint64_t)expireStartedAt NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
