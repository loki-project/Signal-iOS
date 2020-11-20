//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageSender.h"
#import "AppContext.h"
#import "NSData+keyVersionByte.h"
#import "NSData+messagePadding.h"
#import "NSError+MessageSending.h"
#import "OWSBackgroundTask.h"
#import "OWSBlockingManager.h"
#import "OWSContact.h"
#import "OWSDevice.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSDispatch.h"
#import "OWSEndSessionMessage.h"
#import "OWSError.h"
#import "OWSIdentityManager.h"
#import "OWSMessageServiceParams.h"
#import "OWSOperation.h"
#import "OWSOutgoingSentMessageTranscript.h"
#import "OWSOutgoingSyncMessage.h"
#import "OWSPrimaryStorage+PreKeyStore.h"
#import "OWSPrimaryStorage+SignedPreKeyStore.h"
#import "OWSPrimaryStorage+sessionStore.h"
#import "OWSPrimaryStorage+Loki.h"
#import "OWSPrimaryStorage.h"
#import "OWSRequestFactory.h"
#import "OWSUploadOperation.h"
#import "PreKeyBundle+jsonDict.h"
#import "SSKEnvironment.h"
#import "SignalRecipient.h"
#import "TSAccountManager.h"
#import "TSAttachmentStream.h"
#import "TSContactThread.h"
#import "TSGroupThread.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInvalidIdentityKeySendingErrorMessage.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSPreKeyManager.h"
#import "TSQuotedMessage.h"
#import "TSRequest.h"
#import "TSSocketManager.h"
#import "TSThread.h"
#import "TSContactThread.h"
#import "LKDeviceLinkMessage.h"
#import "LKUnlinkDeviceMessage.h"
#import <SessionProtocolKit/AxolotlExceptions.h>
#import <SessionProtocolKit/CipherMessage.h>
#import <SessionProtocolKit/PreKeyBundle.h>
#import <SessionProtocolKit/SessionBuilder.h>
#import <SessionProtocolKit/SessionCipher.h>
#import <PromiseKit/AnyPromise.h>
#import <SignalCoreKit/NSData+OWS.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/SCKExceptionWrapper.h>
#import <SignalCoreKit/Threading.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>
#import <SignalUtilitiesKit/ProfileManagerProtocol.h>
#import <SessionProtocolKit/SessionProtocolKit.h>
#import "SSKAsserts.h"
#import "SignalRecipient.h"

NS_ASSUME_NONNULL_BEGIN

NSString *NoSessionForTransientMessageException = @"NoSessionForTransientMessageException";

const NSUInteger kOversizeTextMessageSizeThreshold = 2 * 1024;

NSError *SSKEnsureError(NSError *_Nullable error, OWSErrorCode fallbackCode, NSString *fallbackErrorDescription)
{
    if (error) {
        return error;
    }
    OWSCFailDebug(@"Using fallback error.");
    return OWSErrorWithCodeDescription(fallbackCode, fallbackErrorDescription);
}

#pragma mark -

void AssertIsOnSendingQueue()
{
#ifdef DEBUG
    if (@available(iOS 10.0, *)) {
        dispatch_assert_queue([OWSDispatch sendingQueue]);
    } // else, skip assert as it's a development convenience.
#endif
}

#pragma mark -

@implementation OWSOutgoingAttachmentInfo

- (instancetype)initWithDataSource:(DataSource *)dataSource
                       contentType:(NSString *)contentType
                    sourceFilename:(nullable NSString *)sourceFilename
                           caption:(nullable NSString *)caption
                    albumMessageId:(nullable NSString *)albumMessageId
{
    self = [super init];
    if (!self) {
        return self;
    }

    _dataSource = dataSource;
    _contentType = contentType;
    _sourceFilename = sourceFilename;
    _caption = caption;
    _albumMessageId = albumMessageId;

    return self;
}

@end

#pragma mark -

/**
 * OWSSendMessageOperation encapsulates all the work associated with sending a message, e.g. uploading attachments,
 * getting proper keys, and retrying upon failure.
 *
 * Used by `OWSMessageSender` to serialize message sending, ensuring that messages are emitted in the order they
 * were sent.
 */
@interface OWSSendMessageOperation : OWSOperation

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithMessage:(TSOutgoingMessage *)message
                  messageSender:(OWSMessageSender *)messageSender
                   dbConnection:(YapDatabaseConnection *)dbConnection
                        success:(void (^)(void))aSuccessHandler
                        failure:(void (^)(NSError * error))aFailureHandler NS_DESIGNATED_INITIALIZER;

@end

#pragma mark -

@interface OWSMessageSender (OWSSendMessageOperation)

- (void)sendMessageToService:(TSOutgoingMessage *)message
                     success:(void (^)(void))successHandler
                     failure:(RetryableFailureHandler)failureHandler;

@end

#pragma mark -

@interface OWSSendMessageOperation ()

@property (nonatomic, readonly) TSOutgoingMessage *message;
@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) void (^successHandler)(void);
@property (nonatomic, readonly) void (^failureHandler)(NSError *error);

@end

#pragma mark -

@implementation OWSSendMessageOperation

- (instancetype)initWithMessage:(TSOutgoingMessage *)message
                  messageSender:(OWSMessageSender *)messageSender
                   dbConnection:(YapDatabaseConnection *)dbConnection
                        success:(void (^)(void))successHandler
                        failure:(void (^)(NSError * error))failureHandler
{
    self = [super init];

    if (!self) {
        return self;
    }

    _message = message;
    _messageSender = messageSender;
    _dbConnection = dbConnection;
    _successHandler = successHandler;
    _failureHandler = failureHandler;

    return self;
}

#pragma mark - OWSOperation overrides

- (nullable NSError *)checkForPreconditionError
{
    __block NSError *_Nullable error = [super checkForPreconditionError];
    if (error) { return error; }

    if (self.message.hasAttachments) {
        [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            for (TSAttachment *attachment in [self.message attachmentsWithTransaction:transaction]) {
                if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
                    error = OWSErrorMakeFailedToSendOutgoingMessageError();
                    break;
                }

                TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
                OWSAssertDebug(attachmentStream);
                OWSAssertDebug(attachmentStream.serverId);
                OWSAssertDebug(attachmentStream.isUploaded);
            }
        }];
    }

    return error;
}

- (void)run
{
    if (self.message.shouldBeSaved && ![TSOutgoingMessage fetchObjectWithUniqueID:self.message.uniqueId]) {
        OWSLogInfo(@"Aborting message send; message deleted.");
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeMessageDeletedBeforeSent, @"Message was deleted before it could be sent.");
        error.isFatal = YES;
        [self reportError:error];
        return;
    }

    [self.messageSender sendMessageToService:self.message
        success:^{
            [self reportSuccess];
        }
        failure:^(NSError *error) {
            [self reportError:error];
        }];
}

- (void)didSucceed
{
    if (self.message.messageState != TSOutgoingMessageStateSent) {
        [LKLogger print:@"[Loki] Succeeded with sending a message, but the message state isn't TSOutgoingMessageStateSent."];
    }

    self.successHandler();
}

- (void)didFailWithError:(NSError *)error
{
    OWSLogError(@"Message failed to send due to error: %@.", error);
    self.failureHandler(error);
}

@end

#pragma mark -

NSString *const OWSMessageSenderInvalidDeviceException = @"InvalidDeviceException";
NSString *const OWSMessageSenderRateLimitedException = @"RateLimitedException";

@interface OWSMessageSender ()

@property (nonatomic, readonly) OWSPrimaryStorage *primaryStorage;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (atomic, readonly) NSMutableDictionary<NSString *, NSOperationQueue *> *sendingQueueMap;

@end

#pragma mark -

@implementation OWSMessageSender

- (instancetype)initWithPrimaryStorage:(OWSPrimaryStorage *)primaryStorage
{
    self = [super init];
    if (!self) {
        return self;
    }

    _primaryStorage = primaryStorage;
    _sendingQueueMap = [NSMutableDictionary new];
    _dbConnection = primaryStorage.newDatabaseConnection;

    OWSSingletonAssert();

    return self;
}

#pragma mark - Dependencies

- (id<ContactsManagerProtocol>)contactsManager
{
    OWSAssertDebug(SSKEnvironment.shared.contactsManager);

    return SSKEnvironment.shared.contactsManager;
}

- (OWSBlockingManager *)blockingManager
{
    OWSAssertDebug(SSKEnvironment.shared.blockingManager);

    return SSKEnvironment.shared.blockingManager;
}

