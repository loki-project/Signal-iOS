//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSConversationSettingsViewController.h"
#import "BlockListUIUtils.h"
#import "ContactsViewHelper.h"
#import "FingerprintViewController.h"
#import "OWSAddToContactViewController.h"
#import "OWSBlockingManager.h"
#import "OWSSoundSettingsViewController.h"
#import "PhoneNumber.h"
#import "ShowGroupMembersViewController.h"
#import "Session-Swift.h"
#import "UIFont+OWS.h"
#import "UIView+OWS.h"
#import "UpdateGroupViewController.h"
#import <Curve25519Kit/Curve25519.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalUtilitiesKit/Environment.h>
#import <SignalUtilitiesKit/OWSAvatarBuilder.h>
#import <SignalUtilitiesKit/OWSContactsManager.h>
#import <SignalUtilitiesKit/OWSProfileManager.h>
#import <SignalUtilitiesKit/OWSSounds.h>
#import <SignalUtilitiesKit/OWSUserProfile.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>
#import <SignalUtilitiesKit/UIUtil.h>
#import <SignalUtilitiesKit/OWSDisappearingConfigurationUpdateInfoMessage.h>
#import <SignalUtilitiesKit/OWSDisappearingMessagesConfiguration.h>
#import <SignalUtilitiesKit/OWSMessageSender.h>
#import <SignalUtilitiesKit/OWSPrimaryStorage.h>
#import <SignalUtilitiesKit/TSGroupThread.h>
#import <SignalUtilitiesKit/TSOutgoingMessage.h>
#import <SignalUtilitiesKit/TSThread.h>

@import ContactsUI;
@import PromiseKit;

NS_ASSUME_NONNULL_BEGIN

//#define SHOW_COLOR_PICKER

const CGFloat kIconViewLength = 24;

@interface OWSConversationSettingsViewController () <ContactEditingDelegate,
    ContactsViewHelperDelegate,
#ifdef SHOW_COLOR_PICKER
    ColorPickerDelegate,
#endif
    OWSSheetViewControllerDelegate>

@property (nonatomic) TSThread *thread;
@property (nonatomic) YapDatabaseConnection *uiDatabaseConnection;
@property (nonatomic, readonly) YapDatabaseConnection *editingDatabaseConnection;

@property (nonatomic) NSArray<NSNumber *> *disappearingMessagesDurations;
@property (nonatomic) OWSDisappearingMessagesConfiguration *disappearingMessagesConfiguration;
@property (nullable, nonatomic) MediaGallery *mediaGallery;
@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;
@property (nonatomic, readonly) UIImageView *avatarView;
@property (nonatomic, readonly) UILabel *disappearingMessagesDurationLabel;
#ifdef SHOW_COLOR_PICKER
@property (nonatomic) OWSColorPicker *colorPicker;
#endif

@end

#pragma mark -

@implementation OWSConversationSettingsViewController

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (void)commonInit
{
    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];

    [self observeNotifications];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Dependencies

- (SSKMessageSenderJobQueue *)messageSenderJobQueue
{
    return SSKEnvironment.shared.messageSenderJobQueue;
}

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

- (OWSContactsManager *)contactsManager
{
    return Environment.shared.contactsManager;
}

- (OWSMessageSender *)messageSender
{
    return SSKEnvironment.shared.messageSender;
}

- (OWSBlockingManager *)blockingManager
{
    return [OWSBlockingManager sharedManager];
}

- (OWSProfileManager *)profileManager
{
    return [OWSProfileManager sharedManager];
}

#pragma mark

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityStateDidChange:)
                                                 name:kNSNotificationName_IdentityStateDidChange
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(otherUsersProfileDidChange:)
                                                 name:kNSNotificationName_OtherUsersProfileDidChange
                                               object:nil];
}

- (YapDatabaseConnection *)editingDatabaseConnection
{
    return [OWSPrimaryStorage sharedManager].dbReadWriteConnection;
}

- (nullable NSString *)threadName
{
    NSString *threadName = self.thread.name;
    if (self.thread.contactIdentifier) {
        return [self.contactsManager profileNameForRecipientId:self.thread.contactIdentifier];
    } else if (threadName.length == 0 && [self isGroupThread]) {
        threadName = [MessageStrings newGroupDefaultTitle];
    }
    return threadName;
}

- (BOOL)isGroupThread
{
    return [self.thread isKindOfClass:[TSGroupThread class]];
}

- (BOOL)isOpenGroupChat
{
    if ([self isGroupThread]) {
        TSGroupThread *thread = (TSGroupThread *)self.thread;
        return thread.isPublicChat;
    }
    return false;
}

-(BOOL)isPrivateGroupChat
{
    if (self.isGroupThread) {
        TSGroupThread *thread = (TSGroupThread *)self.thread;
        return !thread.isRSSFeed && !thread.isPublicChat;
    }
    return false;
}

- (void)configureWithThread:(TSThread *)thread uiDatabaseConnection:(YapDatabaseConnection *)uiDatabaseConnection
{
    OWSAssertDebug(thread);
    self.thread = thread;
    self.uiDatabaseConnection = uiDatabaseConnection;

    [self updateEditButton];
}

- (void)updateEditButton
{
    OWSAssertDebug(self.thread);

    if ([self.thread isKindOfClass:[TSContactThread class]] && self.contactsManager.supportsContactEditing
        && self.hasExistingContact) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"EDIT_TXT", nil)
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(didTapEditButton)
                           accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"edit")];
    }
}

- (BOOL)hasExistingContact
{
    OWSAssertDebug([self.thread isKindOfClass:[TSContactThread class]]);
    TSContactThread *contactThread = (TSContactThread *)self.thread;
    NSString *recipientId = contactThread.contactIdentifier;
    return [self.contactsManager hasSignalAccountForRecipientId:recipientId];
}

#pragma mark - ContactEditingDelegate

- (void)didFinishEditingContact
{
    [self updateTableContents];

    OWSLogDebug(@"");
    [self dismissViewControllerAnimated:NO completion:nil];
}

#pragma mark - CNContactViewControllerDelegate

