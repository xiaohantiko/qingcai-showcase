import Foundation
import CryptoKit
import CSQLite
import QingcaiCore

public struct GatewayFailure: LocalizedError {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
}
public enum GatewayHash {
    public static func data<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest<T: Encodable>(_ value: T) throws -> String { digest(try data(value)) }
}

/// Accessed only by FinanceGateway's actor. Transactions atomically save status and audit.
final class GatewayStore {
    private var db: OpaquePointer?
    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw GatewayFailure(500, "database_unavailable", "网关数据库无法打开。")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, idem TEXT UNIQUE NOT NULL, business TEXT UNIQUE, content TEXT NOT NULL); CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, time TEXT NOT NULL, action TEXT NOT NULL, previous TEXT NOT NULL, digest TEXT NOT NULL);")
        guard try verifyAudit() else { throw GatewayFailure(500, "audit_integrity", "网关审计链校验失败，请保留原文件并核查。") }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw GatewayFailure(500, "database_write", "网关持久化失败，未确认操作结果。") }
    }
    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw GatewayFailure(500, "database_query", "网关数据查询失败。") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            if let value { guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else { throw GatewayFailure(500, "database_binding", "网关参数写入失败。") } }
            else { sqlite3_bind_null(statement, Int32(offset + 1)) }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw GatewayFailure(500, "database_step", "网关数据操作失败。") }
            var row: [String] = []
            for index in 0..<sqlite3_column_count(statement) {
                row.append(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
            }
            result.append(row)
        }
    }
    func lookup(id: String) throws -> GatewayOperation? { try find("id", value: id) }
    func lookup(key: String) throws -> GatewayOperation? { try find("idem", value: key) }
    func lookup(business: String) throws -> GatewayOperation? { try find("business", value: business) }
    private func find(_ column: String, value: String) throws -> GatewayOperation? {
        guard let row = try rows("SELECT content FROM operations WHERE \(column)=?", [value]).first else { return nil }
        return try JSONDecoder().decode(GatewayOperation.self, from: Data(row[0].utf8))
    }
    func operations(limit: Int = 200) throws -> [GatewayOperation] {
        try rows("SELECT content FROM operations ORDER BY rowid DESC LIMIT ?", [String(limit)]).map { try JSONDecoder().decode(GatewayOperation.self, from: Data($0[0].utf8)) }
    }
    func active() throws -> [GatewayOperation] {
        // Do not limit worker recovery to the UI's 200 most recent records.
        try rows("SELECT content FROM operations").map { try JSONDecoder().decode(GatewayOperation.self, from: Data($0[0].utf8)) }.filter { $0.status.isInFlight }
    }
    func save(_ operation: GatewayOperation, business: String?, action: String) throws {
        let content = String(data: try GatewayHash.data(operation), encoding: .utf8)!
        try execute("BEGIN IMMEDIATE")
        do {
            _ = try rows("INSERT INTO operations(id,idem,business,content) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET business=excluded.business,content=excluded.content", [operation.id, operation.idempotencyKey, operation.status == .cancelled ? nil : business, content])
            let previous = try rows("SELECT digest FROM audit ORDER BY id DESC LIMIT 1").first?.first ?? ""
            let time = GatewayClock.string()
            let digest = try GatewayHash.digest([previous, operation.id, time, action])
            _ = try rows("INSERT INTO audit(operation,time,action,previous,digest) VALUES(?,?,?,?,?)", [operation.id, time, action, previous, digest])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func audit() throws -> [GatewayAuditEvent] {
        try rows("SELECT id,operation,time,action,digest FROM audit ORDER BY id DESC LIMIT 200").map {
            GatewayAuditEvent(id: Int($0[0]) ?? 0, operationID: $0[1], time: $0[2], action: $0[3], digest: $0[4])
        }
    }
    func verifyAudit() throws -> Bool {
        var previous = ""
        for row in try rows("SELECT operation,time,action,previous,digest FROM audit ORDER BY id") {
            guard row[3] == previous, row[4] == (try GatewayHash.digest([previous, row[0], row[1], row[2]])) else { return false }
            previous = row[4]
        }
        return true
    }
}
