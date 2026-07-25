// The Swift Programming Language
// https://docs.swift.org/swift-book

import cdbc
import Foundation

extension cdb_buffer_t {
    init(length: UInt64, buffer: UnsafePointer<Int8>) {
        self.init()
        self.length = length
        self.buffer = UnsafeMutablePointer(mutating: buffer)
    }
}

private func withCDBBuffer<Result>(
    for data: Data,
    _ body: (inout cdb_buffer_t) throws -> Result
) rethrows -> Result {
    var emptyByte: Int8 = 0
    return try withUnsafePointer(to: &emptyByte) { emptyPointer in
        try data.withUnsafeBytes { bytes in
            let pointer = bytes.baseAddress?.assumingMemoryBound(to: Int8.self) ?? emptyPointer
            var buffer = cdb_buffer_t(length: UInt64(data.count), buffer: pointer)
            return try body(&buffer)
        }
    }
}

public enum CDBError: Error, LocalizedError, Equatable {
    case closed(operation: String)
    case invalidUTF8(context: String)
    case operationInProgress(operation: String)
    case native(operation: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .closed(let operation):
            return "Cannot perform CDB \(operation) because the database is closed"
        case .invalidUTF8(let context):
            return "CDB \(context) is not valid UTF-8"
        case .operationInProgress(let operation):
            return "Cannot perform CDB \(operation) while another operation is in progress"
        case .native(let operation, let code):
            return "CDB \(operation) failed with error code: \(code)"
        }
    }
}

public enum Mode: Int32 {
    case read = 0
    case write = 1
}

/// A handle to a constant database file.
///
/// `CDB` instances are not thread-safe. Serialize all operations performed on
/// the same instance, including calls to ``close()``. Separate instances may be
/// used concurrently.
public class CDB {
    private var db: OpaquePointer?
    private var isClosed = false
    private var activeIterationCount = 0

    public init(filename: String, mode: Mode) throws {
        var raw_options = cdb_host_options
        let res = cdb_open(&self.db, &raw_options, mode.rawValue, filename)
        if res != 0 {
            throw CDBError.native(operation: "open", code: Int(res))
        }
    }

    public func add(key: String, value: String) throws {
        try add(key: Data(key.utf8), value: Data(value.utf8))
    }

    public func add(key: String, value: Data) throws {
        try add(key: Data(key.utf8), value: value)
    }

    public func add(key: Data, value: String) throws {
        try add(key: key, value: Data(value.utf8))
    }

    public func add(key: Data, value: Data) throws {
        guard !isClosed else {
            throw CDBError.closed(operation: "add")
        }

        try withCDBBuffer(for: key) { keyBuffer in
            try withCDBBuffer(for: value) { valueBuffer in
                let res = cdb_add(db, &keyBuffer, &valueBuffer)
                if res != 0 {
                    throw CDBError.native(operation: "add", code: Int(res))
                }
            }
        }
    }

    public func string(forKey key: String, at index: UInt64 = 0) throws -> String? {
        try string(forKey: Data(key.utf8), at: index)
    }

    public func string(forKey key: Data, at index: UInt64 = 0) throws -> String? {
        guard let data = try data(forKey: key, at: index) else {
            return nil
        }
        return try decodeUTF8(data, context: "value")
    }

    public func data(forKey key: String, at index: UInt64 = 0) throws -> Data? {
        try data(forKey: Data(key.utf8), at: index)
    }

    public func data(forKey key: Data, at index: UInt64 = 0) throws -> Data? {
        guard !isClosed else {
            throw CDBError.closed(operation: "get")
        }

        return try withCDBBuffer(for: key) { keyBuffer in
            var value_info = cdb_file_pos_t(position: 0, length: 0)

            let res = cdb_lookup(self.db, &keyBuffer, &value_info, index)
            if res == 0 {
                return nil
            }
            if res != 1 {
                throw CDBError.native(operation: "lookup", code: Int(res))
            }

            return try readData(at: value_info)
        }
    }

