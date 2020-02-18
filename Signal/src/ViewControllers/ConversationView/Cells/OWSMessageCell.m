//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageCell.h"
#import "OWSContactAvatarBuilder.h"
#import "OWSMessageBubbleView.h"
#import "OWSMessageHeaderView.h"
#import "Session-Swift.h"
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageCell ()

// The nullable properties are created as needed.
// The non-nullable properties are so frequently used that it's easier
// to always keep one around.

@property (nonatomic) OWSMessageHeaderView *headerView;
@property (nonatomic) OWSMessageBubbleView *messageBubbleView;
@property (nonatomic) NSLayoutConstraint *messageBubbleViewBottomConstraint;
@property (nonatomic) LKProfilePictureView *avatarView;
@property (nonatomic) UIImageView *moderatorIconImageView;
@property (nonatomic, nullable) LKFriendRequestView *friendRequestView;
@property (nonatomic, nullable) UIImageView *sendFailureBadgeView;

@property (nonatomic, nullable) NSMutableArray<NSLayoutConstraint *> *viewConstraints;
@property (nonatomic) BOOL isPresentingMenuController;

@end

#pragma mark -

@implementation OWSMessageCell

// `[UIView init]` invokes `[self initWithFrame:...]`.
- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        [self commonInit];
    }

    return self;
}

- (void)commonInit
{
    // Ensure only called once.
    OWSAssertDebug(!self.messageBubbleView);

    self.layoutMargins = UIEdgeInsetsZero;
    self.contentView.layoutMargins = UIEdgeInsetsZero;

    _viewConstraints = [NSMutableArray new];

    self.messageBubbleView = [OWSMessageBubbleView new];
    [self.contentView addSubview:self.messageBubbleView];

    self.headerView = [OWSMessageHeaderView new];

    self.avatarView = [[LKProfilePictureView alloc] init];
    [self.avatarView autoSetDimension:ALDimensionWidth toSize:self.avatarSize];
    [self.avatarView autoSetDimension:ALDimensionHeight toSize:self.avatarSize];

    self.moderatorIconImageView = [[UIImageView alloc] init];
    [self.moderatorIconImageView autoSetDimension:ALDimensionWidth toSize:20.f];
    [self.moderatorIconImageView autoSetDimension:ALDimensionHeight toSize:20.f];
    self.moderatorIconImageView.hidden = YES;
    
    self.messageBubbleViewBottomConstraint = [self.messageBubbleView autoPinBottomToSuperviewMarginWithInset:0];

    self.contentView.userInteractionEnabled = YES;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapGesture:)];
    [self addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPressGesture:)];
    [self.contentView addGestureRecognizer:longPress];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setConversationStyle:(nullable ConversationStyle *)conversationStyle
{
    [super setConversationStyle:conversationStyle];

    self.messageBubbleView.conversationStyle = conversationStyle;
}

+ (NSString *)cellReuseIdentifier
{
    return NSStringFromClass([self class]);
}

#pragma mark - Convenience Accessors

- (OWSMessageCellType)cellType
{
    return self.viewItem.messageCellType;
}

- (TSMessage *)message
{
    OWSAssertDebug([self.viewItem.interaction isKindOfClass:[TSMessage class]]);

    return (TSMessage *)self.viewItem.interaction;
}

- (BOOL)isIncoming
{
    return self.viewItem.interaction.interactionType == OWSInteractionType_IncomingMessage;
}

- (BOOL)isOutgoing
{
    return self.viewItem.interaction.interactionType == OWSInteractionType_OutgoingMessage;
}

- (BOOL)shouldHaveSendFailureBadge
{
    if (![self.viewItem.interaction isKindOfClass:[TSOutgoingMessage class]]) {
        return NO;
    }
    TSOutgoingMessage *outgoingMessage = (TSOutgoingMessage *)self.viewItem.interaction;
    return outgoingMessage.messageState == TSOutgoingMessageStateFailed;
}

#pragma mark - Load

