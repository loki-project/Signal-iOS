//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

@class OWSAES256Key;
@class TSThread;
@class YapDatabaseReadWriteTransaction;

NS_ASSUME_NONNULL_BEGIN

@protocol ProfileManagerProtocol <NSObject>

- (OWSAES256Key *)localProfileKey;

- (nullable NSString *)localProfileName;
- (nullable NSString *)profileNameForRecipientId:(NSString *)recipientId;
- (nullable NSString *)profilePictureURL;

- (nullable NSData *)profileKeyDataForRecipientId:(NSString *)recipientId;
- (void)setProfileKeyData:(NSData *)profileKeyData forRecipientId:(NSString *)recipientId;

- (BOOL)isUserInProfileWhitelist:(NSString *)recipientId;

- (BOOL)isThreadInProfileWhitelist:(TSThread *)thread;

- (void)addUserToProfileWhitelist:(NSString *)recipientId;
- (void)addGroupIdToProfileWhitelist:(NSData *)groupId;

- (void)fetchLocalUsersProfile;

- (void)fetchProfileForRecipientId:(NSString *)recipientId;

- (void)updateProfileForContactWithID:(NSString *)contactID displayName:(NSString *)displayName profilePictureURL:(NSString *)profilePictureURL with:(YapDatabaseReadWriteTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END