    public func count(key: String) throws -> UInt64 {
        try count(key: Data(key.utf8))
    }

    public func count(key: Data) throws -> UInt64 {
        guard !isClosed else {
            throw CDBError.closed(operation: "count")
        }

        return try withCDBBuffer(for: key) { keyBuffer in
            var result: UInt64 = 0

            let res = cdb_count(self.db, &keyBuffer, &result)
            if res != 0 {
                throw CDBError.native(operation: "count", code: Int(res))
            }

            return result
        }
    }

    /// Closes the database and, in write mode, finalizes it on disk.
    ///
    /// Do not call this method from a ``forEach(_:)`` callback.
    public func close() throws {
        guard !isClosed else { return }
        guard activeIterationCount == 0 else {
            throw CDBError.operationInProgress(operation: "close")
        }
        // cdb_close always releases the underlying handle, including when
        // finalization or closing the file fails.
        let handle = db
        db = nil
        isClosed = true

        let res = cdb_close(handle)
        if res != 0 {
            throw CDBError.native(operation: "close", code: Int(res))
        }
    }

    /// Visits every key-value pair in the database.
    ///
    /// The callback must not close this database.
    public func forEach(_ body: @escaping (String, String) throws -> Void) throws {
        try forEachData { key, value in
            try body(
                self.decodeUTF8(key, context: "key"),
                self.decodeUTF8(value, context: "value")
            )
        }
    }

    /// Visits every key-value pair without decoding its bytes.
    ///
    /// The callback must not close this database.
    public func forEachData(_ body: @escaping (Data, Data) throws -> Void) throws {
        guard !isClosed else {
            throw CDBError.closed(operation: "forEachData")
        }

        activeIterationCount += 1
        defer { activeIterationCount -= 1 }

        let helper = ForEachDataHelper(cdb: self, body: body)
        let helperPtr = Unmanaged.passUnretained(helper).toOpaque()

        let callback: cdb_callback = { cdb, key, value, param in
            let helper = Unmanaged<ForEachDataHelper>.fromOpaque(param!).takeUnretainedValue()
            do {
                try helper.handle(keyPos: key!.pointee, valuePos: value!.pointee)
                return 0
            } catch {
                helper.error = error
                return 1
            }
        }

        let res = cdb_foreach(self.db, callback, helperPtr)
        if let error = helper.error {
            throw error
        }
        if res < 0 {
            throw CDBError.native(operation: "forEach", code: Int(res))
        }
    }

    private func decodeUTF8(_ data: Data, context: String) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CDBError.invalidUTF8(context: context)
        }
        return string
    }

    fileprivate func readData(at pos: cdb_file_pos_t) throws -> Data {
        guard !isClosed else {
            throw CDBError.closed(operation: "read")
        }

        let res = cdb_seek(self.db, pos.position)
        if res != 0 {
            throw CDBError.native(operation: "seek", code: Int(res))
        }

        if pos.length == 0 {
            return Data()
        }

        var data = Data(count: Int(pos.length))
        let read_res = data.withUnsafeMutableBytes { bytes in
            cdb_read(self.db, bytes.baseAddress, pos.length)
        }

        if read_res != 0 {
            throw CDBError.native(operation: "read", code: Int(read_res))
        }

        return data
    }

    deinit {
        try? close()
    }

    public subscript(key: String) -> String? {
        get throws {
            return try string(forKey: key)
        }
    }
}

private class ForEachDataHelper {
    private weak var cdb: CDB?
    private let body: (Data, Data) throws -> Void
    var error: Error?

    init(cdb: CDB, body: @escaping (Data, Data) throws -> Void) {
        self.cdb = cdb
        self.body = body
    }

    func handle(keyPos: cdb_file_pos_t, valuePos: cdb_file_pos_t) throws {
        guard let cdb = cdb else { return }
        let key = try cdb.readData(at: keyPos)
        let value = try cdb.readData(at: valuePos)
        try body(key, value)
    }
}
