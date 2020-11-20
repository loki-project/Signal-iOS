//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "AppSetup.h"
#import "Environment.h"
#import "VersionMigrations.h"
#import <SignalUtilitiesKit/OWSDatabaseMigration.h>
#import <SignalUtilitiesKit/OWSProfileManager.h>
#import <SessionProtocolKit/SessionProtocolKit-Swift.h>
#import <SignalUtilitiesKit/ContactDiscoveryService.h>
#import <SignalUtilitiesKit/OWS2FAManager.h>
#import <SignalUtilitiesKit/OWSAttachmentDownloads.h>
#import <SignalUtilitiesKit/OWSBackgroundTask.h>
#import <SignalUtilitiesKit/OWSBatchMessageProcessor.h>
#import <SignalUtilitiesKit/OWSBlockingManager.h>
#import <SignalUtilitiesKit/OWSDisappearingMessagesJob.h>
#import <SignalUtilitiesKit/OWSIdentityManager.h>
#import <SignalUtilitiesKit/OWSMessageDecrypter.h>
#import <SignalUtilitiesKit/OWSMessageManager.h>
#import <SignalUtilitiesKit/OWSMessageReceiver.h>
#import <SignalUtilitiesKit/OWSOutgoingReceiptManager.h>
#import <SignalUtilitiesKit/OWSReadReceiptManager.h>
#import <SignalUtilitiesKit/OWSSounds.h>
#import <SignalUtilitiesKit/OWSStorage.h>
#import <SignalUtilitiesKit/SSKEnvironment.h>
#import <SignalUtilitiesKit/OWSSyncManager.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>
#import <SignalUtilitiesKit/TSSocketManager.h>

NS_ASSUME_NONNULL_BEGIN

@implementation AppSetup

