// A .DS_Store file, read by its structure, never written. The format is
// Finder's and undocumented by Apple; what is known of it (Mark Mentovai's and
// Wim Lewis's notes) is all this reader assumes:
//
//   4 bytes 0x00000001, then a buddy allocator ("Bud1") whose header names
//   its info block: the address of every block, and a table of contents. The
//   entry "DSDB" is the block holding a B-tree's header: root node, levels,
//   record count, node count, page size. A node is a u32 P and a u32 count:
//   P == 0 is a leaf of `count` records; otherwise `count` pairs (child block,
//   record) followed by the rightmost child P. A record is its file name
//   (u32 length in UTF-16 units, UTF-16BE), a four-char code, a four-char
//   type and a value of that type. Everything is big-endian, and every
//   offset in the allocator is from byte 4 of the file.
//
// Every read is bounded by the block it belongs to, every count is checked
// against the header, so a damaged file is a `Corrupt` naming what is wrong,
// never a partial answer.
import Foundation

public struct DSStore: Sendable {
    public enum Value: Sendable, Equatable {
        case long(UInt32)
        case shor(UInt16)
        case bool(Bool)
        case blob([UInt8])
        case type(String)
        case ustr(String)
        case comp(UInt64)
        case dutc(UInt64)
    }

    public struct Record: Sendable {
        /// The name of the file the record is about, inside the folder the
        /// .DS_Store belongs to.
        public let name: String
        public let code: String
        public let value: Value
    }

    public struct Corrupt: Error, Codable, Sendable {
        public let why: String
    }

    /// In the B-tree's order.
    public let records: [Record]

    public init(_ data: Data) throws(Corrupt) {
        let file = Bytes(bytes: [UInt8](data), start: 0, end: data.count)
        guard try file.u32(0) == 1, try file.fourCC(4) == "Bud1" else {
            throw Corrupt(why: "not a .DS_Store: no Bud1 header")
        }
        let infoOffset = Int(try file.u32(8))
        let infoSize = Int(try file.u32(12))
        guard try file.u32(16) == infoOffset else {
            throw Corrupt(why: "the header's two copies of the info block offset differ")
        }
        let info = try file.block(at: 4 + infoOffset, size: infoSize, "the allocator info block")

        let blockCount = Int(try info.u32(0))
        let addresses = try (0..<blockCount).map { (i) throws(Corrupt) in try info.u32(8 + 4 * i) }
        // The address table is padded to a multiple of 256 entries.
        var at = 8 + 4 * ((blockCount + 255) / 256 * 256)
        let tocCount = Int(try info.u32(at))
        at += 4
        var toc: [String: UInt32] = [:]
        for _ in 0..<tocCount {
            let length = Int(try info.u8(at))
            let name = String(decoding: try info.slice(at + 1, length), as: UTF8.self)
            toc[name] = try info.u32(at + 1 + length)
            at += 1 + length + 4
        }
        guard let dsdb = toc["DSDB"] else {
            throw Corrupt(why: "no DSDB entry in the table of contents")
        }

        func node(_ number: UInt32) throws(Corrupt) -> Bytes {
            guard Int(number) < addresses.count else {
                throw Corrupt(
                    why: "block \(number) is past the \(addresses.count) the allocator has")
            }
            let address = addresses[Int(number)]
            return try file.block(
                at: 4 + Int(address & ~0x1F), size: 1 << Int(address & 0x1F), "block \(number)")
        }

        let header = try node(dsdb)
        let root = try header.u32(0)
        let levels = Int(try header.u32(4))
        let expected = Int(try header.u32(8))

        var records: [Record] = []
        records.reserveCapacity(expected)
        func walk(_ number: UInt32, depth: Int) throws(Corrupt) {
            guard depth <= levels else {
                throw Corrupt(why: "the B-tree is deeper than the \(levels) levels its header says")
            }
            let page = try node(number)
            let rightmost = try page.u32(0)
            let count = Int(try page.u32(4))
            var at = 8
            if rightmost == 0 {
                guard depth == levels else {
                    throw Corrupt(why: "a leaf at depth \(depth) of a \(levels)-level B-tree")
                }
                for _ in 0..<count { records.append(try page.record(&at)) }
                return
            }
            for _ in 0..<count {
                let child = try page.u32(at)
                at += 4
                try walk(child, depth: depth + 1)
                records.append(try page.record(&at))
            }
            try walk(rightmost, depth: depth + 1)
        }
        try walk(root, depth: 0)
        guard records.count == expected else {
            throw Corrupt(
                why: "the B-tree holds \(records.count) records, its header says \(expected)")
        }
        self.records = records
    }
}

