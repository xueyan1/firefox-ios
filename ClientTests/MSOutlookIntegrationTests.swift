/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import XCTest
@testable import Client

class MSOutlookIntegrationTests: XCTestCase {
    func testBasicSendTo() {
        let metadata = "mailto:person@email.com".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person@email.com")
    }

    func testSendHNameTo() {
        let metadata = "mailto:?to=person@email.com".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person@email.com")
    }

    func testSendWithToAndHNameTo() {
        let metadata = "mailto:person1@email.com?to=person2@email.com".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person1@email.com%2C%20person2@email.com")
    }

    func testWithCapitalizedHNameProperties() {
        let metadata = "mailto:person1@email.com?To=person2@email.com&Subject=hello".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person1@email.com%2C%20person2@email.com&subject=hello")
    }

    func testFiltersOutNonSupportedParam() {
        let metadata = "mailto:person@email.com?In-Reply-To=random".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person@email.com")
    }

    func testBCCandCC() {
        let metadata = "mailto:person@email.com?cc=someoneelse@email.com&bcc=thecompany@email.com".asURL!.mailToMetadata()!
        let outlookLink = MSOutlookIntegration.newEmailURLFromMetadata(metadata)
        XCTAssertEqual(outlookLink.absoluteString, "ms-outlook://emails/new?to=person@email.com&cc=someoneelse@email.com&bcc=thecompany@email.com")
    }
}