- (void)contactViewController:(CNContactViewController *)viewController
       didCompleteWithContact:(nullable CNContact *)contact
{
    [self updateTableContents];

    if (contact) {
        // Saving normally returns you to the "Show Contact" view
        // which we're not interested in, so we skip it here. There is
        // an unfortunate blip of the "Show Contact" view on slower devices.
        OWSLogDebug(@"completed editing contact.");
        [self dismissViewControllerAnimated:NO completion:nil];
    } else {
        OWSLogDebug(@"canceled editing contact.");
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    // Loki: Original code
    // ========
    // [self updateTableContents];
    // ========
}

#pragma mark - View Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.tableView.estimatedRowHeight = 45;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    _disappearingMessagesDurationLabel = [UILabel new];
    SET_SUBVIEW_ACCESSIBILITY_IDENTIFIER(self, _disappearingMessagesDurationLabel);

    self.disappearingMessagesDurations = [OWSDisappearingMessagesConfiguration validDurationsSeconds];

    self.disappearingMessagesConfiguration =
        [OWSDisappearingMessagesConfiguration fetchObjectWithUniqueID:self.thread.uniqueId];

    if (!self.disappearingMessagesConfiguration) {
        self.disappearingMessagesConfiguration =
            [[OWSDisappearingMessagesConfiguration alloc] initDefaultWithThreadId:self.thread.uniqueId];
    }

#ifdef SHOW_COLOR_PICKER
    self.colorPicker = [[OWSColorPicker alloc] initWithThread:self.thread];
    self.colorPicker.delegate = self;
#endif

    [self updateTableContents];
    
    NSString *title;
    if ([self.thread isKindOfClass:[TSContactThread class]]) {
        title = NSLocalizedString(@"Settings", @"");
    } else {
        title = NSLocalizedString(@"Group Settings", @"");
    }
    [LKViewControllerUtilities setUpDefaultSessionStyleForVC:self withTitle:title customBackButton:YES];
    self.tableView.backgroundColor = UIColor.clearColor;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (self.showVerificationOnAppear) {
        self.showVerificationOnAppear = NO;
        if (self.isGroupThread) {
            [self showGroupMembersView];
        } else {
            [self showVerificationView];
        }
    }
}

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];
    contents.title = NSLocalizedString(@"CONVERSATION_SETTINGS", @"title for conversation settings screen");

    BOOL isNoteToSelf = self.thread.isNoteToSelf;

    __weak OWSConversationSettingsViewController *weakSelf = self;

    // Main section.

    OWSTableSection *mainSection = [OWSTableSection new];

    mainSection.customHeaderView = [self mainSectionHeader];

    if (self.isGroupThread) {
        mainSection.customHeaderHeight = @(147.f);
    } else {
        BOOL isSmallScreen = (UIScreen.mainScreen.bounds.size.height - 568) < 1;
        mainSection.customHeaderHeight = isSmallScreen ? @(201.f) : @(208.f);
    }

    /**
     * Loki: Original code
     * ========
    if ([self.thread isKindOfClass:[TSContactThread class]] && self.contactsManager.supportsContactEditing
        && !self.hasExistingContact) {
        [mainSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            return [weakSelf
                                 disclosureCellWithName:
                                     NSLocalizedString(@"CONVERSATION_SETTINGS_NEW_CONTACT",
                                         @"Label for 'new contact' button in conversation settings view.")
                                               iconName:@"table_ic_new_contact"
                                accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                            OWSConversationSettingsViewController, @"new_contact")];
                        }
                        actionBlock:^{
                            [weakSelf presentContactViewController];
                        }]];
        [mainSection addItem:[OWSTableItem
                                 itemWithCustomCellBlock:^{
                                     return [weakSelf
                                          disclosureCellWithName:
                                              NSLocalizedString(@"CONVERSATION_SETTINGS_ADD_TO_EXISTING_CONTACT",
                                                  @"Label for 'new contact' button in conversation settings view.")
                                                        iconName:@"table_ic_add_to_existing_contact"
                                         accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                     OWSConversationSettingsViewController,
                                                                     @"add_to_existing_contact")];
                                 }
                                 actionBlock:^{
                                     OWSConversationSettingsViewController *strongSelf = weakSelf;
                                     OWSCAssertDebug(strongSelf);
                                     TSContactThread *contactThread = (TSContactThread *)strongSelf.thread;
                                     NSString *recipientId = contactThread.contactIdentifier;
                                     [strongSelf presentAddToContactViewControllerWithRecipientId:recipientId];
                                 }]];
    }
     
     if (SSKFeatureFlags.conversationSearch) {
     * ========
     */

    if ([self.thread isKindOfClass:TSContactThread.class]) {
        [mainSection addItem:[OWSTableItem
                                 itemWithCustomCellBlock:^{
                                     return [weakSelf
                                          disclosureCellWithName:@"Copy Session ID"
                                                        iconName:@"ic_copy"
                                         accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                     OWSConversationSettingsViewController, @"copy_session_id")];
                                 }
                                 actionBlock:^{
                                     [weakSelf copySessionID];
                                 }]];
    }

    [mainSection addItem:[OWSTableItem
                             itemWithCustomCellBlock:^{
                                 return [weakSelf
                                      disclosureCellWithName:MediaStrings.allMedia
                                                    iconName:@"actionsheet_camera_roll_black"
                                     accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                 OWSConversationSettingsViewController, @"all_media")];
                             }
                             actionBlock:^{
                                 [weakSelf showMediaGallery];
                             }]];

    [mainSection addItem:[OWSTableItem
                             itemWithCustomCellBlock:^{
                                 NSString *title = NSLocalizedString(@"CONVERSATION_SETTINGS_SEARCH",
                                     @"Table cell label in conversation settings which returns the user to the "
                                     @"conversation with 'search mode' activated");
                                 return [weakSelf
                                      disclosureCellWithName:title
                                                    iconName:@"conversation_settings_search"
                                     accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                 OWSConversationSettingsViewController, @"search")];
                             }
                             actionBlock:^{
                                 [weakSelf tappedConversationSearch];
                             }]];
    /*
    }

    if (!isNoteToSelf && !self.isGroupThread && self.thread.hasSafetyNumbers) {
        [mainSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            return [weakSelf
                                 disclosureCellWithName:NSLocalizedString(@"VERIFY_PRIVACY",
                                                            @"Label for button or row which allows users to verify the "
                                                            @"safety number of another user.")
                                               iconName:@"table_ic_not_verified"
                                accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                            OWSConversationSettingsViewController, @"safety_numbers")];
                        }
                        actionBlock:^{
                            [weakSelf showVerificationView];
                        }]];
    }

    if (isNoteToSelf) {
        // Skip the profile whitelist.
    } else if ([self.profileManager isThreadInProfileWhitelist:self.thread]) {
        [mainSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            OWSConversationSettingsViewController *strongSelf = weakSelf;
                            OWSCAssertDebug(strongSelf);

                            return [strongSelf
                                      labelCellWithName:
                                          (strongSelf.isGroupThread
                                                  ? NSLocalizedString(
                                                        @"CONVERSATION_SETTINGS_VIEW_PROFILE_IS_SHARED_WITH_GROUP",
                                                        @"Indicates that user's profile has been shared with a group.")
                                                  : NSLocalizedString(
                                                        @"CONVERSATION_SETTINGS_VIEW_PROFILE_IS_SHARED_WITH_USER",
                                                        @"Indicates that user's profile has been shared with a user."))
                                               iconName:@"table_ic_share_profile"
                                accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                            OWSConversationSettingsViewController,
                                                            @"profile_is_shared")];
                        }
                                    actionBlock:nil]];
    } else {
        [mainSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            OWSConversationSettingsViewController *strongSelf = weakSelf;
                            OWSCAssertDebug(strongSelf);

                            UITableViewCell *cell = [strongSelf
                                 disclosureCellWithName:
                                     (strongSelf.isGroupThread
                                             ? NSLocalizedString(@"CONVERSATION_SETTINGS_VIEW_SHARE_PROFILE_WITH_GROUP",
                                                   @"Action that shares user profile with a group.")
                                             : NSLocalizedString(@"CONVERSATION_SETTINGS_VIEW_SHARE_PROFILE_WITH_USER",
                                                   @"Action that shares user profile with a user."))
                                               iconName:@"table_ic_share_profile"
                                accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                            OWSConversationSettingsViewController, @"share_profile")];
                            cell.userInteractionEnabled = !strongSelf.hasLeftGroup;

                            return cell;
                        }
                        actionBlock:^{
                            [weakSelf showShareProfileAlert];
                        }]];
    }
     * =======
     */

    if (![self isOpenGroupChat]) {
        [mainSection addItem:[OWSTableItem
                                 itemWithCustomCellBlock:^{
                                     UITableViewCell *cell = [OWSTableItem newCell];
                                     OWSConversationSettingsViewController *strongSelf = weakSelf;
                                     OWSCAssertDebug(strongSelf);
                                     cell.preservesSuperviewLayoutMargins = YES;
                                     cell.contentView.preservesSuperviewLayoutMargins = YES;
                                     cell.selectionStyle = UITableViewCellSelectionStyleNone;

                                     NSString *iconName
                                         = (strongSelf.disappearingMessagesConfiguration.isEnabled ? @"ic_timer"
                                                                                                   : @"ic_timer_disabled");
                                     UIImageView *iconView = [strongSelf viewForIconWithName:iconName];

                                     UILabel *rowLabel = [UILabel new];
                                     rowLabel.text = NSLocalizedString(
                                         @"DISAPPEARING_MESSAGES", @"table cell label in conversation settings");
                                     rowLabel.textColor = LKColors.text;
                                     rowLabel.font = [UIFont systemFontOfSize:LKValues.mediumFontSize];
                                     rowLabel.lineBreakMode = NSLineBreakByTruncatingTail;

                                     UISwitch *switchView = [UISwitch new];
                                     switchView.on = strongSelf.disappearingMessagesConfiguration.isEnabled;
                                     [switchView addTarget:strongSelf
                                                    action:@selector(disappearingMessagesSwitchValueDidChange:)
                                          forControlEvents:UIControlEventValueChanged];

                                     UIStackView *topRow =
                                         [[UIStackView alloc] initWithArrangedSubviews:@[ iconView, rowLabel, switchView ]];
                                     topRow.spacing = strongSelf.iconSpacing;
                                     topRow.alignment = UIStackViewAlignmentCenter;
                                     [cell.contentView addSubview:topRow];
                                     [topRow autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeBottom];

                                     UILabel *subtitleLabel = [UILabel new];
                                     NSString *displayName;
                                     if (self.thread.isGroupThread) {
                                         displayName = @"the group";
                                     } else {
                                         displayName = [LKUserDisplayNameUtilities getPrivateChatDisplayNameFor:self.thread.contactIdentifier];
                                     }
                                     subtitleLabel.text = [NSString stringWithFormat:NSLocalizedString(@"When enabled, messages between you and %@ will disappear after they have been seen.", ""), displayName];
                                     subtitleLabel.textColor = LKColors.text;
                                     subtitleLabel.font = [UIFont systemFontOfSize:LKValues.smallFontSize];
                                     subtitleLabel.numberOfLines = 0;
                                     subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
                                     [cell.contentView addSubview:subtitleLabel];
                                     [subtitleLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:topRow withOffset:8];
                                     [subtitleLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeLeading ofView:rowLabel];
                                     [subtitleLabel autoPinTrailingToSuperviewMargin];
                                     [subtitleLabel autoPinBottomToSuperviewMargin];

                                     cell.userInteractionEnabled = !strongSelf.hasLeftGroup;

                                     cell.accessibilityIdentifier = ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                         OWSConversationSettingsViewController, @"disappearing_messages");

                                     return cell;
                                 }
                                         customRowHeight:UITableViewAutomaticDimension
                                             actionBlock:nil]];

        if (self.disappearingMessagesConfiguration.isEnabled) {
            [mainSection
                addItem:[OWSTableItem
                            itemWithCustomCellBlock:^{
                                UITableViewCell *cell = [OWSTableItem newCell];
                                OWSConversationSettingsViewController *strongSelf = weakSelf;
                                OWSCAssertDebug(strongSelf);
                                cell.preservesSuperviewLayoutMargins = YES;
                                cell.contentView.preservesSuperviewLayoutMargins = YES;
                                cell.selectionStyle = UITableViewCellSelectionStyleNone;

                                UIImageView *iconView = [strongSelf viewForIconWithName:@"ic_timer"];

                                UILabel *rowLabel = strongSelf.disappearingMessagesDurationLabel;
                                [strongSelf updateDisappearingMessagesDurationLabel];
                                rowLabel.textColor = LKColors.text;
                                rowLabel.font = [UIFont systemFontOfSize:LKValues.mediumFontSize];
                                // don't truncate useful duration info which is in the tail
                                rowLabel.lineBreakMode = NSLineBreakByTruncatingHead;

                                UIStackView *topRow =
                                    [[UIStackView alloc] initWithArrangedSubviews:@[ iconView, rowLabel ]];
                                topRow.spacing = strongSelf.iconSpacing;
                                topRow.alignment = UIStackViewAlignmentCenter;
                                [cell.contentView addSubview:topRow];
                                [topRow autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeBottom];

                                UISlider *slider = [UISlider new];
                                slider.maximumValue = (float)(strongSelf.disappearingMessagesDurations.count - 1);
                                slider.minimumValue = 0;
                                slider.tintColor = LKColors.accent;
                                slider.continuous = NO;
                                slider.value = strongSelf.disappearingMessagesConfiguration.durationIndex;
                                [slider addTarget:strongSelf
                                              action:@selector(durationSliderDidChange:)
                                    forControlEvents:UIControlEventValueChanged];
                                [cell.contentView addSubview:slider];
                                [slider autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:topRow withOffset:6];
                                [slider autoPinEdge:ALEdgeLeading toEdge:ALEdgeLeading ofView:rowLabel];
                                [slider autoPinTrailingToSuperviewMargin];
                                [slider autoPinBottomToSuperviewMargin];

                                cell.userInteractionEnabled = !strongSelf.hasLeftGroup;

                                cell.accessibilityIdentifier = ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                    OWSConversationSettingsViewController, @"disappearing_messages_duration");

                                return cell;
                            }
                                    customRowHeight:UITableViewAutomaticDimension
                                        actionBlock:nil]];
        }
    }
