//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <SessionUtilitiesKit/TSYapDatabaseObject.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OWSUserProfileCompletion)(void);

@class OWSAES256Key;

extern NSString *const kNSNotificationName_LocalProfileDidChange;
extern NSString *const kNSNotificationName_OtherUsersProfileWillChange;
extern NSString *const kNSNotificationName_OtherUsersProfileDidChange;

extern NSString *const kNSNotificationKey_ProfileRecipientId;
extern NSString *const kNSNotificationKey_ProfileGroupId;

extern NSString *const kLocalProfileUniqueId;

// This class should be completely thread-safe.
//
// It is critical for coherency that all DB operations for this
// class should be done on OWSProfileManager's dbConnection.
@interface OWSUserProfile : TSYapDatabaseObject

@property (atomic, readonly) NSString *recipientId;
@property (atomic, nullable) OWSAES256Key *profileKey;
@property (atomic, nullable) NSString *profileName;
@property (atomic, nullable) NSString *avatarUrlPath;
// This filename is relative to OWSProfileManager.profileAvatarsDirPath.
@property (atomic, readonly, nullable) NSString *avatarFileName;

- (instancetype)init NS_UNAVAILABLE;

+ (OWSUserProfile *)getOrBuildUserProfileForRecipientId:(NSString *)recipientId
                                           dbConnection:(YapDatabaseConnection *)dbConnection;

+ (OWSUserProfile *)getOrBuildUserProfileForRecipientId:(NSString *)recipientId transaction:(YapDatabaseReadWriteTransaction *)transaction;

+ (BOOL)localUserProfileExists:(YapDatabaseConnection *)dbConnection;

#pragma mark - Update With... Methods

- (void)updateWithProfileName:(nullable NSString *)profileName
                avatarUrlPath:(nullable NSString *)avatarUrlPath
               avatarFileName:(nullable NSString *)avatarFileName
                  transaction:(YapDatabaseReadWriteTransaction *)transaction
                   completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithProfileName:(nullable NSString *)profileName
                avatarUrlPath:(nullable NSString *)avatarUrlPath
               avatarFileName:(nullable NSString *)avatarFileName
                 dbConnection:(YapDatabaseConnection *)dbConnection
                   completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithProfileName:(nullable NSString *)profileName
                avatarUrlPath:(nullable NSString *)avatarUrlPath
                 dbConnection:(YapDatabaseConnection *)dbConnection
                   completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithAvatarUrlPath:(nullable NSString *)avatarUrlPath
                 avatarFileName:(nullable NSString *)avatarFileName
                   dbConnection:(YapDatabaseConnection *)dbConnection
                     completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithAvatarFileName:(nullable NSString *)avatarFileName
                    dbConnection:(YapDatabaseConnection *)dbConnection
                      completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithProfileKey:(OWSAES256Key *)profileKey
                dbConnection:(YapDatabaseConnection *)dbConnection
                  completion:(nullable OWSUserProfileCompletion)completion;

- (void)updateWithProfileKey:(OWSAES256Key *)profileKey
                 transaction:(YapDatabaseReadWriteTransaction *)transaction
                  completion:(nullable OWSUserProfileCompletion)completion;

- (void)clearWithProfileKey:(OWSAES256Key *)profileKey
               dbConnection:(YapDatabaseConnection *)dbConnection
                 completion:(nullable OWSUserProfileCompletion)completion;

#pragma mark - Profile Avatars Directory

+ (NSString *)profileAvatarFilepathWithFilename:(NSString *)filename;
+ (nullable NSError *)migrateToSharedData;
+ (NSString *)legacyProfileAvatarsDirPath;
+ (NSString *)sharedDataProfileAvatarsDirPath;
+ (NSString *)profileAvatarsDirPath;
+ (void)resetProfileStorage;
+ (NSSet<NSString *> *)allProfileAvatarFilePaths;

@end

NS_ASSUME_NONNULL_END
