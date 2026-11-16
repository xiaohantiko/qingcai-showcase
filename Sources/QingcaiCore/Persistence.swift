import Foundation

public final class FinanceRepository {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("ledger.finance.json") }
    public var attachments: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }
    public init(directory: URL) { self.directory = directory }
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .deferredToDate; return e
    }
    public static func decode(_ data: Data) throws -> FinanceDocument {
        guard data.count <= 50_000_000 else { throw FinanceError.invalid("数据文件超过 50 MB，无法载入。") }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let string = try value.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: string) else { throw FinanceError.invalid("备份中的日期格式无效。") }
            return date
        }
        return try d.decode(FinanceDocument.self, from: data).validated()
    }
    public func load() throws -> FinanceDocument {
        guard FileManager.default.fileExists(atPath: file.path) else { return FinanceDocument() }
        return try Self.decode(Data(contentsOf: file))
    }
    public func save(_ document: FinanceDocument) throws {
        _ = try document.validated()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: file.path) {
            let history = directory.appendingPathComponent("History")
            try fm.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = history.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).finance.json")
            try fm.copyItem(at: file, to: backup)
            let all = try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in all.dropFirst(10) { try fm.removeItem(at: old) }
        }
        try Self.encoder().encode(document).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func addAttachment(from url: URL) throws -> String {
        let allowed = ["pdf", "png", "jpg", "jpeg", "heic", "tiff"]
        guard allowed.contains(url.pathExtension.lowercased()) else { throw FinanceError.invalid("请选择 PDF 或图片凭证。") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000_000,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw FinanceError.invalid("凭证必须是 20 MB 以内的普通文件。") }
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = UUID().uuidString + "." + url.pathExtension.lowercased()
        let target = attachments.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return name
    }
    /// 写入最新快照及所有被引用附件。备份目录可由 iCloud Drive 等云盘同步。
    public func exportSnapshot(_ document: FinanceDocument, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let targetAttachments = folder.appendingPathComponent("Attachments")
        try fm.createDirectory(at: targetAttachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Set(document.entries.compactMap(\.attachment)) {
            guard LedgerEntry.safeAttachment(name) else { throw FinanceError.invalid("凭证路径无效。") }
            let target = targetAttachments.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: attachments.appendingPathComponent(name), to: target) }
        }
        let snapshot = folder.appendingPathComponent("latest.finance.json")
        try Self.encoder().encode(document).write(to: snapshot, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
    }
    public func importAttachments(for document: FinanceDocument, from folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Set(document.entries.compactMap(\.attachment)) {
            guard LedgerEntry.safeAttachment(name) else { throw FinanceError.invalid("凭证路径无效。") }
            let target = attachments.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                let source = folder.appendingPathComponent("Attachments").appendingPathComponent(name)
                let attrs = try fm.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000_000 else { throw FinanceError.invalid("备份中的附件类型或大小无效。") }
                try fm.copyItem(at: source, to: target)
            }
        }
    }
}