#ifdef SHOW_COLOR_PICKER
    [mainSection
        addItem:[OWSTableItem
                    itemWithCustomCellBlock:^{
                        OWSConversationSettingsViewController *strongSelf = weakSelf;
                        OWSCAssertDebug(strongSelf);

                        ConversationColorName colorName = strongSelf.thread.conversationColorName;
                        UIColor *currentColor =
                            [OWSConversationColor conversationColorOrDefaultForColorName:colorName].themeColor;
                        NSString *title = NSLocalizedString(@"CONVERSATION_SETTINGS_CONVERSATION_COLOR",
                            @"Label for table cell which leads to picking a new conversation color");
                        return [strongSelf
                                       cellWithName:title
                                           iconName:@"ic_color_palette"
                                disclosureIconColor:currentColor
                            accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                        OWSConversationSettingsViewController, @"conversation_color")];
                    }
                    actionBlock:^{
                        [weakSelf showColorPicker];
                    }]];
#endif

    [contents addSection:mainSection];

    // Group settings section.

    __block BOOL isUserMember = NO;
    if (self.isGroupThread) {
        NSString *userPublicKey = OWSIdentityManager.sharedManager.identityKeyPair.hexEncodedPublicKey;
        [LKStorage readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            isUserMember = [(TSGroupThread *)self.thread isUserMemberInGroup:userPublicKey transaction:transaction];
        }];
    }

    if (self.isGroupThread && self.isPrivateGroupChat && isUserMember) {
        if (((TSGroupThread *)self.thread).usesSharedSenderKeys) {
            [mainSection addItem:[OWSTableItem
                itemWithCustomCellBlock:^{
                    UITableViewCell *cell =
                        [weakSelf disclosureCellWithName:NSLocalizedString(@"EDIT_GROUP_ACTION",
                                                             @"table cell label in conversation settings")
                                                iconName:@"table_ic_group_edit"
                                 accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                             OWSConversationSettingsViewController, @"edit_group")];
                    cell.userInteractionEnabled = !weakSelf.hasLeftGroup;
                    return cell;
                }
                actionBlock:^{
                    [weakSelf editGroup];
                }]
            ];
        }