- (TSNetworkManager *)networkManager
{
    OWSAssertDebug(SSKEnvironment.shared.networkManager);

    return SSKEnvironment.shared.networkManager;
}

- (id<OWSUDManager>)udManager
{
    OWSAssertDebug(SSKEnvironment.shared.udManager);

    return SSKEnvironment.shared.udManager;
}

- (TSAccountManager *)tsAccountManager
{
    return TSAccountManager.sharedInstance;
}

- (OWSIdentityManager *)identityManager
{
    return SSKEnvironment.shared.identityManager;
}

#pragma mark -

- (NSOperationQueue *)sendingQueueForMessage:(TSOutgoingMessage *)message
{
    OWSAssertDebug(message);


    NSString *kDefaultQueueKey = @"kDefaultQueueKey";
    NSString *queueKey = message.uniqueThreadId ?: kDefaultQueueKey;
    OWSAssertDebug(queueKey.length > 0);

    if ([kDefaultQueueKey isEqualToString:queueKey]) {
        // when do we get here?
        OWSLogDebug(@"using default message queue");
    }

    @synchronized(self)
    {
        NSOperationQueue *sendingQueue = self.sendingQueueMap[queueKey];

        if (!sendingQueue) {
            sendingQueue = [NSOperationQueue new];
            sendingQueue.qualityOfService = NSOperationQualityOfServiceUserInitiated;
            sendingQueue.maxConcurrentOperationCount = 1;
            sendingQueue.name = [NSString stringWithFormat:@"%@:%@", self.logTag, queueKey];
            self.sendingQueueMap[queueKey] = sendingQueue;
        }

        return sendingQueue;
    }
}

- (void)sendMessage:(TSOutgoingMessage *)message
            success:(void (^)(void))successHandler
            failure:(void (^)(NSError *error))failureHandler
{
    OWSAssertDebug(message);

    if (message.body.length > 0) {
        OWSAssertDebug([message.body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= kOversizeTextMessageSizeThreshold);
    }
    
    if (message.shouldBeSaved && !message.thread.isGroupThread && ![LKSessionMetaProtocol isThreadNoteToSelf:message.thread]) {
        // Loki: Not strictly true but nice from a UI point of view
        [NSNotificationCenter.defaultCenter postNotificationName:NSNotification.calculatingPoW object:[[NSNumber alloc] initWithUnsignedLongLong:message.timestamp]];
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSMutableArray<NSString *> *allAttachmentIds = [NSMutableArray new];

        // This method will use a read/write transaction. This transaction
        // will block until any open read/write transactions are complete.
        //
        // That's key - we don't want to send any messages in response
        // to an incoming message until processing of that batch of messages
        // is complete. For example, we wouldn't want to auto-reply to a
        // group info request before that group info request's batch was
        // finished processing. Otherwise, we might receive a delivery
        // notice for a group update we hadn't yet saved to the database.
        //
        // So we're using YDB behavior to ensure this invariant, which is a bit
        // unorthodox.
        if (message.allAttachmentIds.count > 0) {
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                [allAttachmentIds addObjectsFromArray:[OutgoingMessagePreparer prepareMessageForSending:message transaction:transaction]];
            }];
        }

        NSOperationQueue *sendingQueue = [self sendingQueueForMessage:message];

        OWSSendMessageOperation *sendMessageOperation =
            [[OWSSendMessageOperation alloc] initWithMessage:message
                                               messageSender:self
                                                dbConnection:self.dbConnection
                                                     success:successHandler
                                                     failure:failureHandler];

        for (NSString *attachmentId in allAttachmentIds) {
            OWSUploadOperation *uploadAttachmentOperation =
                [[OWSUploadOperation alloc] initWithAttachmentId:attachmentId
                                                        threadID:message.thread.uniqueId
                                                    dbConnection:self.dbConnection];

            [sendMessageOperation addDependency:uploadAttachmentOperation];
            [sendingQueue addOperation:uploadAttachmentOperation];
        }

        [sendingQueue addOperation:sendMessageOperation];
    });
}

- (void)sendTemporaryAttachment:(DataSource *)dataSource
                    contentType:(NSString *)contentType
                      inMessage:(TSOutgoingMessage *)message
                        success:(void (^)(void))successHandler
                        failure:(void (^)(NSError *error))failureHandler
{
    OWSAssertDebug(dataSource);

    void (^successWithDeleteHandler)(void) = ^() {
        successHandler();

        OWSLogDebug(@"Removing successful temporary attachment message with attachment ids: %@", message.attachmentIds);
        [message remove];
    };

    void (^failureWithDeleteHandler)(NSError *error) = ^(NSError *error) {
        failureHandler(error);

        OWSLogDebug(@"Removing failed temporary attachment message with attachment ids: %@", message.attachmentIds);
        [message remove];
    };

    [self sendAttachment:dataSource
             contentType:contentType
          sourceFilename:nil
          albumMessageId:nil
               inMessage:message
                 success:successWithDeleteHandler
                 failure:failureWithDeleteHandler];
}

- (void)sendAttachment:(DataSource *)dataSource
           contentType:(NSString *)contentType
        sourceFilename:(nullable NSString *)sourceFilename
        albumMessageId:(nullable NSString *)albumMessageId
             inMessage:(TSOutgoingMessage *)message
               success:(void (^)(void))success
               failure:(void (^)(NSError *error))failure
{
    OWSAssertDebug(dataSource);

    OWSOutgoingAttachmentInfo *attachmentInfo = [[OWSOutgoingAttachmentInfo alloc] initWithDataSource:dataSource
                                                                                          contentType:contentType
                                                                                       sourceFilename:sourceFilename
                                                                                              caption:nil
                                                                                       albumMessageId:albumMessageId];
    [self sendAttachments:@[ attachmentInfo, ]
                inMessage:message
                  success:success
                  failure:failure];
}

- (void)sendAttachments:(NSArray<OWSOutgoingAttachmentInfo *> *)attachmentInfos
              inMessage:(TSOutgoingMessage *)message
                success:(void (^)(void))success
                failure:(void (^)(NSError *error))failure
{
    OWSAssertDebug(attachmentInfos.count > 0);

    [OutgoingMessagePreparer prepareAttachments:attachmentInfos
                                      inMessage:message
                              completionHandler:^(NSError *_Nullable error) {
                                  if (error) {
                                      failure(error);
                                      return;
                                  }
                                  [self sendMessage:message success:success failure:failure];
                              }];
}

- (void)sendMessageToService:(TSOutgoingMessage *)message
                     success:(void (^)(void))success
                     failure:(RetryableFailureHandler)failure
{
    [self.udManager ensureSenderCertificateWithSuccess:^(SMKSenderCertificate *senderCertificate) {
        OWSAssertDebug(senderCertificate != nil);
        dispatch_async(OWSDispatch.sendingQueue, ^{
            [self sendMessageToService:message senderCertificate:senderCertificate success:success failure:failure];
        });
    }
    failure:^(NSError *error) { // Should never occur
        dispatch_async(OWSDispatch.sendingQueue, ^{
            [self sendMessageToService:message senderCertificate:nil success:success failure:failure];
        });
    }];
}

- (nullable NSArray<NSString *> *)unsentRecipientsForMessage:(TSOutgoingMessage *)message
                                                      thread:(nullable TSThread *)thread
                                                       error:(NSError **)errorHandle
{
    OWSAssertDebug(message);
    OWSAssertDebug(errorHandle);

    NSString *userPublicKey = self.tsAccountManager.localNumber;

    __block NSMutableSet<NSString *> *recipientIds = [NSMutableSet new];
    if ([message isKindOfClass:OWSOutgoingSyncMessage.class]) {
        recipientIds = [LKSessionMetaProtocol getDestinationsForOutgoingSyncMessage];
    } else if (thread.isGroupThread) {
        TSGroupThread *groupThread = (TSGroupThread *)thread;
        recipientIds = [LKSessionMetaProtocol getDestinationsForOutgoingGroupMessage:message inThread:thread];
        __block NSString *userMasterPublicKey;
        [OWSPrimaryStorage.sharedManager.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            userMasterPublicKey = [LKDatabaseUtilities getMasterHexEncodedPublicKeyFor:userPublicKey in:transaction] ?: userPublicKey;
        }];
        if ([recipientIds containsObject:userMasterPublicKey]) {
            OWSFailDebug(@"Message send recipients should not include self.");
        }
    } else if ([thread isKindOfClass:TSContactThread.class]) {
        NSString *recipientContactId = ((TSContactThread *)thread).contactIdentifier;

        // Treat 1:1 sends to blocked contacts as failures.
        // If we block a user, don't send 1:1 messages to them. The UI
        // should prevent this from occurring, but in some edge cases
        // you might, for example, have a pending outgoing message when
        // you block them.
        OWSAssertDebug(recipientContactId.length > 0);
        if ([self.blockingManager isRecipientIdBlocked:recipientContactId]) {
            OWSLogInfo(@"Skipping 1:1 send to blocked contact: %@", recipientContactId);
            NSError *error = OWSErrorMakeMessageSendFailedDueToBlockListError();
            [error setIsRetryable:NO];
            *errorHandle = error;
            return nil;
        }

        [recipientIds addObject:recipientContactId];
    } else {
        OWSFailDebug(@"Unknown message type: %@", [message class]);
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        [error setIsRetryable:NO];
        *errorHandle = error;
        return nil;
    }

    [recipientIds minusSet:[NSSet setWithArray:self.blockingManager.blockedPhoneNumbers]];
    return recipientIds.allObjects;
}

