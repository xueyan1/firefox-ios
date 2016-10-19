/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "CLLocationManager+PrivateHelper.h"

@interface CLLocationManager ()

+ (void)setAuthorizationStatus:(BOOL)value forBundleIdentifier:(NSString *)bundleID;

@end

@implementation CLLocationManager (PrivateHelper)

+ (void)_setAuthorizationStatus:(BOOL)value forBundleIdentifier:(NSString *)bundleId
{
    [CLLocationManager setAuthorizationStatus:value forBundleIdentifier:bundleId];
}

@end
