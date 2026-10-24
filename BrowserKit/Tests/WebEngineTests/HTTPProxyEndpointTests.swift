// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import WebEngine

final class HTTPProxyEndpointTests: XCTestCase {
    func testValidEndpoint() {
        let endpoint = HTTPProxyEndpoint(host: "127.0.0.1", port: 8080)

        XCTAssertTrue(endpoint.isValid)
        XCTAssertEqual(endpoint.displayName, "127.0.0.1:8080")
    }

    func testHostIsTrimmed() {
        let endpoint = HTTPProxyEndpoint(host: "  proxy.local \n", port: 3128)

        XCTAssertEqual(endpoint.host, "proxy.local")
        XCTAssertTrue(endpoint.isValid)
    }

    func testEmptyHostIsInvalid() {
        XCTAssertFalse(HTTPProxyEndpoint(host: "", port: 8080).isValid)
        XCTAssertFalse(HTTPProxyEndpoint(host: "   ", port: 8080).isValid)
    }

    func testHostWithWhitespaceIsInvalid() {
        XCTAssertFalse(HTTPProxyEndpoint(host: "proxy local", port: 8080).isValid)
    }

    func testPortOutsideValidRangeIsInvalid() {
        XCTAssertFalse(HTTPProxyEndpoint(host: "127.0.0.1", port: 0).isValid)
        XCTAssertFalse(HTTPProxyEndpoint(host: "127.0.0.1", port: -1).isValid)
        XCTAssertFalse(HTTPProxyEndpoint(host: "127.0.0.1", port: 65536).isValid)
        XCTAssertTrue(HTTPProxyEndpoint(host: "127.0.0.1", port: 65535).isValid)
    }
}
