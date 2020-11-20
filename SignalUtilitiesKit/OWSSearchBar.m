//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSSearchBar.h"
#import "Theme.h"
#import "UIView+OWS.h"
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>
#import <SessionUIKit/SessionUIKit.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSSearchBar

- (instancetype)init
{
    if (self = [super init]) {
        [self ows_configure];
    }

    return self;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        [self ows_configure];
    }

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        [self ows_configure];
    }

    return self;
}

- (void)ows_configure
{
    [self ows_applyTheme];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeDidChange:)
                                                 name:ThemeDidChangeNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)ows_applyTheme
{
    [self.class applyThemeToSearchBar:self];
}

+ (void)applyThemeToSearchBar:(UISearchBar *)searchBar
{
    OWSAssertIsOnMainThread();

    UIColor *foregroundColor = UIColor.lokiLightestGray;
    searchBar.barTintColor = Theme.backgroundColor;
    searchBar.barStyle = Theme.barStyle;
    searchBar.tintColor = UIColor.lokiGreen;
    
    // Hide searchBar border.
    // Alternatively we could hide the border by using `UISearchBarStyleMinimal`, but that causes an issue when toggling
    // from light -> dark -> light theme wherein the textField background color appears darker than it should
    // (regardless of our re-setting textfield.backgroundColor below).
    searchBar.backgroundImage = [UIImage new];

    if (Theme.isDarkThemeEnabled) {
        UIImage *clearImage = [UIImage imageNamed:@"searchbar_clear"];
        [searchBar setImage:[clearImage asTintedImageWithColor:foregroundColor]
            forSearchBarIcon:UISearchBarIconClear
                       state:UIControlStateNormal];

        UIImage *searchImage = [UIImage imageNamed:@"searchbar_search"];
        [searchBar setImage:[searchImage asTintedImageWithColor:foregroundColor]
            forSearchBarIcon:UISearchBarIconSearch
                       state:UIControlStateNormal];
    } else {
        [searchBar setImage:nil forSearchBarIcon:UISearchBarIconClear state:UIControlStateNormal];

        [searchBar setImage:nil forSearchBarIcon:UISearchBarIconSearch state:UIControlStateNormal];
    }

    [searchBar traverseViewHierarchyWithVisitor:^(UIView *view) {
        if ([view isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)view;
            textField.backgroundColor = Theme.searchFieldBackgroundColor;
            textField.textColor = Theme.primaryColor;
            NSString *placeholder = textField.placeholder;
            if (placeholder != nil) {
                NSMutableAttributedString *attributedPlaceholder = [[NSMutableAttributedString alloc] initWithString:placeholder];
                [attributedPlaceholder addAttribute:NSForegroundColorAttributeName value:foregroundColor range:NSMakeRange(0, placeholder.length)];
                textField.attributedPlaceholder = attributedPlaceholder;
            }
            textField.keyboardAppearance = LKAppModeUtilities.isLightMode ? UIKeyboardAppearanceDefault : UIKeyboardAppearanceDark;
        }
    }];
}

- (void)themeDidChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    [self ows_applyTheme];
}

@end

NS_ASSUME_NONNULL_END
