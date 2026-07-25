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

public struct CDBError: Error {
    public let errno: Int
    public let operation: String

    public var localizedDescription: String {
        return "CDB \(operation) failed with error code: \(errno)"
    }
}

public enum Mode: Int32 {
    case read = 0
    case write = 1
}

public class CDB {
    private var db: OpaquePointer?
    private var isClosed = false

    public init(filename: String, mode: Mode) throws {
        var raw_options = cdb_host_options
        let res = cdb_open(&self.db, &raw_options, mode.rawValue, filename)
        if res != 0 {
            throw CDBError(errno: Int(res), operation: "open")
        }
    }

    public func add(key: String, value: String) throws {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "add")
        }

        try key.withCString { cKey in
            try value.withCString { cValue in
                var keyBuffer = cdb_buffer_t(length: UInt64(key.utf8.count), buffer: cKey)
                var valueBuffer = cdb_buffer_t(length: UInt64(value.utf8.count), buffer: cValue)

                let res = cdb_add(db, &keyBuffer, &valueBuffer)
                if res != 0 {
                    throw CDBError(errno: Int(res), operation: "add")
                }
            }
        }
    }

    public func add(key: String, value: Data) throws {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "add")
        }

        try key.withCString { cKey in
            let res = value.withUnsafeBytes { valueBytes -> Int32 in
                var keyBuffer = cdb_buffer_t(length: UInt64(key.utf8.count), buffer: cKey)
                // For an empty Data, baseAddress is nil; pass a non-null dummy
                // pointer since the C side won't read any bytes when length is 0.
                let valuePtr = valueBytes.baseAddress?.assumingMemoryBound(to: Int8.self) ?? cKey
                var valueBuffer = cdb_buffer_t(length: UInt64(value.count), buffer: valuePtr)

                return cdb_add(db, &keyBuffer, &valueBuffer)
            }

            if res != 0 {
                throw CDBError(errno: Int(res), operation: "add")
            }
        }
    }

    public func get(key: String, at index: UInt64=0) throws -> String? {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "get")
        }

        return try key.withCString { cKey in
            var keyBuffer = cdb_buffer_t(length: UInt64(key.utf8.count), buffer: cKey)
            var value_info = cdb_file_pos_t(position: 0, length: 0)

            let res = cdb_lookup(self.db, &keyBuffer, &value_info, index)
            if res == 0 {
                return nil
            }
            if res != 1 {
                throw CDBError(errno: Int(res), operation: "lookup")
            }

            return try readString(at: value_info)
        }
    }

    public func get(key: String, at index: UInt64=0) throws -> Data? {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "get")
        }

        return try key.withCString { cKey in
            var keyBuffer = cdb_buffer_t(length: UInt64(key.utf8.count), buffer: cKey)
            var value_info = cdb_file_pos_t(position: 0, length: 0)

            let res = cdb_lookup(self.db, &keyBuffer, &value_info, index)
            if res == 0 {
                return nil
            }
            if res != 1 {
                throw CDBError(errno: Int(res), operation: "lookup")
            }

            return try readData(at: value_info)
        }
    }

    public func count(key: String) throws -> UInt64 {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "count")
        }

        return try key.withCString { cKey in
            var keyBuffer = cdb_buffer_t(length: UInt64(key.utf8.count), buffer: cKey)
            var result: UInt64 = 0

            let res = cdb_count(self.db, &keyBuffer, &result)
            if res != 0 {
                throw CDBError(errno: Int(res), operation: "count")
            }

            return result
        }
    }

    public func close() throws {
        guard !isClosed else { return }
        // cdb_close always releases the underlying handle, including when
        // finalization or closing the file fails.
        let handle = db
        db = nil
        isClosed = true

        let res = cdb_close(handle)
        if res != 0 {
            throw CDBError(errno: Int(res), operation: "close")
        }
    }

    public func forEach(_ body: @escaping (String, String) throws -> Void) throws {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "forEach")
        }

        let helper = ForEachHelper(cdb: self, body: body)
        let helperPtr = Unmanaged.passUnretained(helper).toOpaque()

        let callback: cdb_callback = { cdb, key, value, param in
            let helper = Unmanaged<ForEachHelper>.fromOpaque(param!).takeUnretainedValue()
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
            throw CDBError(errno: Int(res), operation: "forEach")
        }
    }

    fileprivate func readString(at pos: cdb_file_pos_t) throws -> String {
        // Decode exactly `pos.length` bytes; do NOT rely on a NUL terminator,
        // otherwise values containing 0x00 would be silently truncated.
        let data = try readData(at: pos)
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate func readData(at pos: cdb_file_pos_t) throws -> Data {
        guard !isClosed else {
            throw CDBError(errno: -1, operation: "read")
        }

        let res = cdb_seek(self.db, pos.position)
        if res != 0 {
            throw CDBError(errno: Int(res), operation: "seek")
        }

        if pos.length == 0 {
            return Data()
        }

        var data = Data(count: Int(pos.length))
        let read_res = data.withUnsafeMutableBytes { bytes in
            cdb_read(self.db, bytes.baseAddress, pos.length)
        }

        if read_res != 0 {
            throw CDBError(errno: Int(read_res), operation: "read")
        }

        return data
    }

    deinit {
        try? close()
    }

    public subscript(key: String) -> String? {
        return try? get(key: key)
    }
}

private class ForEachHelper {
    private weak var cdb: CDB?
    private let body: (String, String) throws -> Void
    var error: Error?

    init(cdb: CDB, body: @escaping (String, String) throws -> Void) {
        self.cdb = cdb
        self.body = body
    }

    func handle(keyPos: cdb_file_pos_t, valuePos: cdb_file_pos_t) throws {
        guard let cdb = cdb else { return }
        let key = try cdb.readString(at: keyPos)
        let value = try cdb.readString(at: valuePos)
        try body(key, value)
    }
}
