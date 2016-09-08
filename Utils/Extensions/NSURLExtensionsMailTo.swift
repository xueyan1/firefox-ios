/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct MailToMetadata {
    public let to: String
    public let headers: [String: String]
}

public extension NSURL {

    /**
     Extracts the metadata associated with a mailto: URL according to RFC 2368
     https://tools.ietf.org/html/rfc2368
     */
    func mailToMetadata() -> MailToMetadata? {
        guard scheme == "mailto" else {
            return nil
        }

        // Extract 'to' value
        let toStart = absoluteString.startIndex.advancedBy("mailto:".characters.count)
        let questionMark = absoluteString.characters.indexOf("?") ?? absoluteString.endIndex

        let to = absoluteString.substringWithRange(toStart..<questionMark)

        // Extract headers
        let headersString = absoluteString.substringWithRange(questionMark.advancedBy(1)..<absoluteString.endIndex)
        var headers = [String: String]()
        let headerComponents = headersString.componentsSeparatedByString("&")

        headerComponents.forEach { headerPair in
            let components = headerPair.componentsSeparatedByString("=")
            guard components.count == 2 else {
                return
            }
            
            let (hname, hvalue) = (components[0], components[1])
            headers[hname] = hvalue
        }

        // Since putting the to value is valid in both the header section and the designated to section,
        // check to see where our to value is at and in case of a duplicate use the designated one.
        let dedupedTo = to == "" ? headers["to"] ?? "" : to
        return MailToMetadata(to: dedupedTo, headers: headers)
    }
}
