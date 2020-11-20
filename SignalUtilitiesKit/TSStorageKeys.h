//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifndef TextSecureKit_TSStorageKeys_h
#define TextSecureKit_TSStorageKeys_h

/**
 *  Preferences exposed to the user
 */

#pragma mark User Preferences

#define TSStorageUserPreferencesCollection @"TSStorageUserPreferencesCollection"


/**
 *  Internal settings of the application, not exposed to the user.
 */

#pragma mark Internal Settings

#define TSStorageInternalSettingsCollection @"TSStorageInternalSettingsCollection"
#define TSStorageInternalSettingsVersion @"TSLastLaunchedVersion"

#endif

NS_ASSUME_NONNULL_END