- (void)loadForDisplay
{
    OWSAssertDebug(self.conversationStyle);
    OWSAssertDebug(self.viewItem);
    OWSAssertDebug(self.viewItem.interaction);
    OWSAssertDebug([self.viewItem.interaction isKindOfClass:[TSMessage class]]);
    OWSAssertDebug(self.messageBubbleView);

    [self.messageBubbleViewBottomConstraint setActive:YES];
    self.messageBubbleView.viewItem = self.viewItem;
    self.messageBubbleView.cellMediaCache = self.delegate.cellMediaCache;
    [self.messageBubbleView configureViews];
    [self.messageBubbleView loadContent];

    if (self.viewItem.hasCellHeader) {
        CGFloat headerHeight =
            [self.headerView measureWithConversationViewItem:self.viewItem conversationStyle:self.conversationStyle]
                .height;
        [self.headerView loadForDisplayWithViewItem:self.viewItem conversationStyle:self.conversationStyle];
        [self.contentView addSubview:self.headerView];
        [self.viewConstraints addObjectsFromArray:@[
            [self.headerView autoSetDimension:ALDimensionHeight toSize:headerHeight],
            [self.headerView autoPinEdgeToSuperviewEdge:ALEdgeLeading],
            [self.headerView autoPinEdgeToSuperviewEdge:ALEdgeTrailing],
            [self.headerView autoPinEdgeToSuperviewEdge:ALEdgeTop],
            [self.messageBubbleView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.headerView],
        ]];
    } else {
        [self.viewConstraints addObjectsFromArray:@[
            [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeTop],
        ]];
    }

    if (self.isIncoming) {
        [self.viewConstraints addObjectsFromArray:@[
            [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeLeading
                                                     withInset:self.conversationStyle.gutterLeading],
            [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeTrailing
                                                     withInset:self.conversationStyle.gutterTrailing
                                                      relation:NSLayoutRelationGreaterThanOrEqual],
        ]];
    } else {
        if (self.shouldHaveSendFailureBadge) {
            self.sendFailureBadgeView = [UIImageView new];
            self.sendFailureBadgeView.image =
                [self.sendFailureBadge imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            self.sendFailureBadgeView.tintColor = LKColors.destructive;
            [self.contentView addSubview:self.sendFailureBadgeView];

            CGFloat sendFailureBadgeBottomMargin
                = round(self.conversationStyle.lastTextLineAxis - self.sendFailureBadgeSize * 0.5f);
            [self.viewConstraints addObjectsFromArray:@[
                [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeLeading
                                                         withInset:self.conversationStyle.gutterLeading
                                                          relation:NSLayoutRelationGreaterThanOrEqual],
                [self.sendFailureBadgeView autoPinLeadingToTrailingEdgeOfView:self.messageBubbleView
                                                                       offset:self.sendFailureBadgeSpacing],
                // V-align the "send failure" badge with the
                // last line of the text (if any, or where it
                // would be).
                [self.messageBubbleView autoPinEdge:ALEdgeBottom
                                             toEdge:ALEdgeBottom
                                             ofView:self.sendFailureBadgeView
                                         withOffset:sendFailureBadgeBottomMargin],
                [self.sendFailureBadgeView autoPinEdgeToSuperviewEdge:ALEdgeTrailing
                                                            withInset:self.conversationStyle.errorGutterTrailing],
                [self.sendFailureBadgeView autoSetDimension:ALDimensionWidth toSize:self.sendFailureBadgeSize],
                [self.sendFailureBadgeView autoSetDimension:ALDimensionHeight toSize:self.sendFailureBadgeSize],
            ]];
        } else {
            [self.viewConstraints addObjectsFromArray:@[
                [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeLeading
                                                         withInset:self.conversationStyle.gutterLeading
                                                          relation:NSLayoutRelationGreaterThanOrEqual],
                [self.messageBubbleView autoPinEdgeToSuperviewEdge:ALEdgeTrailing
                                                         withInset:self.conversationStyle.gutterTrailing],
            ]];
        }
    }
    
    // Loki: Attach the friend request view if needed
    if ([self shouldShowFriendRequestUIForMessage:self.message]) {
        self.friendRequestView = [[LKFriendRequestView alloc] initWithMessage:self.message];
        self.friendRequestView.delegate = self.friendRequestViewDelegate;
        [self.contentView addSubview:self.friendRequestView];
        [self.messageBubbleViewBottomConstraint setActive:NO];
        [self.viewConstraints addObjectsFromArray:@[
            [self.friendRequestView autoPinEdgeToSuperviewEdge:ALEdgeLeading withInset:self.conversationStyle.gutterLeading],
            [self.friendRequestView autoPinEdgeToSuperviewEdge:ALEdgeTrailing withInset:self.conversationStyle.gutterTrailing],
            [self.friendRequestView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.messageBubbleView],
            [self.friendRequestView autoPinEdgeToSuperviewEdge:ALEdgeBottom]
        ]];
    }

    if ([self updateAvatarView]) {
        [self.viewConstraints addObjectsFromArray:@[
            [self.messageBubbleView autoPinLeadingToTrailingEdgeOfView:self.avatarView offset:LKValues.largeSpacing],
            [self.messageBubbleView autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.avatarView],
        ]];
        
        [self.viewConstraints addObjectsFromArray:@[
            [self.moderatorIconImageView autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.avatarView],
            [self.moderatorIconImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:self.avatarView withOffset:3.5]
        ]];
    }
}

- (UIImage *)sendFailureBadge
{
    UIImage *image = [UIImage imageNamed:@"message_status_failed_large"];
    OWSAssertDebug(image);
    OWSAssertDebug(image.size.width == self.sendFailureBadgeSize && image.size.height == self.sendFailureBadgeSize);
    return image;
}

- (CGFloat)sendFailureBadgeSize
{
    return 20.f;
}

- (CGFloat)sendFailureBadgeSpacing
{
    return 8.f;
}

// * If cell is visible, lazy-load (expensive) view contents.
// * If cell is not visible, eagerly unload view contents.
- (void)ensureMediaLoadState
{
    OWSAssertDebug(self.messageBubbleView);

    if (!self.isCellVisible) {
        [self.messageBubbleView unloadContent];
    } else {
        [self.messageBubbleView loadContent];
    }
}

#pragma mark - Avatar

// Returns YES IFF the avatar view is appropriate and configured.
- (BOOL)updateAvatarView
{
    if (!self.viewItem.shouldShowSenderAvatar) {
        return NO;
    }
    if (!self.viewItem.isGroupThread) {
        OWSFailDebug(@"not a group thread.");
        return NO;
    }
    if (self.viewItem.interaction.interactionType != OWSInteractionType_IncomingMessage) {
        OWSFailDebug(@"not an incoming message.");
        return NO;
    }

    TSIncomingMessage *incomingMessage = (TSIncomingMessage *)self.viewItem.interaction;
    
    [self.contentView addSubview:self.avatarView];
    self.avatarView.size = self.avatarSize;
    self.avatarView.hexEncodedPublicKey = incomingMessage.authorId;
    [self.avatarView update];
    
    // Loki: Show the moderator icon if needed
    if (self.viewItem.isGroupThread && !self.viewItem.isRSSFeed) {
        __block LKPublicChat *publicChat;
        [LKStorage readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            publicChat = [LKDatabaseUtilities getPublicChatForThreadID:self.viewItem.interaction.uniqueThreadId transaction: transaction];
        }];
        if (publicChat != nil) {
            BOOL isModerator = [LKPublicChatAPI isUserModerator:incomingMessage.authorId forChannel:publicChat.channel onServer:publicChat.server];
            UIImage *moderatorIcon = [UIImage imageNamed:@"Crown"];
            self.moderatorIconImageView.image = moderatorIcon;
            self.moderatorIconImageView.hidden = !isModerator;
        }
    }
    
    [self.contentView addSubview:self.moderatorIconImageView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(otherUsersProfileDidChange:)
                                                 name:kNSNotificationName_OtherUsersProfileDidChange
                                               object:nil];

    return YES;
}

