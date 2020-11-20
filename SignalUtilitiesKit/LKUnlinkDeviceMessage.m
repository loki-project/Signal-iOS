#import "LKUnlinkDeviceMessage.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>

@implementation LKUnlinkDeviceMessage

#pragma mark Initialization
- (instancetype)initWithThread:(TSThread *)thread {
    return [self initOutgoingMessageWithTimestamp:NSDate.ows_millisecondTimeStamp inThread:thread messageBody:@"" attachmentIds:[NSMutableArray<NSString *> new]
        expiresInSeconds:0 expireStartedAt:0 isVoiceMessage:NO groupMetaMessage:TSGroupMetaMessageUnspecified quotedMessage:nil contactShare:nil linkPreview:nil];
}

#pragma mark Building
- (nullable id)dataMessageBuilder
{
    SSKProtoDataMessageBuilder *builder = super.dataMessageBuilder;
    if (builder == nil) { return nil; }
    [builder setFlags:SSKProtoDataMessageFlagsUnlinkDevice];
    return builder;
}

#pragma mark Settings
- (uint)ttl { return (uint)[LKTTLUtilities getTTLFor:LKMessageTypeUnlinkDevice]; }
- (BOOL)shouldSyncTranscript { return NO; }
- (BOOL)shouldBeSaved { return NO; }

@end