- (NSArray<SignalRecipient *> *)recipientsForRecipientIds:(NSArray<NSString *> *)recipientIds
{
    OWSAssertDebug(recipientIds.count > 0);

    NSMutableArray<SignalRecipient *> *recipients = [NSMutableArray new];
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        for (NSString *recipientId in recipientIds) {
            SignalRecipient *recipient =
                [SignalRecipient getOrBuildUnsavedRecipientForRecipientId:recipientId transaction:transaction];
            [recipients addObject:recipient];
        }
    }];
    return [recipients copy];
}

- (AnyPromise *)sendPromiseForRecipients:(NSArray<SignalRecipient *> *)recipients
                                 message:(TSOutgoingMessage *)message
                                  thread:(nullable TSThread *)thread
                       senderCertificate:(nullable SMKSenderCertificate *)senderCertificate
                              sendErrors:(NSMutableArray<NSError *> *)sendErrors
{
    OWSAssertDebug(recipients.count > 0);
    OWSAssertDebug(message);
    OWSAssertDebug(sendErrors);

    NSMutableArray<AnyPromise *> *sendPromises = [NSMutableArray array];

    for (SignalRecipient *recipient in recipients) {
        AnyPromise *sendPromise = [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
            NSString *localNumber = self.tsAccountManager.localNumber;

            OWSUDAccess *_Nullable theirUDAccess;
            if (senderCertificate != nil && ![recipient.recipientId isEqualToString:localNumber]) {
                theirUDAccess = [self.udManager udAccessForRecipientId:recipient.recipientId requireSyncAccess:YES];
            }

            OWSMessageSend *messageSend = [[OWSMessageSend alloc] initWithMessage:message
                thread:thread
                recipient:recipient
                senderCertificate:senderCertificate
                udAccess:theirUDAccess
                localNumber:self.tsAccountManager.localNumber
                success:^{
                    // The value doesn't matter, we just need any non-NSError value.
                    resolve(@(1));
                }
                failure:^(NSError *error) {
                    @synchronized(sendErrors) {
                        [sendErrors addObject:error];
                    }
                    resolve(error);
                }];

//            NSString *publicKey = recipients.firstObject.recipientId;
//            if ([LKMultiDeviceProtocol isMultiDeviceRequiredForMessage:message toPublicKey:publicKey]) { // Avoid the write transaction if possible
//                [self.primaryStorage.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
//                    [LKMultiDeviceProtocol sendMessageToDestinationAndLinkedDevices:messageSend transaction:transaction];
//                }];
//            } else {
                [self sendMessage:messageSend];
//            }
        }];
        [sendPromises addObject:sendPromise];
    }

    // We use PMKJoin(), not PMKWhen(), because we don't want the
    // completion promise to execute until _all_ send promises
    // have either succeeded or failed. PMKWhen() executes as
    // soon as any of its input promises fail.
    return PMKJoin(sendPromises);
}

- (void)sendMessageToService:(TSOutgoingMessage *)message
           senderCertificate:(nullable SMKSenderCertificate *)senderCertificate
                     success:(void (^)(void))successHandlerParam
                     failure:(RetryableFailureHandler)failureHandlerParam
{
    AssertIsOnSendingQueue();
    OWSAssert(senderCertificate);

    void (^successHandler)(void) = ^() {
        dispatch_async(OWSDispatch.sendingQueue, ^{
            [self handleMessageSentLocally:message
                success:^{
                    successHandlerParam();
                }
                failure:^(NSError *error) {
                    OWSLogError(@"Error sending sync message for message: %@ timestamp: %llu.",
                        message.class,
                        message.timestamp);

                    failureHandlerParam(error);
                }];
        });
    };
    void (^failureHandler)(NSError *) = ^(NSError *error) {
        if (message.wasSentToAnyRecipient) {
            dispatch_async(OWSDispatch.sendingQueue, ^{
                [self handleMessageSentLocally:message
                    success:^{
                        failureHandlerParam(error);
                    }
                    failure:^(NSError *syncError) {
                        OWSLogError(@"Error sending sync message for message: %@ timestamp: %llu, %@.",
                            message.class,
                            message.timestamp,
                            syncError);

                        // Discard the sync message error in favor of the original error
                        failureHandlerParam(error);
                    }];
            });
            return;
        }

        failureHandlerParam(error);
    };

    TSThread *_Nullable thread = message.thread;

    BOOL isSyncMessage = [message isKindOfClass:[OWSOutgoingSyncMessage class]];
    if (thread == nil && !isSyncMessage) {

        // The thread has been deleted since the message was enqueued.
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeMessageSendNoValidRecipients,
            NSLocalizedString(@"ERROR_DESCRIPTION_NO_VALID_RECIPIENTS", @"Error indicating that an outgoing message had no valid recipients."));
        [error setIsRetryable:NO];
        return failureHandler(error);
    }

    // In the "self-send" special case, we ony need to send a sync message with a delivery receipt
    // Loki: Take into account multi device
    if ([LKSessionMetaProtocol isThreadNoteToSelf:thread]
        && !([message isKindOfClass:LKDeviceLinkMessage.class]) && !([message isKindOfClass:SNClosedGroupUpdate.class])) {
        // Don't mark self-sent messages as read (or sent) until the sync transcript is sent
        successHandler();
        return;
    }

    if (thread.isGroupThread) {
        [self saveInfoMessageForGroupMessage:message inThread:thread];
    }

    NSError *error;
    NSArray<NSString *> *_Nullable recipientIds = [self unsentRecipientsForMessage:message thread:thread error:&error];
    if (error || !recipientIds) {
        error = SSKEnsureError(
            error, OWSErrorCodeMessageSendNoValidRecipients, @"Couldn't build recipient list for message.");
        [error setIsRetryable:NO];
        return failureHandler(error);
    }

    // Mark skipped recipients as such.  We skip because:
    //
    // * Recipient is no longer in the group.
    // * Recipient is blocked.
    //
    // Elsewhere, we skip recipient if their Signal account has been deactivated.
    NSMutableSet<NSString *> *obsoleteRecipientIds = [NSMutableSet setWithArray:message.sendingRecipientIds];
    [obsoleteRecipientIds minusSet:[NSSet setWithArray:recipientIds]];
    if (obsoleteRecipientIds.count > 0) {
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            for (NSString *recipientId in obsoleteRecipientIds) {
                [message updateWithSkippedRecipient:recipientId transaction:transaction];
            }
        }];
    }

    if (recipientIds.count < 1) {
        successHandler();
        return;
    }

    NSArray<SignalRecipient *> *recipients = [self recipientsForRecipientIds:recipientIds];

    BOOL isGroupSend = (thread && thread.isGroupThread);
    NSMutableArray<NSError *> *sendErrors = [NSMutableArray array];
    AnyPromise *sendPromise = [self sendPromiseForRecipients:recipients
                                                     message:message
                                                      thread:thread
                                           senderCertificate:senderCertificate
                                                  sendErrors:sendErrors]
                                  .then(^(id value) {
                                      successHandler();
                                  });

    sendPromise.catch(^(id failure) {
        NSError *firstRetryableError = nil;
        NSError *firstNonRetryableError = nil;

        NSArray<NSError *> *sendErrorsCopy;
        @synchronized(sendErrors) {
            sendErrorsCopy = [sendErrors copy];
        }

        for (NSError *error in sendErrorsCopy) {
            // Some errors should be ignored when sending messages
            // to groups.  See discussion on
            // NSError (OWSMessageSender) category.
            if (isGroupSend && error.shouldBeIgnoredForGroups) {
                continue;
            }

            // Some errors should never be retried, in order to avoid
            // hitting rate limits, for example.  Unfortunately, since
            // group send retry is all-or-nothing, we need to fail
            // immediately even if some of the other recipients had
            // retryable errors.
            if (error.isFatal) {
                failureHandler(error);
                return;
            }

            if ([error isRetryable] && !firstRetryableError) {
                firstRetryableError = error;
            } else if (![error isRetryable] && !firstNonRetryableError) {
                firstNonRetryableError = error;
            }
        }

        // If any of the send errors are retryable, we want to retry.
        // Therefore, prefer to propagate a retryable error.
        if (firstRetryableError) {
            return failureHandler(firstRetryableError);
        } else if (firstNonRetryableError) {
            return failureHandler(firstNonRetryableError);
        } else {
            // If we only received errors that we should ignore,
            // consider this send a success, unless the message could
            // not be sent to any recipient.
            if (message.sentRecipientsCount == 0) {
                NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeMessageSendNoValidRecipients,
                    NSLocalizedString(@"ERROR_DESCRIPTION_NO_VALID_RECIPIENTS", @"Error indicating that an outgoing message had no valid recipients."));
                [error setIsRetryable:NO];
                failureHandler(error);
            } else {
                successHandler();
            }
        }
    });

    [sendPromise retainUntilComplete];
}

