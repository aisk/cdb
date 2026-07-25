# swift-cdb

A Swift wrapper for the CDB (Constant Database) implementation from [howerj/cdb](https://github.com/howerj/cdb), providing a native Swift interface for creating and querying constant key-value databases.

## Installation

Add this package to your Swift project dependencies:

```swift
// In your Package.swift
dependencies: [
    .package(url: "https://github.com/aisk/swift-cdb.git", from: "0.1.0"),
]
```

## Usage

```swift
import CDB

// Open a CDB file and read values
do {
    let db = try CDB(filename: "example.cdb", mode: .read)

    // Read string value
    let value = try db.string(forKey: "some_key")
    print("Value: \(value ?? "not found")")

    try db.close()
} catch {
    print("Error: \(error)")
}
```

## API Reference

### Main Methods

- `init(filename: String, mode: CDB.AccessMode) throws` - Open a CDB file
- `init(fileURL: URL, mode: CDB.AccessMode) throws` - Open a CDB file URL
- `add(key: String, value: String) throws` - Add a string value
- `add(key: String, value: Data) throws` - Add binary data
- `add(key: Data, value: String) throws` - Add a string value with a binary key
- `add(key: Data, value: Data) throws` - Add a binary key and value
- `string(forKey: String, at index: UInt64 = 0) throws -> String?` - Get a string value
- `data(forKey: String, at index: UInt64 = 0) throws -> Data?` - Get binary data
- `count(key: String) throws -> UInt64` - Count values for a key
- `forEachData(_:) throws` - Visit all keys and values without decoding
- `close() throws` - Close the database
- `withDatabase(filename:mode:_:) throws` - Use a database within a managed scope
- `withDatabase(fileURL:mode:_:) throws` - Use a file URL within a managed scope
- `subscript(key: String) throws -> String?` - Dictionary-like access

### Access Modes

- `CDB.AccessMode.read` - Open for reading only
- `CDB.AccessMode.write` - Open for writing (creates new database)

## Thread Safety

A `CDB` instance is not thread-safe. Serialize all operations on the same
instance, including `close()`. Separate `CDB` instances may be used
concurrently.

Do not call `close()` from inside a `forEach` callback.

String APIs require valid UTF-8 and throw `CDBError.invalidUTF8` when stored
bytes cannot be decoded. Use `data(forKey:)` or `forEachData(_:)` for arbitrary
binary content.

## License

This project is licensed under the same terms as the original [CDB library](https://github.com/howerj/cdb).
