import Foundation

enum WebHardZipArchive {
    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? (value >> 1) ^ 0xEDB88320
                : value >> 1
        }
        return value
    }

    private struct Entry {
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let modificationTime: UInt16
        let modificationDate: UInt16
        let isDirectory: Bool
    }

    static func create(from directoryURL: URL, in temporaryDirectory: URL) throws -> URL {
        let archiveURL = temporaryDirectory.appendingPathComponent(
            "\(directoryURL.lastPathComponent)-\(UUID().uuidString).zip"
        )
        guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: archiveURL)
        do {
            let entries = try writeEntries(from: directoryURL, to: output)
            try writeCentralDirectory(entries, to: output)
            try output.close()
            return archiveURL
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    private static func writeEntries(
        from directoryURL: URL,
        to output: FileHandle
    ) throws -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw WebHardFileStoreError.itemNotFound
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory == true || values.isRegularFile == true else { continue }

            let relative = String(url.path.dropFirst(directoryURL.path.count + 1))
            let archiveName = values.isDirectory == true ? relative + "/" : relative
            guard let nameData = archiveName.data(using: .utf8),
                  nameData.count <= Int(UInt16.max) else {
                throw WebHardFileStoreError.unsupportedItem
            }
            let fileSize = UInt64(values.fileSize ?? 0)
            guard fileSize <= UInt64(UInt32.max),
                  output.offsetInFile <= UInt64(UInt32.max) else {
                throw WebHardFileStoreError.archiveTooLarge
            }

            let checksum = values.isRegularFile == true ? try crc32(of: url) : 0
            let (time, date) = dosDate(values.contentModificationDate ?? .now)
            let entry = Entry(
                nameData: nameData,
                crc32: checksum,
                size: UInt32(fileSize),
                localHeaderOffset: UInt32(output.offsetInFile),
                modificationTime: time,
                modificationDate: date,
                isDirectory: values.isDirectory == true
            )
            try writeLocalHeader(entry, to: output)
            if values.isRegularFile == true {
                try copy(url, to: output)
            }
            entries.append(entry)
        }
        return entries
    }

    private static func writeLocalHeader(_ entry: Entry, to output: FileHandle) throws {
        var data = Data()
        data.appendLittleEndian(UInt32(0x04034B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0x0800))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entry.modificationTime)
        data.appendLittleEndian(entry.modificationDate)
        data.appendLittleEndian(entry.crc32)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(entry.nameData.count))
        data.appendLittleEndian(UInt16(0))
        data.append(entry.nameData)
        try output.write(contentsOf: data)
    }

    private static func writeCentralDirectory(_ entries: [Entry], to output: FileHandle) throws {
        guard output.offsetInFile <= UInt64(UInt32.max), entries.count <= Int(UInt16.max) else {
            throw WebHardFileStoreError.archiveTooLarge
        }
        let start = UInt32(output.offsetInFile)
        for entry in entries {
            var data = Data()
            data.appendLittleEndian(UInt32(0x02014B50))
            data.appendLittleEndian(UInt16(20))
            data.appendLittleEndian(UInt16(20))
            data.appendLittleEndian(UInt16(0x0800))
            data.appendLittleEndian(UInt16(0))
            data.appendLittleEndian(entry.modificationTime)
            data.appendLittleEndian(entry.modificationDate)
            data.appendLittleEndian(entry.crc32)
            data.appendLittleEndian(entry.size)
            data.appendLittleEndian(entry.size)
            data.appendLittleEndian(UInt16(entry.nameData.count))
            data.appendLittleEndian(UInt16(0))
            data.appendLittleEndian(UInt16(0))
            data.appendLittleEndian(UInt16(0))
            data.appendLittleEndian(UInt16(0))
            data.appendLittleEndian(entry.isDirectory ? UInt32(0x10) : UInt32(0))
            data.appendLittleEndian(entry.localHeaderOffset)
            data.append(entry.nameData)
            try output.write(contentsOf: data)
        }
        guard output.offsetInFile <= UInt64(UInt32.max) else {
            throw WebHardFileStoreError.archiveTooLarge
        }
        let centralSize = UInt32(output.offsetInFile) - start
        var end = Data()
        end.appendLittleEndian(UInt32(0x06054B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(centralSize)
        end.appendLittleEndian(start)
        end.appendLittleEndian(UInt16(0))
        try output.write(contentsOf: end)
    }

    private static func copy(_ inputURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var checksum = UInt32.max
        while true {
            let data = try input.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            for byte in data {
                let index = Int((checksum ^ UInt32(byte)) & 0xFF)
                checksum = (checksum >> 8) ^ crc32Table[index]
            }
        }
        return checksum ^ UInt32.max
    }

    private static func dosDate(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(1980, min(2107, components.year ?? 1980))
        let time = UInt16((components.hour ?? 0) << 11)
            | UInt16((components.minute ?? 0) << 5)
            | UInt16((components.second ?? 0) / 2)
        let packedDate = UInt16(year - 1980) << 9
            | UInt16(components.month ?? 1) << 5
            | UInt16(components.day ?? 1)
        return (time, packedDate)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
