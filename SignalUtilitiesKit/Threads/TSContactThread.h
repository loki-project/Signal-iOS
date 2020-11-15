//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/TSThread.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TSContactThreadPrefix;

typedef NS_ENUM(NSInteger, SNSessionRestorationStatus);

@interface TSContactThread : TSThread

@property (atomic) SNSessionRestorationStatus sessionRestorationStatus;
@property (nonatomic) BOOL hasDismissedOffers;

- (instancetype)initWithContactId:(NSString *)contactId;

+ (instancetype)getOrCreateThreadWithContactId:(NSString *)contactId NS_SWIFT_NAME(getOrCreateThread(contactId:));

+ (instancetype)getOrCreateThreadWithContactId:(NSString *)contactId
                                   transaction:(YapDatabaseReadWriteTransaction *)transaction;

// Unlike getOrCreateThreadWithContactId, this will _NOT_ create a thread if one does not already exist.
+ (nullable instancetype)getThreadWithContactId:(NSString *)contactId transaction:(YapDatabaseReadTransaction *)transaction;

- (NSString *)contactIdentifier;

+ (NSString *)contactIdFromThreadId:(NSString *)threadId;

+ (NSString *)threadIdFromContactId:(NSString *)contactId;

@end

NS_ASSUME_NONNULL_END