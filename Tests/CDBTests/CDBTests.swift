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
        let value1 = try db2.string(forKey: "foo")
        XCTAssertEqual(value1, Optional("bar"))
        let count1 = try db2.count(key: "foo")
        XCTAssertEqual(count1, 1)
        let value2 = try db2.string(forKey: "not_exist")
        XCTAssertEqual(value2, nil)
        let count2 = try db2.count(key: "not_exist")
        XCTAssertEqual(count2, 0)

        var items: [String: String] = [:]
        try db2.forEach { key, value in
            items[key] = value
        }
        XCTAssertEqual(items, ["foo": "bar", "hello": "world", "binary": "\u{01}\u{02}\u{03}\u{04}"])

        XCTAssertEqual(try db2["foo"], "bar")
        XCTAssertEqual(try db2["hello"], "world")
        XCTAssertNil(try db2["nonexistent"])

        let retrievedData = try db2.data(forKey: "binary")
        XCTAssertEqual(retrievedData, testData)

        try db2.close()
        XCTAssertThrowsError(try db2["foo"])
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
        let data = try db2.data(forKey: "withNull")
        XCTAssertEqual(data, withNull)

        // String API reads by length too, so length is preserved.
        let str = try db2.string(forKey: "withNull")
        XCTAssertEqual(str?.utf8.count, withNull.count)

        // Empty Data round-trips without crashing on a nil baseAddress.
        let emptyData = try db2.data(forKey: "empty")
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

    func testForEachCannotCloseDatabaseFromCallback() throws {
        let writer = try CDB(filename: "foreach_close_test.cdb", mode: .write)
        try writer.add(key: "a", value: "1")
        try writer.add(key: "b", value: "2")
        try writer.close()

        let reader = try CDB(filename: "foreach_close_test.cdb", mode: .read)
        var closeError: Error?
        var count = 0

        try reader.forEach { _, _ in
            count += 1
            do {
                try reader.close()
            } catch {
                closeError = error
            }
        }

        XCTAssertEqual(
            closeError as? CDBError,
            .operationInProgress(operation: "close")
        )
        XCTAssertEqual(count, 2)
        let value = try reader.string(forKey: "a")
        XCTAssertEqual(value, "1")
        try reader.close()
    }

    func testBinaryKeysAndIteration() throws {
        let binaryKey = Data([0x00, 0xff, 0x01])
        let binaryValue = Data([0xfe, 0x00, 0x02])
        let writer = try CDB(filename: "binary_key_test.cdb", mode: .write)
        try writer.add(key: binaryKey, value: binaryValue)
        try writer.close()

        let reader = try CDB(filename: "binary_key_test.cdb", mode: .read)
        XCTAssertEqual(try reader.data(forKey: binaryKey), binaryValue)
        XCTAssertEqual(try reader.count(key: binaryKey), 1)

        var entries: [(Data, Data)] = []
        try reader.forEachData { key, value in
            entries.append((key, value))
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.0, binaryKey)
        XCTAssertEqual(entries.first?.1, binaryValue)
        try reader.close()
    }

    func testStringAPIsRejectInvalidUTF8() throws {
        let writer = try CDB(filename: "invalid_utf8_test.cdb", mode: .write)
        try writer.add(key: "invalid", value: Data([0xff]))
        try writer.add(key: Data([0xff]), value: "value")
        try writer.close()

        let reader = try CDB(filename: "invalid_utf8_test.cdb", mode: .read)
        XCTAssertThrowsError(try reader.string(forKey: "invalid")) { error in
            XCTAssertEqual(error as? CDBError, .invalidUTF8(context: "value"))
        }
        XCTAssertEqual(try reader.data(forKey: "invalid"), Data([0xff]))
        XCTAssertThrowsError(try reader.forEach { _, _ in })

        var count = 0
        try reader.forEachData { _, _ in count += 1 }
        XCTAssertEqual(count, 2)
        try reader.close()
    }

    func testWithDatabaseClosesAndFinalizes() throws {
        try CDB.withDatabase(filename: "scoped_test.cdb", mode: .write) { db in
            try db.add(key: "key", value: "value")
        }

        let value = try CDB.withDatabase(
            filename: "scoped_test.cdb",
            mode: .read
        ) { db in
            try db.string(forKey: "key")
        }
        XCTAssertEqual(value, "value")
    }

    func testWithDatabasePreservesBodyError() throws {
        enum TestError: Error, Equatable { case expected }

        XCTAssertThrowsError(
            try CDB.withDatabase(filename: "scoped_error_test.cdb", mode: .write) { _ in
                throw TestError.expected
            }
        ) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }
    }

    func testOperationsValidateAccessMode() throws {
        let writer = try CDB(filename: "mode_test.cdb", mode: .write)
        XCTAssertThrowsError(try writer.data(forKey: "key")) { error in
            XCTAssertEqual(
                error as? CDBError,
                .wrongMode(operation: "get", required: .read)
            )
        }
        try writer.add(key: "key", value: "value")
        try writer.close()

        let reader = try CDB(filename: "mode_test.cdb", mode: .read)
        XCTAssertThrowsError(try reader.add(key: "key", value: "other")) { error in
            XCTAssertEqual(
                error as? CDBError,
                .wrongMode(operation: "add", required: .write)
            )
        }
        XCTAssertEqual(try reader.string(forKey: "key"), "value")
        try reader.close()
    }
}