//        [mainSection addItem:[OWSTableItem
//            itemWithCustomCellBlock:^{
//                UITableViewCell *cell =
//                    [weakSelf disclosureCellWithName:NSLocalizedString(@"LIST_GROUP_MEMBERS_ACTION",
//                                                         @"table cell label in conversation settings")
//                                            iconName:@"table_ic_group_members"
//                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
//                                                         OWSConversationSettingsViewController, @"group_members")];
//                return cell;
//            }
//            actionBlock:^{
//                [weakSelf showGroupMembersView];
//            }]
//        ];
        [mainSection addItem:[OWSTableItem
            itemWithCustomCellBlock:^{
                UITableViewCell *cell =
                    [weakSelf disclosureCellWithName:NSLocalizedString(@"LEAVE_GROUP_ACTION",
                                                         @"table cell label in conversation settings")
                                            iconName:@"table_ic_group_leave"
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                         OWSConversationSettingsViewController, @"leave_group")];
                cell.userInteractionEnabled = !weakSelf.hasLeftGroup;

                return cell;
            }
            actionBlock:^{
                [weakSelf didTapLeaveGroup];
            }]
        ];
    }
    

    // Mute thread section.

    if (!isNoteToSelf) {
//        OWSTableSection *notificationsSection = [OWSTableSection new];
        // We need a section header to separate the notifications UI from the group settings UI.
//        notificationsSection.headerTitle = NSLocalizedString(
//            @"SETTINGS_SECTION_NOTIFICATIONS", @"Label for the notifications section of conversation settings view.");

        [mainSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            UITableViewCell *cell =
                                [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                            [OWSTableItem configureCell:cell];
                            OWSConversationSettingsViewController *strongSelf = weakSelf;
                            OWSCAssertDebug(strongSelf);
                            cell.preservesSuperviewLayoutMargins = YES;
                            cell.contentView.preservesSuperviewLayoutMargins = YES;

                            UIImageView *iconView = [strongSelf viewForIconWithName:@"table_ic_notification_sound"];

                            UILabel *rowLabel = [UILabel new];
                            rowLabel.text = NSLocalizedString(@"SETTINGS_ITEM_NOTIFICATION_SOUND",
                                @"Label for settings view that allows user to change the notification sound.");
                            rowLabel.textColor = LKColors.text;
                            rowLabel.font = [UIFont systemFontOfSize:LKValues.mediumFontSize];
                            rowLabel.lineBreakMode = NSLineBreakByTruncatingTail;

                            UIStackView *contentRow =
                                [[UIStackView alloc] initWithArrangedSubviews:@[ iconView, rowLabel ]];
                            contentRow.spacing = strongSelf.iconSpacing;
                            contentRow.alignment = UIStackViewAlignmentCenter;
                            [cell.contentView addSubview:contentRow];
                            [contentRow autoPinEdgesToSuperviewMargins];

                            OWSSound sound = [OWSSounds notificationSoundForThread:strongSelf.thread];
                            cell.detailTextLabel.text = [OWSSounds displayNameForSound:sound];

                            cell.accessibilityIdentifier = ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                OWSConversationSettingsViewController, @"notifications");

                            return cell;
                        }
                        customRowHeight:UITableViewAutomaticDimension
                        actionBlock:^{
                            OWSSoundSettingsViewController *vc = [OWSSoundSettingsViewController new];
                            vc.thread = weakSelf.thread;
                            [weakSelf.navigationController pushViewController:vc animated:YES];
                        }]];
        [mainSection
            addItem:
                [OWSTableItem
                    itemWithCustomCellBlock:^{
                        UITableViewCell *cell =
                            [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                        [OWSTableItem configureCell:cell];
                        OWSConversationSettingsViewController *strongSelf = weakSelf;
                        OWSCAssertDebug(strongSelf);
                        cell.preservesSuperviewLayoutMargins = YES;
                        cell.contentView.preservesSuperviewLayoutMargins = YES;

                        UIImageView *iconView = [strongSelf viewForIconWithName:@"Mute"];

                        UILabel *rowLabel = [UILabel new];
                        rowLabel.text = NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_LABEL",
                            @"label for 'mute thread' cell in conversation settings");
                        rowLabel.textColor = LKColors.text;
                        rowLabel.font = [UIFont systemFontOfSize:LKValues.mediumFontSize];
                        rowLabel.lineBreakMode = NSLineBreakByTruncatingTail;

                        NSString *muteStatus = NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_NOT_MUTED",
                            @"Indicates that the current thread is not muted.");
                        NSDate *mutedUntilDate = strongSelf.thread.mutedUntilDate;
                        NSDate *now = [NSDate date];
                        if (mutedUntilDate != nil && [mutedUntilDate timeIntervalSinceDate:now] > 0) {
                            NSCalendar *calendar = [NSCalendar currentCalendar];
                            NSCalendarUnit calendarUnits = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay;
                            NSDateComponents *muteUntilComponents =
                                [calendar components:calendarUnits fromDate:mutedUntilDate];
                            NSDateComponents *nowComponents = [calendar components:calendarUnits fromDate:now];
                            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                            if (nowComponents.year != muteUntilComponents.year
                                || nowComponents.month != muteUntilComponents.month
                                || nowComponents.day != muteUntilComponents.day) {

                                [dateFormatter setDateStyle:NSDateFormatterShortStyle];
                                [dateFormatter setTimeStyle:NSDateFormatterShortStyle];
                            } else {
                                [dateFormatter setDateStyle:NSDateFormatterNoStyle];
                                [dateFormatter setTimeStyle:NSDateFormatterShortStyle];
                            }

                            muteStatus = [NSString
                                stringWithFormat:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTED_UNTIL_FORMAT",
                                                     @"Indicates that this thread is muted until a given date or time. "
                                                     @"Embeds {{The date or time which the thread is muted until}}."),
                                [dateFormatter stringFromDate:mutedUntilDate]];
                        }

                        UIStackView *contentRow =
                            [[UIStackView alloc] initWithArrangedSubviews:@[ iconView, rowLabel ]];
                        contentRow.spacing = strongSelf.iconSpacing;
                        contentRow.alignment = UIStackViewAlignmentCenter;
                        [cell.contentView addSubview:contentRow];
                        [contentRow autoPinEdgesToSuperviewMargins];

                        cell.detailTextLabel.text = muteStatus;

                        cell.accessibilityIdentifier
                            = ACCESSIBILITY_IDENTIFIER_WITH_NAME(OWSConversationSettingsViewController, @"mute");

                        return cell;
                    }
                    customRowHeight:UITableViewAutomaticDimension
                    actionBlock:^{
                        [weakSelf showMuteUnmuteActionSheet];
                    }]];
