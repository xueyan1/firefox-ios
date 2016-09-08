/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import XCTest
@testable import Shared

import Foundation

class NSURLExtensionsMailToTests: XCTestCase {
    func testBasicSendTo() {
        let link = "mailto:person@email.com".asURL!
        let metadata = link.mailToMetadata()!
        XCTAssertEqual(metadata.to, "person@email.com")
        XCTAssertTrue(metadata.headers.isEmpty)
    }

    func testSendWithSubject() {
        let link = "mailto:person@email.com?subject=hello".asURL!
        let metadata = link.mailToMetadata()!
        XCTAssertEqual(metadata.to, "person@email.com")
        XCTAssertEqual(metadata.headers["subject"], "hello")
    }

    func testSendWithSubjectAndBody() {
        let link = "mailto:person@email.com?subject=hello&body=this%20is%20a%20test".asURL!
        let metadata = link.mailToMetadata()!
        XCTAssertEqual(metadata.to, "person@email.com")
        XCTAssertEqual(metadata.headers["subject"], "hello")
        XCTAssertEqual(metadata.headers["body"], "this%20is%20a%20test")
    }

    func testToAsHeader() {
        let link = "mailto:?to=person@email.com".asURL!
        let metadata = link.mailToMetadata()!
        XCTAssertTrue(metadata.to.isEmpty)
        XCTAssertEqual(metadata.headers["to"], "person@email.com")
    }

    func testMultipleToInHeaderAndToField() {
        let link = "mailto:person1@email.com?to=person2@email.com".asURL!
        let metadata = link.mailToMetadata()!

        XCTAssertEqual(metadata.to, "person1@email.com")
        XCTAssertEqual(metadata.headers["to"], "person2@email.com")
    }

    func testEmptyLink() {
        let link = "mailto:".asURL!
        let metadata = link.mailToMetadata()!

        XCTAssertTrue(metadata.to.isEmpty)
        XCTAssertTrue(metadata.headers.isEmpty)
    }

    func testEmptyLinkWithQuestionMark() {
        let link = "mailto:?".asURL!
        let metadata = link.mailToMetadata()!

        XCTAssertTrue(metadata.to.isEmpty)
        XCTAssertTrue(metadata.headers.isEmpty)
    }
}
