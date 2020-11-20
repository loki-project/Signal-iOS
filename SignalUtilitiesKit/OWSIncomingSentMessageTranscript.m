//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSIncomingSentMessageTranscript.h"
#import "OWSContact.h"
#import "OWSMessageManager.h"
#import "OWSPrimaryStorage.h"
#import "TSContactThread.h"
#import "TSGroupModel.h"
#import "TSGroupThread.h"
#import "TSOutgoingMessage.h"
#import "TSQuotedMessage.h"
#import "TSThread.h"
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSIncomingSentMessageTranscript

- (instancetype)initWithProto:(SSKProtoSyncMessageSent *)sentProto
                  transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    self = [super init];
    if (!self) {
        return self;
    }

    _dataMessage = sentProto.message;
    _recipientId = sentProto.destination;
    _timestamp = sentProto.timestamp;
    _expirationStartedAt = sentProto.expirationStartTimestamp;
    _expirationDuration = sentProto.message.expireTimer;
    _body = _dataMessage.body;
    _groupId = _dataMessage.group.id;
    _isGroupUpdate = _dataMessage.group != nil && (_dataMessage.group.type == SSKProtoGroupContextTypeUpdate);
    _isGroupQuit = _dataMessage.group != nil && (_dataMessage.group.type == SSKProtoGroupContextTypeQuit);
    _isExpirationTimerUpdate = (_dataMessage.flags & SSKProtoDataMessageFlagsExpirationTimerUpdate) != 0;
    _isEndSessionMessage = (_dataMessage.flags & SSKProtoDataMessageFlagsEndSession) != 0;
    _isRecipientUpdate = sentProto.isRecipientUpdate;

    if (self.isRecipientUpdate) {
        // Fetch, don't create.  We don't want recipient updates to resurrect messages or threads.
        if (self.dataMessage.group) {
            _thread = [TSGroupThread threadWithGroupId:_dataMessage.group.id transaction:transaction];
        } else {
            OWSFailDebug(@"We should never receive a 'recipient update' for messages in contact threads.");
        }
        // Skip the other processing for recipient updates.
    } else {
        if (self.dataMessage.group) {
            _thread = [TSGroupThread getOrCreateThreadWithGroupId:_dataMessage.group.id groupType:closedGroup transaction:transaction];
        } else {
            _thread = [TSContactThread getOrCreateThreadWithContactId:_recipientId transaction:transaction];
        }

        _quotedMessage =
            [TSQuotedMessage quotedMessageForDataMessage:_dataMessage thread:_thread transaction:transaction];
        _contact = [OWSContacts contactForDataMessage:_dataMessage transaction:transaction];

        NSError *linkPreviewError;
        _linkPreview = [OWSLinkPreview buildValidatedLinkPreviewWithDataMessage:_dataMessage
                                                                           body:_body
                                                                    transaction:transaction
                                                                          error:&linkPreviewError];
        if (linkPreviewError && ![OWSLinkPreview isNoPreviewError:linkPreviewError]) {
            OWSLogError(@"linkPreviewError: %@", linkPreviewError);
        }
    }

    if (sentProto.unidentifiedStatus.count > 0) {
        NSMutableArray<NSString *> *nonUdRecipientIds = [NSMutableArray new];
        NSMutableArray<NSString *> *udRecipientIds = [NSMutableArray new];
        for (SSKProtoSyncMessageSentUnidentifiedDeliveryStatus *statusProto in sentProto.unidentifiedStatus) {
            if (!statusProto.hasDestination || statusProto.destination.length < 1) {
                OWSFailDebug(@"Delivery status proto is missing destination.");
                continue;
            }
            if (!statusProto.hasUnidentified) {
                OWSFailDebug(@"Delivery status proto is missing value.");
                continue;
            }
            NSString *recipientId = statusProto.destination;
            if (statusProto.unidentified) {
                [udRecipientIds addObject:recipientId];
            } else {
                [nonUdRecipientIds addObject:recipientId];
            }
        }
        _nonUdRecipientIds = [nonUdRecipientIds copy];
        _udRecipientIds = [udRecipientIds copy];
    }

    return self;
}

- (NSArray<SSKProtoAttachmentPointer *> *)attachmentPointerProtos
{
    if (self.isGroupUpdate && self.dataMessage.group.avatar) {
        return @[ self.dataMessage.group.avatar ];
    } else {
        return self.dataMessage.attachments;
    }
}

@end

NS_ASSUME_NONNULL_END
