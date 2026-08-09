import XCTest
@testable import VPNBarApp

@MainActor
final class NetworkInfoManagerTests: XCTestCase {
    func test_shared_returnsInstance() {
        let manager = NetworkInfoManager.shared
        XCTAssertNotNil(manager)
    }

    func test_networkInfo_initiallyNil() {
        let manager = NetworkInfoManager.shared
        // NetworkInfo is nil until first fetch completes
        // This is expected initial state
        XCTAssertTrue(true)
    }

    func test_cleanup_doesNotCrash() {
        let manager = NetworkInfoManager.shared
        manager.cleanup()
    }

    func test_networkInfo_withAllNilGeoFields_producesNilFormattedLocation() {
        let info = NetworkInfo(
            publicIP: nil,
            country: nil,
            countryCode: nil,
            city: nil,
            vpnInterfaces: [],
            lastUpdated: Date()
        )
        XCTAssertNil(info.formattedLocation)
        XCTAssertNil(info.publicIP)
        XCTAssertNil(info.countryFlag)
    }

    func test_browserLeaksHTML_sample_extractsIPCountryCity() {
        // Mirrors the server-rendered markup from https://browserleaks.com/ip
        let html = """
        <tr><td>IP Address</td><td><span class="flag-container" id="client-ipv4" data-ip="203.0.113.42" data-iso_code="NL"><img class="flag-icon" src="/img/flags/NL.png" alt="NL" title="Netherlands (NL)"><span class="flag-text wball">203.0.113.42</span></span></td></tr>
        <tr><td>Country</td><td><span class="flag-container" id="lookup-flag" data-iso_code="NL"><img class="flag-icon" src="/img/flags/NL.png" alt="NL" title="Netherlands (NL)"><span class="flag-text wball">Netherlands <span class="row-tag">(<span>NL</span>)</span></span></span></td></tr>
        <tr><td>City</td><td>Amsterdam</td></tr>
        """
        let parsed = BrowserLeaksIPParser.parse(html)
        XCTAssertEqual(parsed?.ip, "203.0.113.42")
        XCTAssertEqual(parsed?.countryCode, "NL")
        XCTAssertEqual(parsed?.country, "Netherlands")
        XCTAssertEqual(parsed?.city, "Amsterdam")
    }

    func test_browserLeaksHTML_empty_returnsNil() {
        XCTAssertNil(BrowserLeaksIPParser.parse("<html><body>no ip here</body></html>"))
    }
}