- (nullable NSArray<NSDictionary *> *)deviceMessagesForMessageSend:(OWSMessageSend *)messageSend
                                                             error:(NSError **)errorHandle
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(errorHandle);
    AssertIsOnSendingQueue();

    SignalRecipient *recipient = messageSend.recipient;

    NSArray<NSDictionary *> *deviceMessages;
    @try {
        deviceMessages = [self throws_deviceMessagesForMessageSend:messageSend];
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:NoSessionForTransientMessageException]) {
            // When users re-register, we don't want transient messages (like typing
            // indicators) to cause users to hit the prekey fetch rate limit.  So
            // we silently discard these message if there is no pre-existing session
            // for the recipient.
            NSError *error = OWSErrorWithCodeDescription(
                OWSErrorCodeNoSessionForTransientMessage, @"No session for transient message.");
            [error setIsRetryable:NO];
            [error setIsFatal:YES];
            *errorHandle = error;
            return nil;
        } else if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
            NSString *localizedErrorDescriptionFormat
                = NSLocalizedString(@"FAILED_SENDING_BECAUSE_UNTRUSTED_IDENTITY_KEY",
                    @"action sheet header when re-sending message which failed because of untrusted identity keys");

            NSString *localizedErrorDescription =
                [NSString stringWithFormat:localizedErrorDescriptionFormat,
                          [self.contactsManager displayNameForPhoneIdentifier:recipient.recipientId]];
            NSError *error = OWSErrorMakeUntrustedIdentityError(localizedErrorDescription, recipient.recipientId);

            // Key will continue to be unaccepted, so no need to retry. It'll only cause us to hit the Pre-Key request
            // rate limit
            [error setIsRetryable:NO];
            // Avoid the "Too many failures with this contact" error rate limiting.
            [error setIsFatal:YES];
            *errorHandle = error;

            PreKeyBundle *_Nullable newKeyBundle = exception.userInfo[TSInvalidPreKeyBundleKey];
            if (newKeyBundle == nil) {
                return nil;
            }

            if (![newKeyBundle isKindOfClass:[PreKeyBundle class]]) {
                return nil;
            }

            NSData *newIdentityKeyWithVersion = newKeyBundle.identityKey;

            if (![newIdentityKeyWithVersion isKindOfClass:[NSData class]]) {
                return nil;
            }

            // TODO migrate to storing the full 33 byte representation of the identity key.
            if (newIdentityKeyWithVersion.length != kIdentityKeyLength) {
                return nil;
            }

            NSData *newIdentityKey = [newIdentityKeyWithVersion throws_removeKeyType];
            [self.identityManager saveRemoteIdentity:newIdentityKey recipientId:recipient.recipientId];

            return nil;
        }

        if ([exception.name isEqualToString:OWSMessageSenderRateLimitedException]) {
            NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeSignalServiceRateLimited,
                NSLocalizedString(@"FAILED_SENDING_BECAUSE_RATE_LIMIT",
                    @"action sheet header when re-sending message which failed because of too many attempts"));
            // We're already rate-limited. No need to exacerbate the problem.
            [error setIsRetryable:NO];
            // Avoid exacerbating the rate limiting.
            [error setIsFatal:YES];
            *errorHandle = error;
            return nil;
        }

        OWSLogWarn(@"Could not build device messages: %@", exception);
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        [error setIsRetryable:YES];
        *errorHandle = error;
        return nil;
    }

    return deviceMessages;
}

