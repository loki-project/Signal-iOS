//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSEndSessionMessage.h"
#import "OWSPrimaryStorage+Loki.h"
#import "SignalRecipient.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSEndSessionMessage

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp inThread:(nullable TSThread *)thread
{
    return [super initOutgoingMessageWithTimestamp:timestamp
                                          inThread:thread
                                       messageBody:nil
                                     attachmentIds:[NSMutableArray new]
                                  expiresInSeconds:0
                                   expireStartedAt:0
                                    isVoiceMessage:NO
                                  groupMetaMessage:TSGroupMetaMessageUnspecified
                                     quotedMessage:nil
                                      contactShare:nil
                                       linkPreview:nil];
}

- (BOOL)shouldBeSaved
{
    return NO;
}

- (uint)ttl { return (uint)[LKTTLUtilities getTTLFor:LKMessageTypeEphemeral]; }

- (nullable id)dataMessageBuilder
{
    SSKProtoDataMessageBuilder *_Nullable builder = [super dataMessageBuilder];
    if (!builder) {
        return nil;
    }
    [builder setTimestamp:self.timestamp];
    [builder setFlags:SSKProtoDataMessageFlagsEndSession];

    return builder;
}

- (nullable id)prepareCustomContentBuilder:(SignalRecipient *)recipient {
    SSKProtoContentBuilder *builder = [super prepareCustomContentBuilder:recipient];
    
    PreKeyBundle *bundle = [OWSPrimaryStorage.sharedManager generatePreKeyBundleForContact:recipient.recipientId];
    SSKProtoPrekeyBundleMessageBuilder *preKeyBuilder = [SSKProtoPrekeyBundleMessage builderFromPreKeyBundle:bundle];
    
    // Build the pre key bundle message
    NSError *error;
    SSKProtoPrekeyBundleMessage *_Nullable message = [preKeyBuilder buildAndReturnError:&error];
    if (error || !message) {
        OWSFailDebug(@"Failed to build pre key bundle for: %@ due to error: %@.", recipient.recipientId, error);
    } else {
        [builder setPrekeyBundleMessage:message];
    }
    
    return builder;
}

@end

NS_ASSUME_NONNULL_END