/// A bounded view of the file: a read outside `start..<end` is a `Corrupt`.
private struct Bytes {
    let bytes: [UInt8]
    let start: Int
    let end: Int

    func slice(_ offset: Int, _ count: Int) throws(DSStore.Corrupt) -> ArraySlice<UInt8> {
        let from = start + offset
        guard offset >= 0, count >= 0, from + count <= end else {
            throw DSStore.Corrupt(
                why: "a read of \(count) bytes at \(from) runs past the block ending at \(end)")
        }
        return bytes[from..<from + count]
    }

    func u8(_ offset: Int) throws(DSStore.Corrupt) -> UInt8 { try slice(offset, 1).first! }

    func u32(_ offset: Int) throws(DSStore.Corrupt) -> UInt32 {
        try slice(offset, 4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    func u64(_ offset: Int) throws(DSStore.Corrupt) -> UInt64 {
        try slice(offset, 8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    func fourCC(_ offset: Int) throws(DSStore.Corrupt) -> String {
        String(decoding: try slice(offset, 4), as: UTF8.self)
    }

    func utf16(_ offset: Int, units: Int) throws(DSStore.Corrupt) -> String {
        let raw = Array(try slice(offset, 2 * units))
        let units = stride(from: 0, to: raw.count, by: 2).map {
            UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1])
        }
        return String(decoding: units, as: UTF16.self)
    }

    func block(at offset: Int, size: Int, _ what: String) throws(DSStore.Corrupt) -> Bytes {
        guard offset >= 0, size >= 0, offset + size <= end else {
            throw DSStore.Corrupt(
                why: "\(what) (\(size) bytes at \(offset)) runs past the file's \(end) bytes")
        }
        return Bytes(bytes: bytes, start: offset, end: offset + size)
    }

    /// The record at `at`, which moves past it.
    func record(_ at: inout Int) throws(DSStore.Corrupt) -> DSStore.Record {
        let nameUnits = Int(try u32(at))
        let name = try utf16(at + 4, units: nameUnits)
        at += 4 + 2 * nameUnits
        let code = try fourCC(at)
        let type = try fourCC(at + 4)
        at += 8
        let value: DSStore.Value
        switch type {
        case "long":
            value = .long(try u32(at))
            at += 4
        case "shor":
            value = .shor(UInt16(truncatingIfNeeded: try u32(at)))
            at += 4
        case "bool":
            value = .bool(try u8(at) != 0)
            at += 1
        case "type":
            value = .type(try fourCC(at))
            at += 4
        case "blob":
            let length = Int(try u32(at))
            value = .blob(Array(try slice(at + 4, length)))
            at += 4 + length
        case "ustr":
            let units = Int(try u32(at))
            value = .ustr(try utf16(at + 4, units: units))
            at += 4 + 2 * units
        case "comp":
            value = .comp(try u64(at))
            at += 8
        case "dutc":
            value = .dutc(try u64(at))
            at += 8
        default:
            throw DSStore.Corrupt(
                why: "record '\(name)' \(code) has type '\(type)', which this reader does not know")
        }
        return DSStore.Record(name: name, code: code, value: value)
    }
}
