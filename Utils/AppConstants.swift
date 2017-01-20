/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

public enum AppBuildChannel {
    case Release
    case Beta
    case Nightly
    case Developer
    case Aurora
}

public struct AppConstants {
    public static let IsRunningTest = NSClassFromString("XCTestCase") != nil || NSProcessInfo.processInfo().arguments.contains(LaunchArguments.Test)

    public static let SkipIntro = NSProcessInfo.processInfo().arguments.contains(LaunchArguments.SkipIntro)
    public static let ClearProfile = NSProcessInfo.processInfo().arguments.contains(LaunchArguments.ClearProfile)

    /// Build Channel.
    public static let BuildChannel: AppBuildChannel = {
        #if MOZ_CHANNEL_RELEASE
            return AppBuildChannel.Release
        #elseif MOZ_CHANNEL_BETA
            return AppBuildChannel.Beta
        #elseif MOZ_CHANNEL_NIGHTLY
            return AppBuildChannel.Nightly
        #elseif MOZ_CHANNEL_FENNEC
            return AppBuildChannel.Developer
        #elseif MOZ_CHANNEL_AURORA
            return AppBuildChannel.Aurora
        #endif
    }()

    /// Whether we just mirror (false) or actively merge and upload (true).
    public static var shouldMergeBookmarks = false

    /// Flag indiciating if we are running in Debug mode or not.
    public static let isDebug: Bool = {
        #if MOZ_CHANNEL_FENNEC
            return true
        #else
            return false
        #endif
    }()


    ///  Enables/disables the notification bar that appears on the status bar area
    public static let MOZ_STATUS_BAR_NOTIFICATION: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return true
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()

    
    /// Enables/disables the availability of No Image Mode.
    public static let MOZ_NO_IMAGE_MODE: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()

    /// Enables/disables the availability of Night Mode.
    public static let MOZ_NIGHT_MODE: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()
    
    ///  Enables/disables the top tabs for iPad
    public static let MOZ_TOP_TABS: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()

    /// Toggles the ability to reorder tabs in the tab tray
    public static let MOZ_REORDER_TAB_TRAY: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()

    /// Enables the injection of the experimental page-metadata-parser into the WKWebView for
    /// extracting metadata content from web pages
    public static let MOZ_CONTENT_METADATA_PARSING: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return false
        #elseif MOZ_CHANNEL_FENNEC
            return false
        #elseif MOZ_CHANNEL_AURORA
            return false
        #else
            return false
        #endif
    }()

    ///  Enables/disables the activity stream for iPhone
    public static let MOZ_AS_PANEL: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()

    /// Enables support for International Domain Names (IDN)
    /// Disabled because of https://bugzilla.mozilla.org/show_bug.cgi?id=1312294
    public static let MOZ_PUNYCODE: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()
    
    ///  Enables/disables deep linking form fill for FxA
    public static let MOZ_FXA_DEEP_LINK_FORM_FILL: Bool = {
        #if MOZ_CHANNEL_RELEASE
            return false
        #elseif MOZ_CHANNEL_BETA
            return false
        #elseif MOZ_CHANNEL_NIGHTLY
            return true
        #elseif MOZ_CHANNEL_FENNEC
            return true
        #elseif MOZ_CHANNEL_AURORA
            return true
        #else
            return true
        #endif
    }()
    
}