- (void)sendMessage:(OWSMessageSend *)messageSend
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(messageSend.thread || [messageSend.message isKindOfClass:[OWSOutgoingSyncMessage class]]);
    NSString *userPublicKey = OWSIdentityManager.sharedManager.identityKeyPair.hexEncodedPublicKey;
    if (!messageSend.isUDSend && ![messageSend.recipient.recipientId isEqual:userPublicKey]) {
        [LKLogger print:@"[Loki] Non-UD send"];
    }

    TSOutgoingMessage *message = messageSend.message;
    SignalRecipient *recipient = messageSend.recipient;

    BOOL notifyPNServer = ((message.body != nil && message.body.length > 0) || message.hasAttachments);

    OWSLogInfo(@"Attempting to send message: %@, timestamp: %llu, recipient: %@.",
        message.class,
        message.timestamp,
        recipient.uniqueId);

    AssertIsOnSendingQueue();

    if ([TSPreKeyManager isAppLockedDueToPreKeyUpdateFailures]) {
        // Retry pre key update every time user tries to send a message while the app
        // is disabled due to pre key update failures.
        //
        // Only try to update the signed pre key; updating it is sufficient to
        // re-enable message sending.
        [TSPreKeyManager
            rotateSignedPreKeyWithSuccess:^{
                OWSLogInfo(@"New pre keys registered with server.");
                NSError *error = OWSErrorMakeMessageSendDisabledDueToPreKeyUpdateFailuresError();
                [error setIsRetryable:YES];
                return messageSend.failure(error);
            }
            failure:^(NSError *error) {
                OWSLogWarn(@"Failed to update pre keys with the server due to error: %@.", error);
                return messageSend.failure(error);
            }];
    }

    if (messageSend.remainingAttempts <= 0) {
        // We should always fail with a specific error.
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        [error setIsRetryable:YES];
        return messageSend.failure(error);
    }

    // Consume an attempt.
    messageSend.remainingAttempts = messageSend.remainingAttempts - 1;

    // We need to disable UD for sync messages before we build the device messages,
    // since we don't want to build a device message for the local device in the
    // non-UD auth case.
    if ([message isKindOfClass:[OWSOutgoingSyncMessage class]]
        && ![message isKindOfClass:[OWSOutgoingSentMessageTranscript class]]) {
        [messageSend disableUD];
    }

    NSError *deviceMessagesError;
    NSArray<NSDictionary *> *_Nullable deviceMessages;
    if (message.thread.isGroupThread && ((TSGroupThread *)message.thread).isPublicChat) {
        deviceMessages = @[];
    } else {
        deviceMessages = [self deviceMessagesForMessageSend:messageSend error:&deviceMessagesError];
        
        // Loki: Remove this when we have shared sender keys
        // ========
        if (deviceMessages.count == 0) {
            return messageSend.success();
        }
        // ========
    }

    if (deviceMessagesError || !deviceMessages) {
        OWSAssertDebug(deviceMessagesError);
        return messageSend.failure(deviceMessagesError);
    }

    for (NSDictionary *deviceMessage in deviceMessages) {
        NSNumber *_Nullable messageType = deviceMessage[@"type"];
        OWSAssertDebug(messageType);
        BOOL hasValidMessageType;
        if (messageSend.isUDSend) {
            hasValidMessageType = [messageType isEqualToNumber:@(TSUnidentifiedSenderMessageType)];
        } else {
            NSArray *validMessageTypes = @[ @(TSEncryptedWhisperMessageType), @(TSPreKeyWhisperMessageType), @(TSFallbackMessageType), @(TSClosedGroupCiphertextMessageType) ];
            hasValidMessageType = [validMessageTypes containsObject:messageType];
        }

        if (!hasValidMessageType) {
            OWSFailDebug(@"Invalid message type: %@.", messageType);
            NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
            [error setIsRetryable:NO];
            return messageSend.failure(error);
        }
    }

    if (deviceMessages.count == 0 && !(message.thread.isGroupThread && ((TSGroupThread *)message.thread).isPublicChat)) {
        // This might happen:
        //
        // * The first (after upgrading?) time we send a sync message to our linked devices.
        // * After unlinking all linked devices.
        // * After trying and failing to link a device.
        // * The first time we send a message to a user, if they don't have their
        //   default device.  For example, if they have unregistered
        //   their primary but still have a linked device. Or later, when they re-register.
        //
        // When we're not sure if we have linked devices, we need to try
        // to send self-sync messages even if they have no device messages
        // so that we can learn from the service whether or not there are
        // linked devices that we don't know about.
        OWSLogWarn(@"Sending a message with no device messages.");

        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        [error setIsRetryable:NO];
        return messageSend.failure(error);
    }
    
    void (^failedMessageSend)(NSError *error) = ^(NSError *error) {
        NSUInteger statusCode = 0;
        NSData *_Nullable responseData = nil;
        if ([error.domain isEqualToString:TSNetworkManagerErrorDomain]) {
            statusCode = error.code;
            NSError *_Nullable underlyingError = error.userInfo[NSUnderlyingErrorKey];
            if (underlyingError) {
                responseData = underlyingError.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            } else {
                OWSFailDebug(@"Missing underlying error: %@.", error);
            }
        }
        [self messageSendDidFail:messageSend deviceMessages:deviceMessages statusCode:statusCode error:error responseData:responseData];
    };
    
    __block SNOpenGroup *publicChat;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        publicChat = [LKDatabaseUtilities getPublicChatForThreadID:message.uniqueThreadId transaction: transaction];
    }];
    if (publicChat != nil) {
        NSString *userPublicKey = OWSIdentityManager.sharedManager.identityKeyPair.hexEncodedPublicKey;
        NSString *displayName = SSKEnvironment.shared.profileManager.localProfileName;
        if (displayName == nil) { displayName = @"Anonymous"; }
        TSQuotedMessage *quote = message.quotedMessage;
        uint64_t quoteID = quote.timestamp;
        NSString *quoteePublicKey = quote.authorId;
        __block uint64_t quotedMessageServerID = 0;
        if (quoteID != 0) {
            [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
                quotedMessageServerID = [LKDatabaseUtilities getServerIDForQuoteWithID:quoteID quoteeHexEncodedPublicKey:quoteePublicKey threadID:messageSend.thread.uniqueId transaction:transaction];
            }];
        }
        NSString *body = (message.body != nil && message.body.length > 0) ? message.body : [NSString stringWithFormat:@"%@", @(message.timestamp)]; // Workaround for the fact that the back-end doesn't accept messages without a body
        SNOpenGroupMessage *groupMessage = [[SNOpenGroupMessage alloc] initWithSenderPublicKey:userPublicKey displayName:displayName body:body type:SNOpenGroupAPI.openGroupMessageType
            timestamp:message.timestamp quotedMessageTimestamp:quoteID quoteePublicKey:quoteePublicKey quotedMessageBody:quote.body quotedMessageServerID:quotedMessageServerID signatureData:nil signatureVersion:0 serverTimestamp:0];
        OWSLinkPreview *linkPreview = message.linkPreview;
        if (linkPreview != nil) {
            TSAttachmentStream *attachment = [TSAttachmentStream fetchObjectWithUniqueID:linkPreview.imageAttachmentId];
            if (attachment != nil) {
                [groupMessage addAttachmentWithKind:@"preview" server:publicChat.server serverID:attachment.serverId contentType:attachment.contentType size:attachment.byteCount fileName:attachment.sourceFilename flags:0 width:@(attachment.imageSize.width).unsignedIntegerValue height:@(attachment.imageSize.height).unsignedIntegerValue caption:attachment.caption url:attachment.downloadURL linkPreviewURL:linkPreview.urlString linkPreviewTitle:linkPreview.title];
            }
        }
        for (NSString *attachmentID in message.attachmentIds) {
            TSAttachmentStream *attachment = [TSAttachmentStream fetchObjectWithUniqueID:attachmentID];
            if (attachment == nil) { continue; }
            NSUInteger width = attachment.shouldHaveImageSize ? @(attachment.imageSize.width).unsignedIntegerValue : 0;
            NSUInteger height = attachment.shouldHaveImageSize ? @(attachment.imageSize.height).unsignedIntegerValue : 0;
            [groupMessage addAttachmentWithKind:@"attachment" server:publicChat.server serverID:attachment.serverId contentType:attachment.contentType size:attachment.byteCount fileName:attachment.sourceFilename flags:0 width:width height:height caption:attachment.caption url:attachment.downloadURL linkPreviewURL:nil linkPreviewTitle:nil];
        }
        message.actualSenderHexEncodedPublicKey = userPublicKey;
        [[SNOpenGroupAPI sendMessage:groupMessage toGroup:publicChat.channel onServer:publicChat.server]
        .thenOn(OWSDispatch.sendingQueue, ^(SNOpenGroupMessage *groupMessage) {
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                [message saveOpenGroupServerMessageID:groupMessage.serverID in:transaction];
                [self.primaryStorage setIDForMessageWithServerID:groupMessage.serverID to:message.uniqueId in:transaction];
            }];
            [self messageSendDidSucceed:messageSend deviceMessages:deviceMessages wasSentByUD:messageSend.isUDSend wasSentByWebsocket:false];
        })
        .catchOn(OWSDispatch.sendingQueue, ^(NSError *error) {
            failedMessageSend(error);
        }) retainUntilComplete];
    } else {
        NSString *targetPublicKey = recipient.recipientId;
        NSString *userPublicKey = OWSIdentityManager.sharedManager.identityKeyPair.hexEncodedPublicKey;
        __block BOOL isUserLinkedDevice;
        [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            isUserLinkedDevice = [LKDatabaseUtilities isUserLinkedDevice:targetPublicKey in:transaction];
        }];
        BOOL isSSKBasedClosedGroup = [messageSend.thread isKindOfClass:TSGroupThread.class] && ((TSGroupThread *)messageSend.thread).usesSharedSenderKeys;
        if (isSSKBasedClosedGroup) {
            [LKLogger print:[NSString stringWithFormat:@"[Loki] Sending %@ to SSK based closed group.", message.class]];
        } else if ([targetPublicKey isEqual:userPublicKey]) {
            [LKLogger print:[NSString stringWithFormat:@"[Loki] Sending %@ to self.", message.class]];
        } else if (isUserLinkedDevice) {
            [LKLogger print:[NSString stringWithFormat:@"[Loki] Sending %@ to %@ (one of the current user's linked devices).", message.class, recipient.recipientId]];
        } else {
            [LKLogger print:[NSString stringWithFormat:@"[Loki] Sending %@ to %@.", message.class, recipient.recipientId]];
        }
        NSDictionary *signalMessageInfo = deviceMessages.firstObject;
        SSKProtoEnvelopeType type = ((NSNumber *)signalMessageInfo[@"type"]).integerValue;
        uint32_t senderDeviceID = (type == SSKProtoEnvelopeTypeUnidentifiedSender) ? 0 : OWSDevicePrimaryDeviceId;
        NSString *content = signalMessageInfo[@"content"];
        NSString *recipientID = signalMessageInfo[@"destination"];
        uint64_t ttl = ((NSNumber *)signalMessageInfo[@"ttl"]).unsignedIntegerValue;
        BOOL isPing = ((NSNumber *)signalMessageInfo[@"isPing"]).boolValue;
        uint64_t timestamp = message.timestamp;
        NSString *senderID;
        if (type == SSKProtoEnvelopeTypeClosedGroupCiphertext) {
            senderID = recipientID;
        } else if (type == SSKProtoEnvelopeTypeUnidentifiedSender) {
            senderID = @"";
        } else {
            senderID = userPublicKey;
            [LKLogger print:@"[Loki] Non-UD send"];
        }
        LKSignalMessage *signalMessage = [[LKSignalMessage alloc] initWithType:type timestamp:timestamp senderID:senderID senderDeviceID:senderDeviceID content:content recipientID:recipientID ttl:ttl isPing:isPing];
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            if (!message.skipSave) {
                // Update the PoW calculation status
                [message saveIsCalculatingProofOfWork:YES withTransaction:transaction];
            }
        }];
        // Convenience
        void (^handleError)(NSError *error) = ^(NSError *error) {
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                if (!message.skipSave) {
                    // Update the PoW calculation status
                    [message saveIsCalculatingProofOfWork:NO withTransaction:transaction];
                }
            }];
            // Handle the error
            failedMessageSend(error);
        };
        // Send the message
        [[LKSnodeAPI sendSignalMessage:signalMessage]
         .thenOn(OWSDispatch.sendingQueue, ^(id result) {
            NSSet<AnyPromise *> *promises = (NSSet<AnyPromise *> *)result;
            __block BOOL isSuccess = NO;
            NSUInteger promiseCount = promises.count;
            __block NSUInteger errorCount = 0;
            for (AnyPromise *promise in promises) {
                [promise
                .thenOn(OWSDispatch.sendingQueue, ^(id result) {
                    if (isSuccess) { return; } // Succeed as soon as the first promise succeeds
                    [NSNotificationCenter.defaultCenter postNotificationName:NSNotification.messageSent object:[[NSNumber alloc] initWithUnsignedLongLong:signalMessage.timestamp]];
                    isSuccess = YES;
                    if (notifyPNServer) {
                        [LKPushNotificationManager notifyForMessage:signalMessage];
                    }
                    [self messageSendDidSucceed:messageSend deviceMessages:deviceMessages wasSentByUD:messageSend.isUDSend wasSentByWebsocket:false];
                })
                .catchOn(OWSDispatch.sendingQueue, ^(NSError *error) {
                    errorCount += 1;
                    if (errorCount != promiseCount) { return; } // Only error out if all promises failed
                    [NSNotificationCenter.defaultCenter postNotificationName:NSNotification.messageFailed object:[[NSNumber alloc] initWithUnsignedLongLong:signalMessage.timestamp]];
                    handleError(error);
                }) retainUntilComplete];
            }
        })
        .catchOn(OWSDispatch.sendingQueue, ^(NSError *error) {
            handleError(error);
        }) retainUntilComplete];
    }
}

