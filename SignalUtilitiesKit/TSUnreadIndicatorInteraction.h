//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/TSInteraction.h>

NS_ASSUME_NONNULL_BEGIN

// This class is vestigial.
__attribute__((deprecated)) @interface TSUnreadIndicatorInteraction : TSInteraction

- (instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