- (CGFloat)avatarSize
{
    return LKValues.smallProfilePictureSize;
}

- (void)otherUsersProfileDidChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    if (!self.viewItem.shouldShowSenderAvatar) {
        return;
    }
    if (!self.viewItem.isGroupThread) {
        OWSFailDebug(@"not a group thread.");
        return;
    }
    if (self.viewItem.interaction.interactionType != OWSInteractionType_IncomingMessage) {
        OWSFailDebug(@"not an incoming message.");
        return;
    }

    NSString *recipientId = notification.userInfo[kNSNotificationKey_ProfileRecipientId];
    if (recipientId.length == 0) {
        return;
    }
    TSIncomingMessage *incomingMessage = (TSIncomingMessage *)self.viewItem.interaction;

    if (![incomingMessage.authorId isEqualToString:recipientId]) {
        return;
    }

    [self updateAvatarView];
}

#pragma mark - Measurement

- (CGSize)cellSize
{
    OWSAssertDebug(self.conversationStyle);
    OWSAssertDebug(self.conversationStyle.viewWidth > 0);
    OWSAssertDebug(self.viewItem);
    OWSAssertDebug([self.viewItem.interaction isKindOfClass:[TSMessage class]]);
    OWSAssertDebug(self.messageBubbleView);

    self.messageBubbleView.viewItem = self.viewItem;
    self.messageBubbleView.cellMediaCache = self.delegate.cellMediaCache;
    CGSize messageBubbleSize = [self.messageBubbleView measureSize];

    CGSize cellSize = messageBubbleSize;

    OWSAssertDebug(cellSize.width > 0 && cellSize.height > 0);

    if (self.viewItem.hasCellHeader) {
        cellSize.height +=
            [self.headerView measureWithConversationViewItem:self.viewItem conversationStyle:self.conversationStyle]
                .height;
    }

    if (self.shouldHaveSendFailureBadge) {
        cellSize.width += self.sendFailureBadgeSize + self.sendFailureBadgeSpacing;
    }

    // Loki: Include the friend request view if needed
    if ([self shouldShowFriendRequestUIForMessage:self.message]) {
        cellSize.height += [LKFriendRequestView calculateHeightWithMessage:self.message conversationStyle:self.conversationStyle];
    }
    
    cellSize = CGSizeCeil(cellSize);

    return cellSize;
}