- (void)messageSendDidSucceed:(OWSMessageSend *)messageSend
               deviceMessages:(NSArray<NSDictionary *> *)deviceMessages
                  wasSentByUD:(BOOL)wasSentByUD
           wasSentByWebsocket:(BOOL)wasSentByWebsocket
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(deviceMessages);

    SignalRecipient *recipient = messageSend.recipient;

    OWSLogInfo(@"Successfully sent message: %@ timestamp: %llu, wasSentByUD: %d.",
               messageSend.message.class, messageSend.message.timestamp, wasSentByUD);

    if (messageSend.isLocalNumber && deviceMessages.count == 0) {
        OWSLogInfo(@"Sent a message with no device messages; clearing 'mayHaveLinkedDevices'.");
        // In order to avoid skipping necessary sync messages, the default value
        // for mayHaveLinkedDevices is YES.  Once we've successfully sent a
        // sync message with no device messages (e.g. the service has confirmed
        // that we have no linked devices), we can set mayHaveLinkedDevices to NO
        // to avoid unnecessary message sends for sync messages until we learn
        // of a linked device (e.g. through the device linking UI or by receiving
        // a sync message, etc.).
        [OWSDeviceManager.sharedManager clearMayHaveLinkedDevices];
    }

    dispatch_async(OWSDispatch.sendingQueue, ^{
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [messageSend.message updateWithSentRecipient:messageSend.recipient.uniqueId
                                             wasSentByUD:wasSentByUD
                                             transaction:transaction];

            // If we've just delivered a message to a user, we know they
            // have a valid Signal account.
            [SignalRecipient markRecipientAsRegisteredAndGet:recipient.recipientId transaction:transaction];
        }];

        messageSend.success();
    });
}

- (void)messageSendDidFail:(OWSMessageSend *)messageSend
            deviceMessages:(NSArray<NSDictionary *> *)deviceMessages
                statusCode:(NSInteger)statusCode
                     error:(NSError *)responseError
              responseData:(nullable NSData *)responseData
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(messageSend.thread || [messageSend.message isKindOfClass:[OWSOutgoingSyncMessage class]]);
    OWSAssertDebug(deviceMessages);
    OWSAssertDebug(responseError);

    TSOutgoingMessage *message = messageSend.message;
    SignalRecipient *recipient = messageSend.recipient;

    OWSLogInfo(@"Failed to send message: %@, timestamp: %llu, to recipient: %@.",
        message.class,
        message.timestamp,
        recipient.uniqueId);

    void (^retrySend)(void) = ^void() {
        if (messageSend.remainingAttempts <= 0) {
            return messageSend.failure(responseError);
        }

        dispatch_async(OWSDispatch.sendingQueue, ^{
            OWSLogDebug(@"Retrying: %@.", message.debugDescription);
            [self sendMessage:messageSend];
        });
    };

    switch (statusCode) {
        case 0: { // Loki
            NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
            [error setIsRetryable:NO];
            return messageSend.failure(error);
        }
        case 401: {
            OWSLogWarn(@"Unable to send due to invalid credentials. Did the user's client get de-authed by "
                       @"registering elsewhere?");
            NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeSignalServiceFailure,
                NSLocalizedString(@"ERROR_DESCRIPTION_SENDING_UNAUTHORIZED", @"Error message when attempting to send message"));
            // No need to retry if we've been de-authed.
            [error setIsRetryable:NO];
            return messageSend.failure(error);
        }
        default:
            retrySend();
            break;
    }
}

- (void)handleMessageSentLocally:(TSOutgoingMessage *)message
                         success:(void (^)(void))successParam
                         failure:(RetryableFailureHandler)failure
{
    dispatch_block_t success = ^{
        // Don't mark self-sent messages as read (or sent) until the sync transcript is sent
        // Loki: Take into account multi device
        BOOL isNoteToSelf = [LKSessionMetaProtocol isThreadNoteToSelf:message.thread];
        if (isNoteToSelf && !([message isKindOfClass:LKDeviceLinkMessage.class])
            && ![message isKindOfClass:SNClosedGroupUpdate.class]) {
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                for (NSString *recipientId in message.sendingRecipientIds) {
                    [message updateWithReadRecipientId:recipientId readTimestamp:message.timestamp transaction:transaction];
                }
            }];
        }

        successParam();
    };

    [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [[OWSDisappearingMessagesJob sharedJob] startAnyExpirationForMessage:message
                                                         expirationStartedAt:[NSDate ows_millisecondTimeStamp]
                                                                 transaction:transaction];
    }];

    if (!message.shouldSyncTranscript) {
        return success();
    }

    BOOL shouldSendTranscript = [LKSessionMetaProtocol shouldSendTranscriptForMessage:message inThread:message.thread];
    if (!shouldSendTranscript) {
        return success();
    }

    BOOL isRecipientUpdate = message.hasSyncedTranscript;
    [self
        sendSyncTranscriptForMessage:message
                   isRecipientUpdate:isRecipientUpdate
                             success:^{
                                 [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                                     [message updateWithHasSyncedTranscript:YES transaction:transaction];
                                 }];

                                 success();
                             }
                             failure:failure];
}

