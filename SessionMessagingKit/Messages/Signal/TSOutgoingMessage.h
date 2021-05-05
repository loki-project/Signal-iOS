//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <SessionMessagingKit/TSMessage.h>

NS_ASSUME_NONNULL_BEGIN

// Feature flag.
//
// TODO: Remove.
BOOL AreRecipientUpdatesEnabled(void);

typedef NS_ENUM(NSInteger, TSOutgoingMessageState) {
    // The message is either:
    // a) Enqueued for sending.
    // b) Waiting on attachment upload(s).
    // c) Being sent to the service.
    TSOutgoingMessageStateSending,
    // The failure state.
    TSOutgoingMessageStateFailed,
    // The message has been sent to the service.
    TSOutgoingMessageStateSent,
};

NSString *NSStringForOutgoingMessageState(TSOutgoingMessageState value);

typedef NS_ENUM(NSInteger, OWSOutgoingMessageRecipientState) {
    // Message could not be sent to recipient.
    OWSOutgoingMessageRecipientStateFailed = 0,
    // Message is being sent to the recipient (enqueued, uploading or sending).
    OWSOutgoingMessageRecipientStateSending,
    // The message was not sent because the recipient is not valid.
    // For example, this recipient may have left the group.
    OWSOutgoingMessageRecipientStateSkipped,
    // The message has been sent to the service.  It may also have been delivered or read.
    OWSOutgoingMessageRecipientStateSent,

    OWSOutgoingMessageRecipientStateMin = OWSOutgoingMessageRecipientStateFailed,
    OWSOutgoingMessageRecipientStateMax = OWSOutgoingMessageRecipientStateSent,
};

NSString *NSStringForOutgoingMessageRecipientState(OWSOutgoingMessageRecipientState value);

typedef NS_ENUM(NSInteger, TSGroupMetaMessage) {
    TSGroupMetaMessageUnspecified,
    TSGroupMetaMessageNew,
    TSGroupMetaMessageUpdate,
    TSGroupMetaMessageDeliver,
    TSGroupMetaMessageQuit,
    TSGroupMetaMessageRequestInfo,
};

@class SNProtoAttachmentPointer;
@class SNProtoContentBuilder;
@class SNProtoDataMessage;
@class SNProtoDataMessageBuilder;
@class SignalRecipient;

@interface TSOutgoingMessageRecipientState : MTLModel

@property (atomic, readonly) OWSOutgoingMessageRecipientState state;
// This property should only be set if state == .sent.
@property (atomic, nullable, readonly) NSNumber *deliveryTimestamp;
// This property should only be set if state == .sent.
@property (atomic, nullable, readonly) NSNumber *readTimestamp;

@property (atomic, readonly) BOOL wasSentByUD;

@end

#pragma mark -

@interface TSOutgoingMessage : TSMessage

- (instancetype)initMessageWithTimestamp:(uint64_t)timestamp
                                inThread:(nullable TSThread *)thread
                             messageBody:(nullable NSString *)body
                           attachmentIds:(NSArray<NSString *> *)attachmentIds
                        expiresInSeconds:(uint32_t)expiresInSeconds
                         expireStartedAt:(uint64_t)expireStartedAt
                           quotedMessage:(nullable TSQuotedMessage *)quotedMessage
                             linkPreview:(nullable OWSLinkPreview *)linkPreview NS_UNAVAILABLE;

// MJK TODO - Can we remove the sender timestamp param?
- (instancetype)initOutgoingMessageWithTimestamp:(uint64_t)timestamp
                                        inThread:(nullable TSThread *)thread
                                     messageBody:(nullable NSString *)body
                                   attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                                expiresInSeconds:(uint32_t)expiresInSeconds
                                 expireStartedAt:(uint64_t)expireStartedAt
                                  isVoiceMessage:(BOOL)isVoiceMessage
                                groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
                                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                         openGroupInvitationName:(nullable NSString *)openGroupInvitationName
                          openGroupInvitationURL:(nullable NSString *)openGroupInvitationURL NS_DESIGNATED_INITIALIZER;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                            messageBody:(nullable NSString *)body
                           attachmentId:(nullable NSString *)attachmentId
                       expiresInSeconds:(uint32_t)expiresInSeconds
                          quotedMessage:(nullable TSQuotedMessage *)quotedMessage
                            linkPreview:(nullable OWSLinkPreview *)linkPreview;

+ (instancetype)outgoingMessageInThread:(nullable TSThread *)thread
                       groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                       expiresInSeconds:(uint32_t)expiresInSeconds;

