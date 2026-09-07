import AppKit
import XCTest
@testable import Codenotch

final class BrandResourceTests: XCTestCase {
    func testWebsiteFontIsAvailableInsideTheApplication() {
        AppTheme.registerFonts()
        guard let name = AppTheme.fontName else {
            return XCTFail("The application must bundle its Bricolage Grotesque font.")
        }
        XCTAssertTrue(name.contains("BricolageGrotesque"))
        XCTAssertNotNil(NSFont(name: name, size: 14))
    }

    func testEveryManagedProviderHasItsRealBundledMark() {
        for provider in AccountProvider.allCases {
            guard let name = provider.glyph.brandAssetName else {
                XCTFail("Missing real mark for \(provider.title)")
                continue
            }
            guard let image = NSImage(named: name) else {
                XCTFail("Missing bundled artwork: \(name)")
                continue
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
        XCTAssertNotNil(NSImage(named: "brand-kimi-dark"))
    }
}