- (void)sendSyncTranscriptForMessage:(TSOutgoingMessage *)message
                   isRecipientUpdate:(BOOL)isRecipientUpdate
                             success:(void (^)(void))success
                             failure:(RetryableFailureHandler)failure
{
    OWSOutgoingSentMessageTranscript *sentMessageTranscript =
        [[OWSOutgoingSentMessageTranscript alloc] initWithOutgoingMessage:message isRecipientUpdate:isRecipientUpdate];

    NSString *userPublicKey = self.tsAccountManager.localNumber;

    // Loki: Send to the user's other device
    __block NSSet<NSString *> *userLinkedDevices;
    [self.primaryStorage.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        userLinkedDevices = [LKDatabaseUtilities getLinkedDeviceHexEncodedPublicKeysFor:userPublicKey in:transaction];
    }];
    NSString *otherUserDevice;
    for (NSString *device in userLinkedDevices) {
        if (![device isEqual:userPublicKey]) {
            otherUserDevice = device;
            break;
        }
    }

    NSString *recipientId = otherUserDevice ?: userPublicKey;
    __block SignalRecipient *recipient;
    [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        recipient = [SignalRecipient markRecipientAsRegisteredAndGet:recipientId transaction:transaction];
    }];
    
    SMKSenderCertificate *senderCertificate = [self.udManager getSenderCertificate];
    OWSUDAccess *recipientUDAccess = nil;
    if (senderCertificate != nil) {
        recipientUDAccess = [self.udManager udAccessForRecipientId:recipient.recipientId requireSyncAccess:YES];
    }

    // Loki: If the message was aimed at an SSK based closed group, aim the sync transcript at
    // the contact thread with the other device rather than also sending it to the group.
    __block TSThread *thread = message.thread;
    if ([thread isKindOfClass:TSGroupThread.class] && ((TSGroupThread *)thread).usesSharedSenderKeys) {
        [LKStorage readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            thread = [TSContactThread getThreadWithContactId:otherUserDevice transaction:transaction];
        }];
    }

    OWSMessageSend *messageSend = [[OWSMessageSend alloc] initWithMessage:sentMessageTranscript
        thread:thread
        recipient:recipient
        senderCertificate:senderCertificate
        udAccess:recipientUDAccess
        localNumber:self.tsAccountManager.localNumber
        success:^{
            OWSLogInfo(@"Successfully sent sync transcript.");

            success();
        }
        failure:^(NSError *error) {
            OWSLogInfo(@"Failed to send sync transcript: %@ (isRetryable: %d).", error, error.isRetryable);

            failure(error);
        }];

    [self sendMessage:messageSend];
}

- (NSArray<NSDictionary *> *)throws_deviceMessagesForMessageSend:(OWSMessageSend *)messageSend
{
    // Loki: Multi device is handled elsewhere so just send to the provided recipient ID (Signal used
    // to send to each of the recipient's devices here)
    OWSAssertDebug(messageSend.message != nil);
    OWSAssertDebug(messageSend.recipient != nil);

    SignalRecipient *recipient = messageSend.recipient;
    NSMutableArray *messagesArray = [NSMutableArray new];

    NSData *_Nullable plainText = [messageSend.message buildPlainTextData:recipient];
    if (!plainText) {
        OWSRaiseException(InvalidMessageException, @"Failed to build message proto.");
    }
    OWSLogDebug(@"Built message: %@ plainTextData.length: %lu", [messageSend.message class], (unsigned long)plainText.length);

    NSString *recipientID = recipient.recipientId;

    OWSLogVerbose(@"Building device messages for: %@ %@ (isLocalNumber: %d, isUDSend: %d).",
        recipientID,
        recipient.devices,
        messageSend.isLocalNumber,
        messageSend.isUDSend);

    @try {
        __block BOOL isSessionRequired;
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            isSessionRequired = [LKSessionManagementProtocol isSessionRequiredForMessage:messageSend.message recipientID:recipientID transaction:transaction];
        }];
        if (isSessionRequired) {
            BOOL hasSession = [self throws_ensureRecipientHasSessionForMessageSend:messageSend recipientID:recipientID deviceId:@(OWSDevicePrimaryDeviceId)];

            // Loki: Remove this when shared sender keys has been widely rolled out
            // ========
            if (!hasSession && [LKSessionManagementProtocol shouldIgnoreMissingPreKeyBundleExceptionForMessage:messageSend.message to:recipientID]) {
                return @[ [NSDictionary new] ];
            }
            // ========
        }

        __block NSDictionary *_Nullable messageDict;
        __block NSException *encryptionException;
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            @try {
                messageDict = [self throws_encryptedMessageForMessageSend:messageSend
                                                              recipientID:recipientID
                                                                plainText:plainText
                                                              transaction:transaction];
            } @catch (NSException *exception) {
                encryptionException = exception;
            }
        }];

        if (encryptionException) {
            OWSLogInfo(@"Exception during encryption: %@.", encryptionException);
            @throw encryptionException;
        }

        if (messageDict) {
            [messagesArray addObject:messageDict];
        } else {
            OWSRaiseException(InvalidMessageException, @"Failed to encrypt message.");
        }
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:OWSMessageSenderInvalidDeviceException]) {
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                [recipient updateRegisteredRecipientWithDevicesToAdd:nil
                                                     devicesToRemove:@[ @(OWSDevicePrimaryDeviceId) ]
                                                         transaction:transaction];
            }];
        } else {
            @throw exception;
        }
    }

    return [messagesArray copy];
}

- (BOOL)throws_ensureRecipientHasSessionForMessageSend:(OWSMessageSend *)messageSend recipientID:(NSString *)recipientID deviceId:(NSNumber *)deviceId
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(deviceId);

    OWSPrimaryStorage *storage = self.primaryStorage;
    SignalRecipient *recipient = messageSend.recipient;
    OWSAssertDebug(recipientID.length > 0);
    
    // Discard "typing indicator" messages if there is no existing session with the user.
    BOOL canSafelyBeDiscarded = messageSend.message.isOnline;
    if (canSafelyBeDiscarded) {
        OWSRaiseException(NoSessionForTransientMessageException, @"No session for transient message.");
    }
    
    PreKeyBundle *_Nullable bundle = [storage getPreKeyBundleForContact:recipientID];
    __block NSException *exception;

    if (!bundle) {
        __block BOOL hasSession;
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            hasSession = [storage containsSession:recipientID deviceId:[deviceId intValue] protocolContext:transaction];
        }];
        if (hasSession) { return YES; }

        TSOutgoingMessage *message = messageSend.message;
        // Loki: Remove this when we have shared sender keys
        // ========
        if ([LKSessionManagementProtocol shouldIgnoreMissingPreKeyBundleExceptionForMessage:message to:recipientID]) { return NO; }
        // ========
        NSString *missingPrekeyBundleException = @"missingPrekeyBundleException";
        OWSRaiseException(missingPrekeyBundleException, @"Missing pre key bundle for: %@.", recipientID);
    } else {
        SessionBuilder *builder = [[SessionBuilder alloc] initWithSessionStore:storage
                                                                   preKeyStore:storage
                                                             signedPreKeyStore:storage
                                                              identityKeyStore:self.identityManager
                                                                   recipientId:recipientID
                                                                      deviceId:[deviceId intValue]];
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            @try {
                [builder throws_processPrekeyBundle:bundle protocolContext:transaction];
                
                // Loki: Discard the pre key bundle as the session has now been established
                [storage removePreKeyBundleForContact:recipientID transaction:transaction];
            } @catch (NSException *caughtException) {
                exception = caughtException;
            }
        }];
        if (exception) {
            if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
                OWSRaiseExceptionWithUserInfo(UntrustedIdentityKeyException, (@{ TSInvalidPreKeyBundleKey : bundle, TSInvalidRecipientKey : recipientID }), @"");
            }
            @throw exception;
        }
        return YES;
    }
}