//        mainSection.footerTitle = NSLocalizedString(
//            @"MUTE_BEHAVIOR_EXPLANATION", @"An explanation of the consequences of muting a thread.");
//            [contents addSection:notificationsSection];
    }
    // Block Conversation section.

    if (!isNoteToSelf && [self.thread isKindOfClass:TSContactThread.class]) {
        [mainSection addItem:[OWSTableItem
                                 itemWithCustomCellBlock:^{
                                     return [weakSelf
                                          disclosureCellWithName:@"Reset Secure Session"
                                                        iconName:@"system_message_security"
                                         accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                     OWSConversationSettingsViewController, @"reset_secure_ession")];
                                 }
                                 actionBlock:^{
                                     [weakSelf resetSecureSession];
                                 }]];

        mainSection.footerTitle = NSLocalizedString(
            @"BLOCK_USER_BEHAVIOR_EXPLANATION", @"An explanation of the consequences of blocking another user.");

        [mainSection addItem:[OWSTableItem
                             itemWithCustomCellBlock:^{
                                 OWSConversationSettingsViewController *strongSelf = weakSelf;
                                 if (!strongSelf) {
                                     return [UITableViewCell new];
                                 }

                                 NSString *cellTitle = NSLocalizedString(@"CONVERSATION_SETTINGS_BLOCK_THIS_USER",
                                                                         @"table cell label in conversation settings");
                                 UITableViewCell *cell = [strongSelf
                                      disclosureCellWithName:cellTitle
                                                    iconName:@"table_ic_block"
                                     accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(
                                                                 OWSConversationSettingsViewController, @"block")];

                                 cell.selectionStyle = UITableViewCellSelectionStyleNone;

                                 UISwitch *blockConversationSwitch = [UISwitch new];
                                 blockConversationSwitch.on =
                                     [strongSelf.blockingManager isThreadBlocked:strongSelf.thread];
                                 [blockConversationSwitch addTarget:strongSelf
                                                             action:@selector(blockConversationSwitchDidChange:)
                                                   forControlEvents:UIControlEventValueChanged];
                                 cell.accessoryView = blockConversationSwitch;

                                 return cell;
                             }
                                         actionBlock:nil]];
    }

    self.contents = contents;
}

- (CGFloat)iconSpacing
{
    return 12.f;
}

- (UITableViewCell *)cellWithName:(NSString *)name
                         iconName:(NSString *)iconName
              disclosureIconColor:(UIColor *)disclosureIconColor
{
    UITableViewCell *cell = [self cellWithName:name iconName:iconName];
    OWSColorPickerAccessoryView *accessoryView =
        [[OWSColorPickerAccessoryView alloc] initWithColor:disclosureIconColor];
    [accessoryView sizeToFit];
    cell.accessoryView = accessoryView;

    return cell;
}

- (UITableViewCell *)cellWithName:(NSString *)name iconName:(NSString *)iconName
{
    OWSAssertDebug(iconName.length > 0);
    UIImageView *iconView = [self viewForIconWithName:iconName];
    return [self cellWithName:name iconView:iconView];
}

- (UITableViewCell *)cellWithName:(NSString *)name iconView:(UIView *)iconView
{
    OWSAssertDebug(name.length > 0);

    UITableViewCell *cell = [OWSTableItem newCell];
    cell.preservesSuperviewLayoutMargins = YES;
    cell.contentView.preservesSuperviewLayoutMargins = YES;

    UILabel *rowLabel = [UILabel new];
    rowLabel.text = name;
    rowLabel.textColor = LKColors.text;
    rowLabel.font = [UIFont systemFontOfSize:LKValues.mediumFontSize];
    rowLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    UIStackView *contentRow = [[UIStackView alloc] initWithArrangedSubviews:@[ iconView, rowLabel ]];
    contentRow.spacing = self.iconSpacing;

    [cell.contentView addSubview:contentRow];
    [contentRow autoPinEdgesToSuperviewMargins];

    return cell;
}

- (UITableViewCell *)disclosureCellWithName:(NSString *)name
                                   iconName:(NSString *)iconName
                    accessibilityIdentifier:(NSString *)accessibilityIdentifier
{
    UITableViewCell *cell = [self cellWithName:name iconName:iconName];
    cell.accessibilityIdentifier = accessibilityIdentifier;
    return cell;
}

- (UITableViewCell *)labelCellWithName:(NSString *)name
                              iconName:(NSString *)iconName
               accessibilityIdentifier:(NSString *)accessibilityIdentifier
{
    UITableViewCell *cell = [self cellWithName:name iconName:iconName];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = accessibilityIdentifier;
    return cell;
}

static CGRect oldframe;

-(void)showProfilePicture:(UITapGestureRecognizer *)tapGesture
{
    LKProfilePictureView *profilePictureView = (LKProfilePictureView *)tapGesture.view;
    UIImage *image = [profilePictureView getProfilePicture];
    if (image == nil) { return; }
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    UIView *backgroundView = [[UIView alloc]initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height)];
    oldframe = [profilePictureView convertRect:profilePictureView.bounds toView:window];
    backgroundView.backgroundColor = [UIColor blackColor];
    backgroundView.alpha = 0;
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:oldframe];
    imageView.image = image;
    imageView.tag = 1;
    imageView.layer.cornerRadius = [UIScreen mainScreen].bounds.size.width / 2;
    imageView.layer.masksToBounds = true;
    [backgroundView addSubview:imageView];
    [window addSubview:backgroundView];
        
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(hideImage:)];
    [backgroundView addGestureRecognizer: tap];
        
    [UIView animateWithDuration:0.25 animations:^{
        imageView.frame = CGRectMake(0,([UIScreen mainScreen].bounds.size.height - oldframe.size.height * [UIScreen mainScreen].bounds.size.width / oldframe.size.width) / 2, [UIScreen mainScreen].bounds.size.width, oldframe.size.height * [UIScreen mainScreen].bounds.size.width / oldframe.size.width);
        backgroundView.alpha = 1;
    } completion:nil];
}

