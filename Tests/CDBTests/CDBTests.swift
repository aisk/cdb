import XCTest
@testable import CDB

final class CDBTests: XCTestCase {
    func testExample() throws {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods

        let db1 = try CDB(filename: "example.cdb", mode: .write)
        try db1.add(key: "foo", value: "bar")
        try db1.add(key: "hello", value: "world")
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        try db1.add(key: "binary", value: testData)
        try db1.close()

        let db2 = try CDB(filename: "example.cdb", mode: .read)
        let value1: String? = try db2.get(key: "foo")
        XCTAssertEqual(value1, Optional("bar"))
        let count1 = try db2.count(key: "foo")
        XCTAssertEqual(count1, 1)
        let value2: String? = try db2.get(key: "not_exist")
        XCTAssertEqual(value2, nil)
        let count2 = try db2.count(key: "not_exist")
        XCTAssertEqual(count2, 0)

        var items: [String: String] = [:]
        try db2.forEach { key, value in
            items[key] = value
        }
        XCTAssertEqual(items, ["foo": "bar", "hello": "world", "binary": "\u{01}\u{02}\u{03}\u{04}"])

        XCTAssertEqual(db2["foo"], "bar")
        XCTAssertEqual(db2["hello"], "world")
        XCTAssertNil(db2["nonexistent"])

        let retrievedData: Data? = try db2.get(key: "binary")
        XCTAssertEqual(retrievedData, testData)

        try db2.close()
    }

    func testBinaryValueWithNullBytes() throws {
        let db1 = try CDB(filename: "binary_null_test.cdb", mode: .write)
        // A value containing an embedded 0x00 must survive round-tripping;
        // String(cString:) used to truncate it at the first NUL byte.
        let withNull = Data([0x01, 0x00, 0x02, 0x00, 0x03])
        try db1.add(key: "withNull", value: withNull)
        try db1.add(key: "empty", value: Data())
        try db1.close()

        let db2 = try CDB(filename: "binary_null_test.cdb", mode: .read)

        // Data API: full bytes preserved, not truncated at the first 0x00.
        let data: Data? = try db2.get(key: "withNull")
        XCTAssertEqual(data, withNull)

        // String API reads by length too, so length is preserved.
        let str: String? = try db2.get(key: "withNull")
        XCTAssertEqual(str?.utf8.count, withNull.count)

        // Empty Data round-trips without crashing on a nil baseAddress.
        let emptyData: Data? = try db2.get(key: "empty")
        XCTAssertEqual(emptyData, Data())

        try db2.close()
    }

    func testForEach() throws {
        let db1 = try CDB(filename: "foreach_test.cdb", mode: .write)
        try db1.add(key: "a", value: "1")
        try db1.add(key: "b", value: "2")
        try db1.add(key: "c", value: "3")
        try db1.close()

        let db2 = try CDB(filename: "foreach_test.cdb", mode: .read)
        var items: [String: String] = [:]
        try db2.forEach { key, value in
            items[key] = value
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items["a"], "1")
        XCTAssertEqual(items["b"], "2")
        XCTAssertEqual(items["c"], "3")

        var count = 0
        try db2.forEach { _, _ in
            count += 1
        }
        XCTAssertEqual(count, 3)

        try db2.close()
    }

    func testForEachEarlyExit() throws {
        let db1 = try CDB(filename: "foreach_exit_test.cdb", mode: .write)
        try db1.add(key: "a", value: "1")
        try db1.add(key: "b", value: "2")
        try db1.add(key: "c", value: "3")
        try db1.close()

        let db2 = try CDB(filename: "foreach_exit_test.cdb", mode: .read)
        enum TestError: Error { case stop }
        var count = 0
        XCTAssertThrowsError(try db2.forEach { _, _ in
            count += 1
            if count == 2 {
                throw TestError.stop
            }
        })
        XCTAssertGreaterThanOrEqual(count, 2)

        try db2.close()
    }
}