#pragma mark - Reuse

- (void)prepareForReuse
{
    [super prepareForReuse];

    [NSLayoutConstraint deactivateConstraints:self.viewConstraints];
    self.viewConstraints = [NSMutableArray new];

    [self.messageBubbleView prepareForReuse];
    [self.messageBubbleView unloadContent];

    [self.headerView removeFromSuperview];

    [self.friendRequestView removeFromSuperview];
    self.friendRequestView = nil;
    
    [self.avatarView removeFromSuperview];

    self.moderatorIconImageView.image = nil;
    [self.moderatorIconImageView removeFromSuperview];
    
    [self.sendFailureBadgeView removeFromSuperview];
    self.sendFailureBadgeView = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)setIsCellVisible:(BOOL)isCellVisible {
    BOOL didChange = self.isCellVisible != isCellVisible;

    [super setIsCellVisible:isCellVisible];

    if (!didChange) {
        return;
    }

    [self ensureMediaLoadState];
}

#pragma mark - Gesture recognizers

- (void)handleTapGesture:(UITapGestureRecognizer *)sender
{
    OWSAssertDebug(self.delegate);

    if (sender.state != UIGestureRecognizerStateRecognized) {
        OWSLogVerbose(@"Ignoring tap on message: %@", self.viewItem.interaction.debugDescription);
        return;
    }

    if ([self isGestureInCellHeader:sender]) {
        return;
    }

    if (self.viewItem.interaction.interactionType == OWSInteractionType_OutgoingMessage) {
        TSOutgoingMessage *outgoingMessage = (TSOutgoingMessage *)self.viewItem.interaction;
        if (outgoingMessage.messageState == TSOutgoingMessageStateFailed) {
            [self.delegate didTapFailedOutgoingMessage:outgoingMessage];
            return;
        } else if (outgoingMessage.messageState == TSOutgoingMessageStateSending) {
            // Ignore taps on outgoing messages being sent.
            return;
        }
    }

    [self.messageBubbleView handleTapGesture:sender];
}