-(void)hideImage:(UITapGestureRecognizer *)tap{
    UIView *backgroundView = tap.view;
    UIImageView *imageView = (UIImageView *)[tap.view viewWithTag:1];
    [UIView animateWithDuration:0.25 animations:^{
        imageView.frame = oldframe;
        backgroundView.alpha = 0;
    } completion:^(BOOL finished) {
        [backgroundView removeFromSuperview];
    }];
}


- (UIView *)mainSectionHeader
{
    UITapGestureRecognizer *profilePictureTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showProfilePicture:)];
    LKProfilePictureView *profilePictureView = [LKProfilePictureView new];
    CGFloat size = LKValues.largeProfilePictureSize;
    profilePictureView.size = size;
    [profilePictureView autoSetDimension:ALDimensionWidth toSize:size];
    [profilePictureView autoSetDimension:ALDimensionHeight toSize:size];
    [profilePictureView addGestureRecognizer:profilePictureTapGestureRecognizer];
    
    UILabel *titleView = [UILabel new];
    titleView.textColor = LKColors.text;
    titleView.font = [UIFont boldSystemFontOfSize:LKValues.largeFontSize];
    titleView.lineBreakMode = NSLineBreakByTruncatingTail;
    titleView.text = (self.threadName != nil && self.threadName.length > 0) ? self.threadName : @"Anonymous";
    
    UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[ profilePictureView, titleView ]];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = LKValues.mediumSpacing;
    stackView.distribution = UIStackViewDistributionEqualCentering; 
    stackView.alignment = UIStackViewAlignmentCenter;
    BOOL isSmallScreen = (UIScreen.mainScreen.bounds.size.height - 568) < 1;
    CGFloat horizontalSpacing = isSmallScreen ? LKValues.largeSpacing : LKValues.veryLargeSpacing;
    stackView.layoutMargins = UIEdgeInsetsMake(LKValues.mediumSpacing, horizontalSpacing, LKValues.mediumSpacing, horizontalSpacing);
    [stackView setLayoutMarginsRelativeArrangement:YES];

    if (!self.isGroupThread) {
        SRCopyableLabel *subtitleView = [SRCopyableLabel new];
        subtitleView.textColor = LKColors.text;
        subtitleView.font = [LKFonts spaceMonoOfSize:LKValues.smallFontSize];
        subtitleView.lineBreakMode = NSLineBreakByCharWrapping;
        subtitleView.numberOfLines = 2;
        subtitleView.text = self.thread.contactIdentifier;
        subtitleView.textAlignment = NSTextAlignmentCenter;
        [stackView addArrangedSubview:subtitleView];
    }
    
    [profilePictureView updateForThread:self.thread];
    
    return stackView;
}

- (void)conversationNameTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (self.isGroupThread) {
            CGPoint location = [sender locationInView:self.avatarView];
            if (CGRectContainsPoint(self.avatarView.bounds, location)) {
                [self showUpdateGroupView:UpdateGroupMode_EditGroupAvatar];
            } else {
                [self showUpdateGroupView:UpdateGroupMode_EditGroupName];
            }
        } else {
            if (self.contactsManager.supportsContactEditing) {
                [self presentContactViewController];
            }
        }
    }
}

- (UIImageView *)viewForIconWithName:(NSString *)iconName
{
    UIImage *icon = [UIImage imageNamed:iconName];

    OWSAssertDebug(icon);
    UIImageView *iconView = [UIImageView new];
    iconView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iconView.tintColor = LKColors.text;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.minificationFilter = kCAFilterTrilinear;
    iconView.layer.magnificationFilter = kCAFilterTrilinear;

    [iconView autoSetDimensionsToSize:CGSizeMake(kIconViewLength, kIconViewLength)];

    return iconView;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    NSIndexPath *_Nullable selectedPath = [self.tableView indexPathForSelectedRow];
    if (selectedPath) {
        // HACK to unselect rows when swiping back
        // http://stackoverflow.com/questions/19379510/uitableviewcell-doesnt-get-deselected-when-swiping-back-quickly
        [self.tableView deselectRowAtIndexPath:selectedPath animated:animated];
    }

    [self updateTableContents];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    if (self.disappearingMessagesConfiguration.isNewRecord && !self.disappearingMessagesConfiguration.isEnabled) {
        // don't save defaults, else we'll unintentionally save the configuration and notify the contact.
        return;
    }

    if (self.disappearingMessagesConfiguration.dictionaryValueDidChange) {
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            [self.disappearingMessagesConfiguration saveWithTransaction:transaction];
            // MJK TODO - should be safe to remove this senderTimestamp
            OWSDisappearingConfigurationUpdateInfoMessage *infoMessage =
                [[OWSDisappearingConfigurationUpdateInfoMessage alloc]
                         initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                    thread:self.thread
                             configuration:self.disappearingMessagesConfiguration
                       createdByRemoteName:nil
                    createdInExistingGroup:NO];
            [infoMessage saveWithTransaction:transaction];

            OWSDisappearingMessagesConfigurationMessage *message = [[OWSDisappearingMessagesConfigurationMessage alloc]
                initWithConfiguration:self.disappearingMessagesConfiguration
                               thread:self.thread];

            [self.messageSenderJobQueue addMessage:message transaction:transaction];
        }];
    }
}

#pragma mark - Actions

- (void)showShareProfileAlert
{
    [self.profileManager presentAddThreadToProfileWhitelist:self.thread
                                         fromViewController:self
                                                    success:^{
                                                        [self updateTableContents];
                                                    }];
}

- (void)showVerificationView
{
    NSString *recipientId = self.thread.contactIdentifier;
    OWSAssertDebug(recipientId.length > 0);

    [FingerprintViewController presentFromViewController:self recipientId:recipientId];
}

- (void)showGroupMembersView
{
    TSGroupThread *thread = (TSGroupThread *)self.thread;
    LKGroupMembersVC *groupMembersVC = [[LKGroupMembersVC alloc] initWithThread:thread];
    [self.navigationController pushViewController:groupMembersVC animated:YES];
}

- (void)showUpdateGroupView:(UpdateGroupMode)mode
{
    OWSAssertDebug(self.conversationSettingsViewDelegate);

    UpdateGroupViewController *updateGroupViewController = [UpdateGroupViewController new];
    updateGroupViewController.conversationSettingsViewDelegate = self.conversationSettingsViewDelegate;
    updateGroupViewController.thread = (TSGroupThread *)self.thread;
    updateGroupViewController.mode = mode;
    [self.navigationController pushViewController:updateGroupViewController animated:YES];
}

- (void)presentContactViewController
{
    if (!self.contactsManager.supportsContactEditing) {
        OWSFailDebug(@"Contact editing not supported");
        return;
    }
    if (![self.thread isKindOfClass:[TSContactThread class]]) {
        OWSFailDebug(@"unexpected thread: %@", [self.thread class]);
        return;
    }

    TSContactThread *contactThread = (TSContactThread *)self.thread;
    [self.contactsViewHelper presentContactViewControllerForRecipientId:contactThread.contactIdentifier
                                                     fromViewController:self
                                                        editImmediately:YES];
}