+ (void)setupEnvironmentWithAppSpecificSingletonBlock:(dispatch_block_t)appSpecificSingletonBlock
                                  migrationCompletion:(dispatch_block_t)migrationCompletion
{
    OWSAssertDebug(appSpecificSingletonBlock);
    OWSAssertDebug(migrationCompletion);

    __block OWSBackgroundTask *_Nullable backgroundTask =
        [OWSBackgroundTask backgroundTaskWithLabelStr:__PRETTY_FUNCTION__];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Order matters here.
        //
        // All of these "singletons" should have any dependencies used in their
        // initializers injected.
        [[OWSBackgroundTaskManager sharedManager] observeNotifications];

        OWSPrimaryStorage *primaryStorage = [[OWSPrimaryStorage alloc] initStorage];
        [OWSPrimaryStorage protectFiles];

        // AFNetworking (via CFNetworking) spools it's attachments to NSTemporaryDirectory().
        // If you receive a media message while the device is locked, the download will fail if the temporary directory
        // is NSFileProtectionComplete
        BOOL success = [OWSFileSystem protectFileOrFolderAtPath:NSTemporaryDirectory()
                                             fileProtectionType:NSFileProtectionCompleteUntilFirstUserAuthentication];
        OWSAssert(success);

        OWSPreferences *preferences = [OWSPreferences new];

        TSNetworkManager *networkManager = [[TSNetworkManager alloc] initDefault];
        OWSContactsManager *contactsManager = [[OWSContactsManager alloc] initWithPrimaryStorage:primaryStorage];
        ContactsUpdater *contactsUpdater = [ContactsUpdater new];
        OWSMessageSender *messageSender = [[OWSMessageSender alloc] initWithPrimaryStorage:primaryStorage];
        SSKMessageSenderJobQueue *messageSenderJobQueue = [SSKMessageSenderJobQueue new];
        OWSProfileManager *profileManager = [[OWSProfileManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSMessageManager *messageManager = [[OWSMessageManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSBlockingManager *blockingManager = [[OWSBlockingManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSIdentityManager *identityManager = [[OWSIdentityManager alloc] initWithPrimaryStorage:primaryStorage];
        id<OWSUDManager> udManager = [[OWSUDManagerImpl alloc] initWithPrimaryStorage:primaryStorage];
        OWSMessageDecrypter *messageDecrypter = [[OWSMessageDecrypter alloc] initWithPrimaryStorage:primaryStorage];
        OWSBatchMessageProcessor *batchMessageProcessor =
            [[OWSBatchMessageProcessor alloc] initWithPrimaryStorage:primaryStorage];
        OWSMessageReceiver *messageReceiver = [[OWSMessageReceiver alloc] initWithPrimaryStorage:primaryStorage];
        TSSocketManager *socketManager = [[TSSocketManager alloc] init];
        TSAccountManager *tsAccountManager = [[TSAccountManager alloc] initWithPrimaryStorage:primaryStorage];
        OWS2FAManager *ows2FAManager = [[OWS2FAManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSDisappearingMessagesJob *disappearingMessagesJob =
            [[OWSDisappearingMessagesJob alloc] initWithPrimaryStorage:primaryStorage];
        ContactDiscoveryService *contactDiscoveryService = [[ContactDiscoveryService alloc] initDefault];
        OWSReadReceiptManager *readReceiptManager =
            [[OWSReadReceiptManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSOutgoingReceiptManager *outgoingReceiptManager =
            [[OWSOutgoingReceiptManager alloc] initWithPrimaryStorage:primaryStorage];
        OWSSyncManager *syncManager = [[OWSSyncManager alloc] initDefault];
        id<SSKReachabilityManager> reachabilityManager = [SSKReachabilityManagerImpl new];
        id<OWSTypingIndicators> typingIndicators = [[OWSTypingIndicatorsImpl alloc] init];
        OWSAttachmentDownloads *attachmentDownloads = [[OWSAttachmentDownloads alloc] init];

        OWSAudioSession *audioSession = [OWSAudioSession new];
        OWSSounds *sounds = [[OWSSounds alloc] initWithPrimaryStorage:primaryStorage];
        id<OWSProximityMonitoringManager> proximityMonitoringManager = [OWSProximityMonitoringManagerImpl new];
        OWSWindowManager *windowManager = [[OWSWindowManager alloc] initDefault];
        
        [Environment setShared:[[Environment alloc] initWithAudioSession:audioSession
                                                             preferences:preferences
                                              proximityMonitoringManager:proximityMonitoringManager
                                                                  sounds:sounds
                                                           windowManager:windowManager]];

        [SSKEnvironment setShared:[[SSKEnvironment alloc] initWithContactsManager:contactsManager
                                                                    messageSender:messageSender
                                                            messageSenderJobQueue:messageSenderJobQueue
                                                                   profileManager:profileManager
                                                                   primaryStorage:primaryStorage
                                                                  contactsUpdater:contactsUpdater
                                                                   networkManager:networkManager
                                                                   messageManager:messageManager
                                                                  blockingManager:blockingManager
                                                                  identityManager:identityManager
                                                                        udManager:udManager
                                                                 messageDecrypter:messageDecrypter
                                                            batchMessageProcessor:batchMessageProcessor
                                                                  messageReceiver:messageReceiver
                                                                    socketManager:socketManager
                                                                 tsAccountManager:tsAccountManager
                                                                    ows2FAManager:ows2FAManager
                                                          disappearingMessagesJob:disappearingMessagesJob
                                                          contactDiscoveryService:contactDiscoveryService
                                                               readReceiptManager:readReceiptManager
                                                           outgoingReceiptManager:outgoingReceiptManager
                                                              reachabilityManager:reachabilityManager
                                                                      syncManager:syncManager
                                                                 typingIndicators:typingIndicators
                                                              attachmentDownloads:attachmentDownloads]];

        appSpecificSingletonBlock();

        OWSAssertDebug(SSKEnvironment.shared.isComplete);

        // Register renamed classes.
        [NSKeyedUnarchiver setClass:[OWSUserProfile class] forClassName:[OWSUserProfile collection]];
        [NSKeyedUnarchiver setClass:[OWSDatabaseMigration class] forClassName:[OWSDatabaseMigration collection]];

        [OWSStorage registerExtensionsWithMigrationBlock:^() {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Don't start database migrations until storage is ready.
                [VersionMigrations performUpdateCheckWithCompletion:^() {
                    OWSAssertIsOnMainThread();

                    migrationCompletion();

                    OWSAssertDebug(backgroundTask);
                    backgroundTask = nil;
                }];
            });
        }];
    });
}

@end

NS_ASSUME_NONNULL_END
