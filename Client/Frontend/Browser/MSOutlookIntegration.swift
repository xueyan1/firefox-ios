/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

/**
 *  Integration with MS Outlook email client for iOS
 */
struct MSOutlookIntegration {
    static let supportedHeaders = [
        "to",
        "cc",
        "bcc",
        "subject",
        "body"
    ]

    static func newEmailURLFromMetadata(metadata: MailToMetadata) -> NSURL {
        // Format for MS Outlook
        var msOutlookMailURL = "ms-outlook://emails/new?"

        // The web is a crazy place and some people like to capitalize the hname values in their mailto: links.
        // Make sure we lowercase anything we found in the metadata since Outlook requires them to be lower case.
        var lowercasedHeaders = [String: String]()
        metadata.headers.forEach { (hname, hvalue) in
            lowercasedHeaders[hname.lowercaseString] = hvalue
        }

        // If we have both a [ to ] parameter and an hname 'to', combine them according to the RFC.
        var toParam: String
        if let toHValue = lowercasedHeaders["to"] {
            let value = metadata.to.isEmpty ? toHValue : [metadata.to, toHValue].joinWithSeparator("%2C%20")
            lowercasedHeaders.removeValueForKey("to")
            toParam = "to=\(value)"
        } else {
            toParam = "to=\(metadata.to)"
        }

        let queryParams = lowercasedHeaders.filter { (hname, _) in
            return supportedHeaders.contains(hname)
        } .map { "\($0)=\($1)" } .joinWithSeparator("&")


        msOutlookMailURL +=
            queryParams.isEmpty ? toParam : [toParam, queryParams].joinWithSeparator("&")

        return msOutlookMailURL.asURL!
    }
}