- (void)presentAddToContactViewControllerWithRecipientId:(NSString *)recipientId
{
    if (!self.contactsManager.supportsContactEditing) {
        // Should not expose UI that lets the user get here.
        OWSFailDebug(@"Contact editing not supported.");
        return;
    }

    if (!self.contactsManager.isSystemContactsAuthorized) {
        [self.contactsViewHelper presentMissingContactAccessAlertControllerFromViewController:self];
        return;
    }

    OWSAddToContactViewController *viewController = [OWSAddToContactViewController new];
    [viewController configureWithRecipientId:recipientId];
    [self.navigationController pushViewController:viewController animated:YES];
}

- (void)didTapEditButton
{
    [self presentContactViewController];
}

- (void)editGroup
{
    LKEditClosedGroupVC *editClosedGroupVC = [[LKEditClosedGroupVC alloc] initWithThreadID:self.thread.uniqueId];
    [self.navigationController pushViewController:editClosedGroupVC animated:YES completion:nil];
}

- (void)didTapLeaveGroup
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedString(@"CONFIRM_LEAVE_GROUP_TITLE", @"Alert title")
                                            message:NSLocalizedString(@"CONFIRM_LEAVE_GROUP_DESCRIPTION", @"Alert body")
                                     preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *leaveAction = [UIAlertAction
                actionWithTitle:NSLocalizedString(@"LEAVE_BUTTON_TITLE", @"Confirmation button within contextual alert")
        accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"leave_group_confirm")
                          style:UIAlertActionStyleDestructive
                        handler:^(UIAlertAction *_Nonnull action) {
                            [self leaveGroup];
                        }];
    [alert addAction:leaveAction];
    [alert addAction:[OWSAlerts cancelAction]];

    [self presentAlert:alert];
}

- (BOOL)hasLeftGroup
{
    if (self.isGroupThread) {
        TSGroupThread *groupThread = (TSGroupThread *)self.thread;
        return !groupThread.isLocalUserInGroup;
    }

    return NO;
}

- (void)leaveGroup
{
    TSGroupThread *gThread = (TSGroupThread *)self.thread;

    if (gThread.usesSharedSenderKeys) {
        NSString *groupPublicKey = [LKGroupUtilities getDecodedGroupID:gThread.groupModel.groupId];
        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            [[LKClosedGroupsProtocol leaveGroupWithPublicKey:groupPublicKey transaction:transaction] retainUntilComplete];
        }];
    } else {
        TSOutgoingMessage *message =
            [TSOutgoingMessage outgoingMessageInThread:gThread groupMetaMessage:TSGroupMetaMessageQuit expiresInSeconds:0];

        [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            [self.messageSenderJobQueue addMessage:message transaction:transaction];
            [gThread leaveGroupWithTransaction:transaction];
        }];
    }

    [self.navigationController popViewControllerAnimated:YES];
}

- (void)disappearingMessagesSwitchValueDidChange:(UISwitch *)sender
{
    UISwitch *disappearingMessagesSwitch = (UISwitch *)sender;

    [self toggleDisappearingMessages:disappearingMessagesSwitch.isOn];

    [self updateTableContents];
}

- (void)blockConversationSwitchDidChange:(id)sender
{
    if (![sender isKindOfClass:[UISwitch class]]) {
        OWSFailDebug(@"Unexpected sender for block user switch: %@", sender);
    }
    UISwitch *blockConversationSwitch = (UISwitch *)sender;

    BOOL isCurrentlyBlocked = [self.blockingManager isThreadBlocked:self.thread];

    __weak OWSConversationSettingsViewController *weakSelf = self;
    if (blockConversationSwitch.isOn) {
        OWSAssertDebug(!isCurrentlyBlocked);
        if (isCurrentlyBlocked) {
            return;
        }
        [BlockListUIUtils showBlockThreadActionSheet:self.thread
                                  fromViewController:self
                                     blockingManager:self.blockingManager
                                     contactsManager:self.contactsManager
                                       messageSender:self.messageSender
                                     completionBlock:^(BOOL isBlocked) {
                                         // Update switch state if user cancels action.
                                         blockConversationSwitch.on = isBlocked;

                                         [weakSelf updateTableContents];
                                     }];

    } else {
        OWSAssertDebug(isCurrentlyBlocked);
        if (!isCurrentlyBlocked) {
            return;
        }
        [BlockListUIUtils showUnblockThreadActionSheet:self.thread
                                    fromViewController:self
                                       blockingManager:self.blockingManager
                                       contactsManager:self.contactsManager
                                       completionBlock:^(BOOL isBlocked) {
                                           // Update switch state if user cancels action.
                                           blockConversationSwitch.on = isBlocked;

                                           [weakSelf updateTableContents];
                                       }];
    }
}

- (void)toggleDisappearingMessages:(BOOL)flag
{
    self.disappearingMessagesConfiguration.enabled = flag;

    [self updateTableContents];
}

- (void)durationSliderDidChange:(UISlider *)slider
{
    // snap the slider to a valid value
    NSUInteger index = (NSUInteger)(slider.value + 0.5);
    [slider setValue:index animated:YES];
    NSNumber *numberOfSeconds = self.disappearingMessagesDurations[index];
    self.disappearingMessagesConfiguration.durationSeconds = [numberOfSeconds unsignedIntValue];

    [self updateDisappearingMessagesDurationLabel];
}

- (void)updateDisappearingMessagesDurationLabel
{
    if (self.disappearingMessagesConfiguration.isEnabled) {
        NSString *keepForFormat = @"Disappear after %@";
        self.disappearingMessagesDurationLabel.text =
            [NSString stringWithFormat:keepForFormat, self.disappearingMessagesConfiguration.durationString];
    } else {
        self.disappearingMessagesDurationLabel.text
            = NSLocalizedString(@"KEEP_MESSAGES_FOREVER", @"Slider label when disappearing messages is off");
    }

    [self.disappearingMessagesDurationLabel setNeedsLayout];
    [self.disappearingMessagesDurationLabel.superview setNeedsLayout];
}

- (void)showMuteUnmuteActionSheet
{
    // The "unmute" action sheet has no title or message; the
    // action label speaks for itself.
    NSString *title = nil;
    NSString *message = nil;
    if (!self.thread.isMuted) {
        title = NSLocalizedString(
            @"CONVERSATION_SETTINGS_MUTE_ACTION_SHEET_TITLE", @"Title of the 'mute this thread' action sheet.");
        message = NSLocalizedString(
            @"MUTE_BEHAVIOR_EXPLANATION", @"An explanation of the consequences of muting a thread.");
    }

    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:title
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak OWSConversationSettingsViewController *weakSelf = self;
    if (self.thread.isMuted) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_UNMUTE_ACTION",
                                                                   @"Label for button to unmute a thread.")
                                       accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"unmute")
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction *_Nonnull ignore) {
                                                           [weakSelf setThreadMutedUntilDate:nil];
                                                       }];
        [actionSheet addAction:action];
    } else {
#ifdef DEBUG
        [actionSheet
            addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_ONE_MINUTE_ACTION",
                                                         @"Label for button to mute a thread for a minute.")
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"mute_1_minute")
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *_Nonnull ignore) {
                                                 NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                                                 NSCalendar *calendar = [NSCalendar currentCalendar];
                                                 [calendar setTimeZone:timeZone];
                                                 NSDateComponents *dateComponents = [NSDateComponents new];
                                                 [dateComponents setMinute:1];
                                                 NSDate *mutedUntilDate =
                                                     [calendar dateByAddingComponents:dateComponents
                                                                               toDate:[NSDate date]
                                                                              options:0];
                                                 [weakSelf setThreadMutedUntilDate:mutedUntilDate];
                                             }]];
