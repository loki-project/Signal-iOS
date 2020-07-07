#import "OWSPrimaryStorage.h"

#import <SessionAxolotlKit/AxolotlExceptions.h>
#import <SessionAxolotlKit/PreKeyBundle.h>
#import <SessionAxolotlKit/PreKeyRecord.h>
#import <SessionCurve25519Kit/Ed25519.h>
#import <YapDatabase/YapDatabase.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LKFriendRequestStatus) {
    /// New conversation; no messages sent or received.
    LKFriendRequestStatusNone,
    /// This state is used to lock the input early while sending.
    LKFriendRequestStatusRequestSending,
    /// Friend request sent; awaiting response.
    LKFriendRequestStatusRequestSent,
    /// Friend request received; awaiting user input.
    LKFriendRequestStatusRequestReceived,
    /// We're friends with the other user.
    LKFriendRequestStatusFriends,
    /// A friend request was sent, but it timed out (i.e. the other user didn't accept within the allocated time).
    LKFriendRequestStatusRequestExpired
};

@interface OWSPrimaryStorage (Loki)

# pragma mark - Pre Key Record Management

- (BOOL)hasPreKeyRecordForContact:(NSString *)hexEncodedPublicKey;
- (PreKeyRecord *_Nullable)getPreKeyRecordForContact:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadTransaction *)transaction;
- (PreKeyRecord *)getOrCreatePreKeyRecordForContact:(NSString *)hexEncodedPublicKey;

# pragma mark - Pre Key Bundle Management

/**
 * Generates a pre key bundle for the given contact. Doesn't store the pre key bundle (pre key bundles are supposed to be sent without ever being stored).
 */
- (PreKeyBundle *)generatePreKeyBundleForContact:(NSString *)hexEncodedPublicKey;
- (PreKeyBundle *_Nullable)getPreKeyBundleForContact:(NSString *)hexEncodedPublicKey;
- (void)setPreKeyBundle:(PreKeyBundle *)bundle forContact:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)removePreKeyBundleForContact:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadWriteTransaction *)transaction;

# pragma mark - Last Message Hash

/**
 * Gets the last message hash and removes it if its `expiresAt` has already passed.
 */
- (NSString *_Nullable)getLastMessageHashForSnode:(NSString *)snode transaction:(YapDatabaseReadWriteTransaction *)transaction;
- (void)setLastMessageHashForSnode:(NSString *)snode hash:(NSString *)hash expiresAt:(u_int64_t)expiresAt transaction:(YapDatabaseReadWriteTransaction *)transaction NS_SWIFT_NAME(setLastMessageHash(forSnode:hash:expiresAt:transaction:));

# pragma mark - Open Groups

- (void)setIDForMessageWithServerID:(NSUInteger)serverID to:(NSString *)messageID in:(YapDatabaseReadWriteTransaction *)transaction;
- (NSString *_Nullable)getIDForMessageWithServerID:(NSUInteger)serverID in:(YapDatabaseReadTransaction *)transaction;
- (void)updateMessageIDCollectionByPruningMessagesWithIDs:(NSSet<NSString *> *)targetMessageIDs in:(YapDatabaseReadWriteTransaction *)transaction NS_SWIFT_NAME(updateMessageIDCollectionByPruningMessagesWithIDs(_:in:));

# pragma mark - Restoration from Seed

- (void)setRestorationTime:(NSTimeInterval)time;
- (NSTimeInterval)getRestorationTime;

# pragma mark - Friend Requests

- (NSSet<NSString *> *)getAllFriendsWithTransaction:(YapDatabaseReadTransaction *)transaction NS_SWIFT_NAME(getAllFriends(using:));
- (LKFriendRequestStatus)getFriendRequestStatusForContact:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadTransaction *)transaction NS_SWIFT_NAME(getFriendRequestStatus(for:transaction:));
- (void)setFriendRequestStatus:(LKFriendRequestStatus)friendRequestStatus forContact:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadWriteTransaction *)transaction NS_SWIFT_NAME(setFriendRequestStatus(_:for:transaction:));

@end

NS_ASSUME_NONNULL_END
