// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import WebEngine

final class DoHResolverTests: XCTestCase {
    func testEndpointNormalization() {
        XCTAssertEqual(DoHResolver.endpoint(from: "1.1.1.1")?.absoluteString,
                       "https://1.1.1.1/dns-query")
        XCTAssertEqual(DoHResolver.endpoint(from: "dns.example.com")?.absoluteString,
                       "https://dns.example.com/dns-query")
        XCTAssertEqual(DoHResolver.endpoint(from: "https://dns.example.com/custom")?.absoluteString,
                       "https://dns.example.com/custom")
        XCTAssertEqual(DoHResolver.endpoint(from: "  https://1.1.1.1/  ")?.absoluteString,
                       "https://1.1.1.1/dns-query")
        XCTAssertNil(DoHResolver.endpoint(from: ""))
        XCTAssertNil(DoHResolver.endpoint(from: "http://1.1.1.1/dns-query"))
        XCTAssertNil(DoHResolver.endpoint(from: "https://"))
    }

    func testMakeQueryEncodesQuestion() {
        let data = DoHResolver.makeQuery(host: "a.io", type: 1)

        XCTAssertNotNil(data)
        guard let data else { return }
        XCTAssertEqual(data.count, 12 + 10)
        XCTAssertEqual(Array(data[2...5]), [0x01, 0x00, 0x00, 0x01])
        XCTAssertEqual(Array(data.suffix(10)), [1, 0x61, 2, 0x69, 0x6f, 0, 0, 1, 0, 1])
    }

    func testParsesARecord() {
        let response: [UInt8] = [
            0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x04,
            93, 184, 216, 34
        ]

        let answers = DoHResolver.parseAnswers(data: Data(response), type: 1)

        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(Array(answers[0]), [93, 184, 216, 34])
    }

    func testParsesAAAARecord() {
        let response: [UInt8] = [
            0xab, 0xcd, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
            0x00, 0x1c, 0x00, 0x01,
            0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x10,
            0x2a, 0x00, 0x11, 0x58, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
        ]

        let answers = DoHResolver.parseAnswers(data: Data(response), type: 28)

        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(Array(answers[0].prefix(4)), [0x2a, 0x00, 0x11, 0x58])
        XCTAssertEqual(Array(answers[0].suffix(1)), [0x01])
    }

    func testIgnoresOtherRecordTypes() {
        let response: [UInt8] = [
            0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xc0, 0x0c, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x02,
            0xc0, 0x10
        ]

        XCTAssertTrue(DoHResolver.parseAnswers(data: Data(response), type: 1).isEmpty)
    }
}
