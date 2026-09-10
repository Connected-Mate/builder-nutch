import XCTest
@testable import Codenotch

final class AccountNamingTests: XCTestCase {
    func testTheNameIsWhatComesBeforeTheFirstDot() {
        XCTAssertEqual(AccountNaming.suggested(email: "alex.connectedmate@gmail.com", taken: []), "Alex")
        XCTAssertEqual(AccountNaming.suggested(email: "jean.claude.myai@gmail.com", taken: []), "Jean")
        XCTAssertEqual(AccountNaming.suggested(email: "nodots@example.test", taken: []), "Nodots")
        XCTAssertEqual(AccountNaming.suggested(email: "alex+work.tgv@example.test", taken: []), "Alex")
    }

    func testTwoAddressesWithTheSameStartAreToldApartByTheNextPiece() {
        let first = AccountNaming.suggested(email: "staff.1.iaetinno.tgv@gmail.com", taken: [])
        XCTAssertEqual(first, "Staff")
        let second = AccountNaming.suggested(email: "staff.2.iaetinno.tgv@gmail.com", taken: ["Staff"])
        XCTAssertEqual(second, "Staff 2")
        XCTAssertEqual(AccountNaming.suggested(email: "alex.cormeraie@gmail.com", taken: ["alex"]), "Alex Cormeraie",
                       "Taken is compared without case")
    }

    func testAnAddressWithNothingToOfferGivesNoName() {
        XCTAssertNil(AccountNaming.suggested(email: "@example.test", taken: []))
        XCTAssertNil(AccountNaming.suggested(email: "not an address", taken: []))
        XCTAssertNil(AccountNaming.suggested(email: "solo@example.test", taken: ["Solo"]), "Every piece is in use")
    }

    func testOnlyTheAppsOwnDefaultNamesAreReplaced() {
        XCTAssertTrue(AccountNaming.isDefault("Claude", provider: .claude))
        XCTAssertTrue(AccountNaming.isDefault("Claude 4", provider: .claude))
        XCTAssertTrue(AccountNaming.isDefault("Codex 12", provider: .codex))
        XCTAssertFalse(AccountNaming.isDefault("Claude Pro", provider: .claude))
        XCTAssertFalse(AccountNaming.isDefault("Boulot", provider: .claude))
        XCTAssertFalse(AccountNaming.isDefault("Claude 4", provider: .codex))
    }
}