@property (readonly) TSOutgoingMessageState messageState;
@property (readonly) BOOL wasDeliveredToAnyRecipient;
@property (readonly) BOOL wasSentToAnyRecipient;

@property (atomic, readonly) BOOL hasSyncedTranscript;
@property (atomic, readonly) NSString *customMessage;
@property (atomic, readonly) NSString *mostRecentFailureText;
// A map of attachment id-to-"source" filename.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSString *> *attachmentFilenameMap;

@property (atomic, readonly) TSGroupMetaMessage groupMetaMessage;

@property (nonatomic, readonly) BOOL isVoiceMessage;

+ (nullable instancetype)findMessageWithTimestamp:(uint64_t)timestamp;

- (BOOL)shouldBeSaved;

// All recipients of this message.
- (NSArray<NSString *> *)recipientIds;

// All recipients of this message who we are currently trying to send to (queued, uploading or during send).
- (NSArray<NSString *> *)sendingRecipientIds;

// All recipients of this message to whom it has been sent (and possibly delivered or read).
- (NSArray<NSString *> *)sentRecipientIds;

// All recipients of this message to whom it has been sent and delivered (and possibly read).
- (NSArray<NSString *> *)deliveredRecipientIds;

// All recipients of this message to whom it has been sent, delivered and read.
- (NSArray<NSString *> *)readRecipientIds;

// Number of recipients of this message to whom it has been sent.
- (NSUInteger)sentRecipientsCount;

- (nullable TSOutgoingMessageRecipientState *)recipientStateForRecipientId:(NSString *)recipientId;

#pragma mark - Update With... Methods

// This method is used to record a successful send to one recipient.
- (void)updateWithSentRecipient:(NSString *)recipientId
                    wasSentByUD:(BOOL)wasSentByUD
                    transaction:(YapDatabaseReadWriteTransaction *)transaction;

// This method is used to record a skipped send to one recipient.
- (void)updateWithSkippedRecipient:(NSString *)recipientId transaction:(YapDatabaseReadWriteTransaction *)transaction;

// On app launch, all "sending" recipients should be marked as "failed".
- (void)updateWithAllSendingRecipientsMarkedAsFailedWithTansaction:(YapDatabaseReadWriteTransaction *)transaction;

// When we start a message send, all "failed" recipients should be marked as "sending".
- (void)updateWithMarkingAllUnsentRecipientsAsSendingWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;

// This method is used to forge the message state for fake messages.
//
// NOTE: This method should only be used by Debug UI, etc.
- (void)updateWithFakeMessageState:(TSOutgoingMessageState)messageState
                       transaction:(YapDatabaseReadWriteTransaction *)transaction;

// This method is used to record a failed send to all "sending" recipients.
- (void)updateWithSendingError:(NSError *)error
                   transaction:(YapDatabaseReadWriteTransaction *)transaction
    NS_SWIFT_NAME(update(sendingError:transaction:));

- (void)updateWithHasSyncedTranscript:(BOOL)hasSyncedTranscript
                          transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithCustomMessage:(NSString *)customMessage transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)updateWithCustomMessage:(NSString *)customMessage;

// This method is used to record a successful delivery to one recipient.
//
// deliveryTimestamp is an optional parameter, since legacy
// delivery receipts don't have a "delivery timestamp".  Those
// messages repurpose the "timestamp" field to indicate when the
// corresponding message was originally sent.
- (void)updateWithDeliveredRecipient:(NSString *)recipientId
                   deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                         transaction:(YapDatabaseReadWriteTransaction *)transaction;

- (void)updateWithWasSentFromLinkedDeviceWithUDRecipientIds:(nullable NSArray<NSString *> *)udRecipientIds
                                          nonUdRecipientIds:(nullable NSArray<NSString *> *)nonUdRecipientIds
                                               isSentUpdate:(BOOL)isSentUpdate
                                                transaction:(YapDatabaseReadWriteTransaction *)transaction;

// This method is used to rewrite the recipient list with a single recipient.
// It is used to reply to a "group info request", which should only be
// delivered to the requestor.
- (void)updateWithSendingToSingleGroupRecipient:(NSString *)singleGroupRecipient
                                    transaction:(YapDatabaseReadWriteTransaction *)transaction;

// This method is used to record a successful "read" by one recipient.
- (void)updateWithReadRecipientId:(NSString *)recipientId
                    readTimestamp:(uint64_t)readTimestamp
                      transaction:(YapDatabaseReadWriteTransaction *)transaction;

- (nullable NSNumber *)firstRecipientReadTimestamp;

- (NSString *)statusDescription;

@end

NS_ASSUME_NONNULL_END