- (nullable NSDictionary *)throws_encryptedMessageForMessageSend:(OWSMessageSend *)messageSend
                                                     recipientID:(NSString *)recipientID
                                                       plainText:(NSData *)plainText
                                                     transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssertDebug(messageSend);
    OWSAssertDebug(recipientID);
    OWSAssertDebug(plainText);
    OWSAssertDebug(transaction);

    OWSPrimaryStorage *storage = self.primaryStorage;
    TSOutgoingMessage *message = messageSend.message;

    SessionCipher *cipher = [[SessionCipher alloc] initWithSessionStore:storage
                                                            preKeyStore:storage
                                                      signedPreKeyStore:storage
                                                       identityKeyStore:self.identityManager
                                                            recipientId:recipientID
                                                               deviceId:@(OWSDevicePrimaryDeviceId).intValue];

    NSData *_Nullable serializedMessage;
    TSWhisperMessageType messageType;
    if ([LKSharedSenderKeysImplementation.shared isClosedGroup:recipientID]) {
        NSError *error;
        serializedMessage = [LKClosedGroupUtilities encryptData:plainText.paddedMessageBody usingGroupPublicKey:recipientID transaction:transaction error:&error];

        if (error != nil) {
            OWSFailDebug(@"Couldn't encrypt message for SSK based closed group due to error: %@.", error);
            return nil;
        }

        messageType = TSClosedGroupCiphertextMessageType;

        messageSend.udAccess = nil;
    } else if (messageSend.isUDSend) {
        NSError *error;
        SNSessionRestorationImplementation *sessionResetImplementation = [SNSessionRestorationImplementation new];

        SMKSecretSessionCipher *_Nullable secretCipher =
            [[SMKSecretSessionCipher alloc] initWithSessionResetImplementation:sessionResetImplementation
                                                                  sessionStore:self.primaryStorage
                                                                   preKeyStore:self.primaryStorage
                                                             signedPreKeyStore:self.primaryStorage
                                                                 identityStore:self.identityManager
                                                                         error:&error];
        if (error || !secretCipher) {
            OWSRaiseException(@"SecretSessionCipherFailure", @"Can't create secret session cipher.");
        }

        // Loki: The way this works is:
        // • Alice sends a session request (i.e. a pre key bundle) to Bob using fallback encryption.
        // • She may send any number of subsequent messages also encrypted using fallback encryption.
        // • When Bob receives the session request, he sets up his Signal cipher session locally and sends back a null message,
        //   now encrypted using Signal encryption.
        // • Alice receives this, sets up her Signal cipher session locally, and sends any subsequent messages
        //   using Signal encryption.

        BOOL shouldUseFallbackEncryption = [LKSessionManagementProtocol shouldUseFallbackEncryptionForMessage:message recipientID:recipientID transaction:transaction];

        if (shouldUseFallbackEncryption) {
            [LKLogger print:@"[Loki] Using fallback encryption"];
        } else {
            [LKLogger print:@"[Loki] Using Signal Encryption"];
        }

        serializedMessage = [secretCipher throwswrapped_encryptMessageWithRecipientPublicKey:recipientID
                                                                                    deviceID:@(OWSDevicePrimaryDeviceId).intValue
                                                                             paddedPlaintext:plainText.paddedMessageBody
                                                                           senderCertificate:messageSend.senderCertificate
                                                                             protocolContext:transaction
                                                                    useFallbackSessionCipher:shouldUseFallbackEncryption
                                                                                       error:&error];

        SCKRaiseIfExceptionWrapperError(error);
        if (serializedMessage == nil || error != nil) {
            OWSFailDebug(@"Error while UD encrypting message: %@.", error);
            return nil;
        }
        messageType = TSUnidentifiedSenderMessageType;
    } else {
        id<CipherMessage> encryptedMessage =
            [cipher throws_encryptMessage:[plainText paddedMessageBody] protocolContext:transaction];
        serializedMessage = encryptedMessage.serialized;
        messageType = [self messageTypeForCipherMessage:encryptedMessage];
    }

    BOOL isSilent = message.isSilent;
    BOOL isOnline = message.isOnline;

    OWSMessageServiceParams *messageParams =
        [[OWSMessageServiceParams alloc] initWithType:messageType
                                          recipientId:recipientID
                                               device:@(OWSDevicePrimaryDeviceId).intValue
                                              content:serializedMessage
                                             isSilent:isSilent
                                             isOnline:isOnline
                                       registrationId:[cipher throws_remoteRegistrationId:transaction]
                                                  ttl:message.ttl
                                               isPing:NO];

    NSError *error;
    NSDictionary *jsonDict = [MTLJSONAdapter JSONDictionaryFromModel:messageParams error:&error];
    
    if (error != nil) {
        return nil;
    }

    return jsonDict;
}

- (TSWhisperMessageType)messageTypeForCipherMessage:(id<CipherMessage>)cipherMessage
{
    switch (cipherMessage.cipherMessageType) {
        case CipherMessageType_Whisper:
            return TSEncryptedWhisperMessageType;
        case CipherMessageType_Prekey:
            return TSPreKeyWhisperMessageType;
        default:
            return TSUnknownMessageType;
    }
}

- (void)saveInfoMessageForGroupMessage:(TSOutgoingMessage *)message inThread:(TSThread *)thread
{
    OWSAssertDebug(message);
    OWSAssertDebug(thread);

    if (message.groupMetaMessage == TSGroupMetaMessageDeliver) {
        // TODO: Why is this necessary?
        [message save];
    } else if (message.groupMetaMessage == TSGroupMetaMessageQuit) {
        // MJK TODO - remove senderTimestamp
        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
                                         inThread:thread
                                      messageType:TSInfoMessageTypeGroupQuit
                                    customMessage:message.customMessage] save];
    } else {
        // MJK TODO - remove senderTimestamp
        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
                                         inThread:thread
                                      messageType:TSInfoMessageTypeGroupUpdate
                                    customMessage:message.customMessage] save];
    }
}

@end

@implementation OutgoingMessagePreparer

#pragma mark - Dependencies

+ (YapDatabaseConnection *)dbConnection
{
    return SSKEnvironment.shared.primaryStorage.dbReadWriteConnection;
}

#pragma mark -

+ (NSArray<NSString *> *)prepareMessageForSending:(TSOutgoingMessage *)message
                                      transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    NSMutableArray<NSString *> *attachmentIds = [NSMutableArray new];

    if (message.attachmentIds) {
        [attachmentIds addObjectsFromArray:message.attachmentIds];
    }

    if (message.quotedMessage) {
        // Though we currently only ever expect at most one thumbnail, the proto data model
        // suggests this could change. The logic is intended to work with multiple, but
        // if we ever actually want to send multiple, we should do more testing.
        NSArray<TSAttachmentStream *> *quotedThumbnailAttachments =
            [message.quotedMessage createThumbnailAttachmentsIfNecessaryWithTransaction:transaction];
        for (TSAttachmentStream *attachment in quotedThumbnailAttachments) {
            [attachmentIds addObject:attachment.uniqueId];
        }
    }

    if (message.contactShare.avatarAttachmentId != nil) {
        TSAttachment *attachment = [message.contactShare avatarAttachmentWithTransaction:transaction];
        if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
            [attachmentIds addObject:attachment.uniqueId];
        } else {
            OWSFailDebug(@"Unexpected avatarAttachment: %@.", attachment);
        }
    }

    if (message.linkPreview.imageAttachmentId != nil) {
        TSAttachment *attachment =
            [TSAttachment fetchObjectWithUniqueID:message.linkPreview.imageAttachmentId transaction:transaction];
        if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
            [attachmentIds addObject:attachment.uniqueId];
        } else {
            OWSFailDebug(@"Unexpected attachment: %@.", attachment);
        }
    }

    // All outgoing messages should be saved at the time they are enqueued.
    [message saveWithTransaction:transaction];
    // When we start a message send, all "failed" recipients should be marked as "sending".
    [message updateWithMarkingAllUnsentRecipientsAsSendingWithTransaction:transaction];

    return attachmentIds;
}

+ (void)prepareAttachments:(NSArray<OWSOutgoingAttachmentInfo *> *)attachmentInfos
                 inMessage:(TSOutgoingMessage *)outgoingMessage
         completionHandler:(void (^)(NSError *_Nullable error))completionHandler
{
    OWSAssertDebug(attachmentInfos.count > 0);
    OWSAssertDebug(outgoingMessage);

    dispatch_async([OWSDispatch attachmentsQueue], ^{
        NSMutableArray<TSAttachmentStream *> *attachmentStreams = [NSMutableArray new];
        for (OWSOutgoingAttachmentInfo *attachmentInfo in attachmentInfos) {
            TSAttachmentStream *attachmentStream =
                [[TSAttachmentStream alloc] initWithContentType:attachmentInfo.contentType
                                                      byteCount:(UInt32)attachmentInfo.dataSource.dataLength
                                                 sourceFilename:attachmentInfo.sourceFilename
                                                        caption:attachmentInfo.caption
                                                 albumMessageId:attachmentInfo.albumMessageId];
            
            if (outgoingMessage.isVoiceMessage) {
                attachmentStream.attachmentType = TSAttachmentTypeVoiceMessage;
            }

            if (![attachmentStream writeDataSource:attachmentInfo.dataSource]) {
                NSError *error = OWSErrorMakeWriteAttachmentDataError();
                completionHandler(error);
                return;
            }

            [attachmentStreams addObject:attachmentStream];
        }

        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            for (TSAttachmentStream *attachmentStream in attachmentStreams) {
                [outgoingMessage.attachmentIds addObject:attachmentStream.uniqueId];
                if (attachmentStream.sourceFilename) {
                    outgoingMessage.attachmentFilenameMap[attachmentStream.uniqueId] = attachmentStream.sourceFilename;
                }
            }
            [outgoingMessage saveWithTransaction:transaction];
            for (TSAttachmentStream *attachmentStream in attachmentStreams) {
                [attachmentStream saveWithTransaction:transaction];
            }
        }];

        completionHandler(nil);
    });
}

@end

NS_ASSUME_NONNULL_END