#endif
        [actionSheet
            addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_ONE_HOUR_ACTION",
                                                         @"Label for button to mute a thread for a hour.")
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"mute_1_hour")
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *_Nonnull ignore) {
                                                 NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                                                 NSCalendar *calendar = [NSCalendar currentCalendar];
                                                 [calendar setTimeZone:timeZone];
                                                 NSDateComponents *dateComponents = [NSDateComponents new];
                                                 [dateComponents setHour:1];
                                                 NSDate *mutedUntilDate =
                                                     [calendar dateByAddingComponents:dateComponents
                                                                               toDate:[NSDate date]
                                                                              options:0];
                                                 [weakSelf setThreadMutedUntilDate:mutedUntilDate];
                                             }]];
        [actionSheet
            addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_ONE_DAY_ACTION",
                                                         @"Label for button to mute a thread for a day.")
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"mute_1_day")
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *_Nonnull ignore) {
                                                 NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                                                 NSCalendar *calendar = [NSCalendar currentCalendar];
                                                 [calendar setTimeZone:timeZone];
                                                 NSDateComponents *dateComponents = [NSDateComponents new];
                                                 [dateComponents setDay:1];
                                                 NSDate *mutedUntilDate =
                                                     [calendar dateByAddingComponents:dateComponents
                                                                               toDate:[NSDate date]
                                                                              options:0];
                                                 [weakSelf setThreadMutedUntilDate:mutedUntilDate];
                                             }]];
        [actionSheet
            addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_ONE_WEEK_ACTION",
                                                         @"Label for button to mute a thread for a week.")
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"mute_1_week")
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *_Nonnull ignore) {
                                                 NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                                                 NSCalendar *calendar = [NSCalendar currentCalendar];
                                                 [calendar setTimeZone:timeZone];
                                                 NSDateComponents *dateComponents = [NSDateComponents new];
                                                 [dateComponents setDay:7];
                                                 NSDate *mutedUntilDate =
                                                     [calendar dateByAddingComponents:dateComponents
                                                                               toDate:[NSDate date]
                                                                              options:0];
                                                 [weakSelf setThreadMutedUntilDate:mutedUntilDate];
                                             }]];
        [actionSheet
            addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"CONVERSATION_SETTINGS_MUTE_ONE_YEAR_ACTION",
                                                         @"Label for button to mute a thread for a year.")
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"mute_1_year")
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *_Nonnull ignore) {
                                                 NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
                                                 NSCalendar *calendar = [NSCalendar currentCalendar];
                                                 [calendar setTimeZone:timeZone];
                                                 NSDateComponents *dateComponents = [NSDateComponents new];
                                                 [dateComponents setYear:1];
                                                 NSDate *mutedUntilDate =
                                                     [calendar dateByAddingComponents:dateComponents
                                                                               toDate:[NSDate date]
                                                                              options:0];
                                                 [weakSelf setThreadMutedUntilDate:mutedUntilDate];
                                             }]];
    }

    [actionSheet addAction:[OWSAlerts cancelAction]];

    [self presentAlert:actionSheet];
}

- (void)setThreadMutedUntilDate:(nullable NSDate *)value
{
    [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        [self.thread updateWithMutedUntilDate:value transaction:transaction];
    }];
    
    [self updateTableContents];
}

- (void)copySessionID
{
    UIPasteboard.generalPasteboard.string = self.thread.contactIdentifier;
}

- (void)showMediaGallery
{
    OWSLogDebug(@"");

    MediaGallery *mediaGallery = [[MediaGallery alloc] initWithThread:self.thread
                                                              options:MediaGalleryOptionSliderEnabled];

    self.mediaGallery = mediaGallery;

    OWSAssertDebug([self.navigationController isKindOfClass:[OWSNavigationController class]]);
    [mediaGallery pushTileViewFromNavController:(OWSNavigationController *)self.navigationController];
}

- (void)tappedConversationSearch
{
    [self.conversationSettingsViewDelegate conversationSettingsDidRequestConversationSearch:self];
}

- (void)resetSecureSession
{
    if (![self.thread isKindOfClass:TSContactThread.class]) { return; }
    TSContactThread *thread = (TSContactThread *)self.thread;
    __weak OWSConversationSettingsViewController *weakSelf = self;
    NSString *message = @"This may help if you're having encryption problems in this conversation. Your messages will be kept.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Secure Session?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"TXT_CANCEL_TITLE", @"") style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                [thread addSessionRestoreDevice:thread.contactIdentifier transaction:transaction];
                [LKSessionManagementProtocol startSessionResetInThread:thread transaction:transaction];
            }];
            [weakSelf.navigationController popViewControllerAnimated:YES];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Notifications

- (void)identityStateDidChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    [self updateTableContents];
}

- (void)otherUsersProfileDidChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    NSString *recipientId = notification.userInfo[kNSNotificationKey_ProfileRecipientId];
    OWSAssertDebug(recipientId.length > 0);

    if (recipientId.length > 0 && [self.thread isKindOfClass:[TSContactThread class]] &&
        [self.thread.contactIdentifier isEqualToString:recipientId]) {
        [self updateTableContents];
    }
}

#pragma mark - ColorPickerDelegate

#ifdef SHOW_COLOR_PICKER

- (void)showColorPicker
{
    OWSSheetViewController *sheetViewController = self.colorPicker.sheetViewController;
    sheetViewController.delegate = self;

    [self presentViewController:sheetViewController
                       animated:YES
                     completion:^() {
                         OWSLogInfo(@"presented sheet view");
                     }];
}

- (void)colorPicker:(OWSColorPicker *)colorPicker
    didPickConversationColor:(OWSConversationColor *_Nonnull)conversationColor
{
    OWSLogDebug(@"picked color: %@", conversationColor.name);
    [LKStorage writeSyncWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        [self.thread updateConversationColorName:conversationColor.name transaction:transaction];
    }];

    [self.contactsManager.avatarCache removeAllImages];
    [self updateTableContents];
    [self.conversationSettingsViewDelegate conversationColorWasUpdated];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ConversationConfigurationSyncOperation *operation =
            [[ConversationConfigurationSyncOperation alloc] initWithThread:self.thread];
        OWSAssertDebug(operation.isReady);
        [operation start];
    });
}

#endif

#pragma mark - OWSSheetViewController

- (void)sheetViewControllerRequestedDismiss:(OWSSheetViewController *)sheetViewController
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

NS_ASSUME_NONNULL_END
