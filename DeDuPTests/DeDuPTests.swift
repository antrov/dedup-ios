//
//  DeDuPTests.swift
//  DeDuPTests
//
//  Created by Hubert Andrzejewski on 21/05/2024.
//

@testable import DeDuP
import XCTest

final class DeDuPTests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testFieldStringEquatable() {
        let strField = Field<String>(value: "foo", difference: .notCompared)
        let optionalNilField = Field<String?>(value: nil, difference: .notCompared)
        let optionalFooField = Field<String?>(value: "foo", difference: .notCompared)
        let optionalBarField = Field<String?>(value: "bar", difference: .notCompared)

        XCTAssertEqual(strField == strField, true)
        XCTAssertEqual(optionalNilField == optionalNilField, true)
        XCTAssertEqual(optionalNilField == optionalFooField, false)
        XCTAssertEqual(optionalFooField == optionalFooField, true)
        XCTAssertEqual(optionalFooField == optionalBarField, false)
    }

    func testFieldDateEquatable() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let nowField = Field<Date>(value: now, difference: .notCompared)
        let nowPlusMsField = Field<Date>(value: now.addingTimeInterval(0.001), difference: .notCompared)
        let nowPlusMoreMsField = Field<Date>(value: now.addingTimeInterval(0.999), difference: .notCompared)
        let nowPlusSecField = Field<Date>(value: now.addingTimeInterval(1), difference: .notCompared)
        let nowPlusDayField = Field<Date>(value: now.addingTimeInterval(86400), difference: .notCompared)

        XCTAssertEqual(nowField, nowField)
        XCTAssertEqual(nowField, nowPlusMsField)
        XCTAssertEqual(nowField, nowPlusMoreMsField)
        XCTAssertEqual(nowPlusMsField, nowPlusMoreMsField)
        XCTAssertEqual(nowPlusMoreMsField, nowPlusSecField)
        XCTAssertNotEqual(nowField, nowPlusSecField)
        XCTAssertNotEqual(nowField, nowPlusDayField)
    }
}
