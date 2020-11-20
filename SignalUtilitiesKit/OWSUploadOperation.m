//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSUploadOperation.h"
#import "MIMETypeUtil.h"
#import "NSError+MessageSending.h"
#import "NSNotificationCenter+OWS.h"
#import "OWSDispatch.h"
#import "OWSError.h"
#import "OWSOperation.h"
#import "OWSRequestFactory.h"
#import "SSKEnvironment.h"
#import "TSAttachmentStream.h"
#import "TSNetworkManager.h"
#import <SignalCoreKit/Cryptography.h>
#import <YapDatabase/YapDatabaseConnection.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kAttachmentUploadProgressNotification = @"kAttachmentUploadProgressNotification";
NSString *const kAttachmentUploadProgressKey = @"kAttachmentUploadProgressKey";
NSString *const kAttachmentUploadAttachmentIDKey = @"kAttachmentUploadAttachmentIDKey";

// Use a slightly non-zero value to ensure that the progress
// indicator shows up as quickly as possible.
static const CGFloat kAttachmentUploadProgressTheta = 0.001f;

@interface OWSUploadOperation ()

@property (readonly, nonatomic) NSString *attachmentId;
@property (readonly, nonatomic) NSString *threadID;
@property (readonly, nonatomic) YapDatabaseConnection *dbConnection;

@end

#pragma mark -

@implementation OWSUploadOperation

- (instancetype)initWithAttachmentId:(NSString *)attachmentId
                            threadID:(NSString *)threadID
                        dbConnection:(YapDatabaseConnection *)dbConnection
{
    self = [super init];
    if (!self) {
        return self;
    }

    self.remainingRetries = 4;

    _attachmentId = attachmentId;
    _threadID = threadID;
    _dbConnection = dbConnection;

    return self;
}

- (TSNetworkManager *)networkManager
{
    return SSKEnvironment.shared.networkManager;
}

- (void)run
{
    __block TSAttachmentStream *attachmentStream;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        attachmentStream = [TSAttachmentStream fetchObjectWithUniqueID:self.attachmentId transaction:transaction];
    }];

    if (!attachmentStream) {
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        // Not finding a local attachment is a terminal failure
        error.isRetryable = NO;
        [self reportError:error];
        return;
    }

    if (attachmentStream.isUploaded) {
        OWSLogDebug(@"Attachment previously uploaded.");
        [self reportSuccess];
        return;
    }
    
    [self fireNotificationWithProgress:0];
    
    __block SNOpenGroup *publicChat;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        publicChat = [LKDatabaseUtilities getPublicChatForThreadID:self.threadID transaction:transaction];
    }];
    NSString *server = (publicChat != nil) ? publicChat.server : SNFileServerAPI.server;
    
    [[SNFileServerAPI uploadAttachment:attachmentStream withID:self.attachmentId toServer:server]
    .thenOn(dispatch_get_main_queue(), ^() {
        [self reportSuccess];
    })
    .catchOn(dispatch_get_main_queue(), ^(NSError *error) {
        [self reportError:error];
    }) retainUntilComplete];
}

- (void)uploadWithServerId:(UInt64)serverId
                  location:(NSString *)location
          attachmentStream:(TSAttachmentStream *)attachmentStream
{
    OWSLogDebug(@"started uploading data for attachment: %@", self.attachmentId);
    NSError *error;
    NSData *attachmentData = [attachmentStream readDataFromFileAndReturnError:&error];
    if (error) {
        OWSLogError(@"Failed to read attachment data with error: %@", error);
        error.isRetryable = YES;
        [self reportError:error];
        return;
    }

    NSData *encryptionKey;
    NSData *digest;
    NSData *_Nullable encryptedAttachmentData =
        [Cryptography encryptAttachmentData:attachmentData shouldPad:YES outKey:&encryptionKey outDigest:&digest];
    if (!encryptedAttachmentData) {
        OWSFailDebug(@"could not encrypt attachment data.");
        error = OWSErrorMakeFailedToSendOutgoingMessageError();
        error.isRetryable = YES;
        [self reportError:error];
        return;
    }
    attachmentStream.encryptionKey = encryptionKey;
    attachmentStream.digest = digest;

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:location]];
    request.HTTPMethod = @"PUT";
    [request setValue:OWSMimeTypeApplicationOctetStream forHTTPHeaderField:@"Content-Type"];

    AFURLSessionManager *manager = [[AFURLSessionManager alloc]
        initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];

    NSURLSessionUploadTask *uploadTask;
    uploadTask = [manager uploadTaskWithRequest:request
        fromData:encryptedAttachmentData
        progress:^(NSProgress *_Nonnull uploadProgress) {
            [self fireNotificationWithProgress:uploadProgress.fractionCompleted];
        }
        completionHandler:^(NSURLResponse *_Nonnull response, id _Nullable responseObject, NSError *_Nullable error) {
            OWSAssertIsOnMainThread();
            if (error) {
                error.isRetryable = YES;
                [self reportError:error];
                return;
            }

            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            BOOL isValidResponse = (statusCode >= 200) && (statusCode < 400);
            if (!isValidResponse) {
                OWSLogError(@"Unexpected server response: %d", (int)statusCode);
                NSError *invalidResponseError = OWSErrorMakeUnableToProcessServerResponseError();
                invalidResponseError.isRetryable = YES;
                [self reportError:invalidResponseError];
                return;
            }

            OWSLogInfo(@"Uploaded attachment: %p serverId: %llu, byteCount: %u",
                attachmentStream.uniqueId,
                attachmentStream.serverId,
                attachmentStream.byteCount);
            attachmentStream.serverId = serverId;
            attachmentStream.isUploaded = YES;
            [attachmentStream saveAsyncWithCompletionBlock:^{
                [self reportSuccess];
            }];
        }];

    [uploadTask resume];
}

- (void)fireNotificationWithProgress:(CGFloat)aProgress
{
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    CGFloat progress = MAX(kAttachmentUploadProgressTheta, aProgress);
    [notificationCenter postNotificationNameAsync:kAttachmentUploadProgressNotification
                                           object:nil
                                         userInfo:@{
                                             kAttachmentUploadProgressKey : @(progress),
                                             kAttachmentUploadAttachmentIDKey : self.attachmentId
                                         }];
}

@end

NS_ASSUME_NONNULL_END