- (void)handleLongPressGesture:(UILongPressGestureRecognizer *)sender
{
    OWSAssertDebug(self.delegate);

    if ([self shouldShowFriendRequestUIForMessage:self.message]) {
        return;
    }
    
    if (sender.state != UIGestureRecognizerStateBegan) {
        return;
    }

    if ([self isGestureInCellHeader:sender]) {
        return;
    }

    BOOL shouldAllowReply = YES;
    if (self.viewItem.interaction.interactionType == OWSInteractionType_OutgoingMessage) {
        TSOutgoingMessage *outgoingMessage = (TSOutgoingMessage *)self.viewItem.interaction;
        if (outgoingMessage.messageState == TSOutgoingMessageStateFailed) {
            // Don't allow "delete" or "reply" on "failed" outgoing messages.
            shouldAllowReply = NO;
        } else if (outgoingMessage.messageState == TSOutgoingMessageStateSending) {
            // Don't allow "delete" or "reply" on "sending" outgoing messages.
            shouldAllowReply = NO;
        }
    }

    CGPoint locationInMessageBubble = [sender locationInView:self.messageBubbleView];
    switch ([self.messageBubbleView gestureLocationForLocation:locationInMessageBubble]) {
        case OWSMessageGestureLocation_Default:
        case OWSMessageGestureLocation_OversizeText:
        case OWSMessageGestureLocation_LinkPreview: {
            [self.delegate conversationCell:self
                           shouldAllowReply:shouldAllowReply
                   didLongpressTextViewItem:self.viewItem];
            break;
        }
        case OWSMessageGestureLocation_Media: {
            [self.delegate conversationCell:self
                           shouldAllowReply:shouldAllowReply
                  didLongpressMediaViewItem:self.viewItem];
            break;
        }
        case OWSMessageGestureLocation_QuotedReply: {
            [self.delegate conversationCell:self
                           shouldAllowReply:shouldAllowReply
                  didLongpressQuoteViewItem:self.viewItem];
            break;
        }
    }
}

- (BOOL)isGestureInCellHeader:(UIGestureRecognizer *)sender
{
    OWSAssertDebug(self.viewItem);

    if (!self.viewItem.hasCellHeader) {
        return NO;
    }

    CGPoint location = [sender locationInView:self];
    CGPoint headerBottom = [self convertPoint:CGPointMake(0, self.headerView.height) fromView:self.headerView];
    return location.y <= headerBottom.y;
}

#pragma mark - Convenience

- (BOOL)shouldShowFriendRequestUIForMessage:(TSMessage *)message
{
    if ([message isKindOfClass:TSOutgoingMessage.class]) {
        return message.isFriendRequest;
    } else {
        if (message.isFriendRequest) {
            // Only show the first friend request that was received
            NSString *senderID = ((TSIncomingMessage *)message).authorId;
            __block NSMutableSet<TSContactThread *> *linkedDeviceThreads;
            [LKStorage writeWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                linkedDeviceThreads = [LKDatabaseUtilities getLinkedDeviceThreadsFor:senderID in:transaction].mutableCopy;
            }];
            NSMutableArray<TSIncomingMessage *> *allFriendRequestMessages = @[].mutableCopy;
            for (TSContactThread *thread in linkedDeviceThreads) {
                [thread enumerateInteractionsUsingBlock:^(TSInteraction *interaction) {
                    TSIncomingMessage *message = [interaction as:TSIncomingMessage.class];
                    if (message != nil && message.isFriendRequest) {
                        [allFriendRequestMessages addObject:message];
                    }
                }];
            }
            [allFriendRequestMessages sortUsingComparator:^NSComparisonResult(TSIncomingMessage *lhs, TSIncomingMessage *rhs) {
                return [@(lhs.timestamp) compare:@(rhs.timestamp)] == NSOrderedDescending;
            }];
            return [message.uniqueId isEqual:allFriendRequestMessages.firstObject.uniqueId];
        } else {
            return NO;
        }
    }
}

@end

NS_ASSUME_NONNULL_END
