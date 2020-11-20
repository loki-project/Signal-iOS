//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/OWSPrimaryStorage.h>
#import <SessionProtocolKit/SessionStore.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSPrimaryStorage (SessionStore) <SessionStore>

- (void)archiveAllSessionsForContact:(NSString *)contactIdentifier protocolContext:(nullable id)protocolContext;

#pragma mark - Debug

- (void)resetSessionStore:(YapDatabaseReadWriteTransaction *)transaction;

#if DEBUG
- (void)snapshotSessionStore:(YapDatabaseReadWriteTransaction *)transaction;
- (void)restoreSessionStore:(YapDatabaseReadWriteTransaction *)transaction;
#endif

- (void)printAllSessions;

@end

NS_ASSUME_NONNULL_END
