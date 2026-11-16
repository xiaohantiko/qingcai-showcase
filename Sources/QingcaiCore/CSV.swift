import Foundation

public enum LedgerCSV {
    public static let headers = ["ID", "类型", "事项", "往来单位", "含税金额", "税率(%)", "凭证类型", "归属日期", "已结清", "结算日期", "到期日期", "分类", "可抵扣进项", "备注", "涉及现金"]
    public static func encode(_ entries: [LedgerEntry]) -> String {
        let rows = entries.map { e in [e.id.uuidString, e.kind.rawValue, e.title, e.counterparty, Money.raw(e.amount),
            Money.raw(e.vatRate), e.invoice.rawValue, ChinaDate.string(e.date), e.isSettled ? "是" : "否",
            ChinaDate.string(e.settlementDate), ChinaDate.string(e.dueDate), e.category, e.deductible ? "是" : "否", e.notes, e.affectsCash ? "是" : "否"] }
        return "\u{FEFF}" + ([headers] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
    }
    private static func escape(_ value: String) -> String {
        // 防止导出的文本被电子表格当成公式执行；导入时恢复前缀。
        let protected = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func decode(_ text: String) throws -> [LedgerEntry] {
        let rows = try parse(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard rows.first == headers else { throw FinanceError.invalid("CSV 表头不匹配。请先导出模板，再按原有列名填写。") }
        var result: [LedgerEntry] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            let line = offset + 2
            guard row.count == headers.count, let kind = EntryKind(rawValue: row[1]),
                  let amount = Money.parse(row[4]), let rate = Money.parse(row[5]), let invoice = InvoiceKind(rawValue: row[6]),
                  let date = ChinaDate.parse(row[7]), ["是", "否"].contains(row[8]),
                  let settlement = ChinaDate.parse(row[9]), let due = ChinaDate.parse(row[10]), ["是", "否"].contains(row[12]), ["是", "否"].contains(row[14]) else {
                throw FinanceError.invalid("CSV 第 \(line) 条记录格式有误。日期用 yyyy-MM-dd，金额用数字，是/否须填写完整。")
            }
            let id: UUID
            if row[0].isEmpty { id = UUID() }
            else if let parsed = UUID(uuidString: row[0]) { id = parsed }
            else { throw FinanceError.invalid("CSV 第 \(line) 条记录 ID 无效；新增记录可留空。") }
            let e = LedgerEntry(id: id, kind: kind, title: row[2], counterparty: row[3], amount: amount,
                vatRate: rate, invoice: invoice, date: date, isSettled: row[8] == "是", settlementDate: settlement,
                dueDate: due, category: row[11], deductible: row[12] == "是", notes: row[13], affectsCash: row[14] == "是")
            if let error = e.validationError { throw FinanceError.invalid("CSV 第 \(line) 条记录：\(error)") }
            result.append(e)
        }
        return result
    }
    public static func merge(_ incoming: [LedgerEntry], into existing: [LedgerEntry]) -> (entries: [LedgerEntry], added: Int, skipped: Int) {
        var entries = existing, ids = Set(existing.map(\.id)), keys = Set(existing.map(fingerprint)), skipped = 0
        for e in incoming {
            let key = fingerprint(e)
            if ids.contains(e.id) || keys.contains(key) { skipped += 1; continue }
            entries.append(e); ids.insert(e.id); keys.insert(key)
        }
        return (entries, entries.count - existing.count, skipped)
    }
    private static func fingerprint(_ e: LedgerEntry) -> String {
        // JSON 编码字段数组避免分隔符碰撞；忽略随机 ID 和附件。
        let fields = [e.kind.rawValue, e.title, e.counterparty, Money.raw(e.amount), Money.raw(e.vatRate),
            e.invoice.rawValue, ChinaDate.string(e.date), String(e.isSettled), ChinaDate.string(e.settlementDate),
            ChinaDate.string(e.dueDate), e.category, String(e.deductible), e.notes, String(e.affectsCash)]
        return String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
    }
    public static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text); var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, index = 0
        func finishField() {
            if field.hasPrefix("'"), field.count > 1,
               ["=", "+", "-", "@", "\t", "\r"].contains(String(field.dropFirst().prefix(1))) { field.removeFirst() }
            row.append(field); field = ""; closed = false
        }
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "\"" {
                guard field.isEmpty && !closed else { throw FinanceError.invalid("CSV 引号位置不正确。") }; quoted = true
            } else if c == "," { finishField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                finishField(); rows.append(row); row = []
                if c == "\r" && index + 1 < chars.count && chars[index + 1] == "\n" { index += 1 }
            } else {
                guard !closed else { throw FinanceError.invalid("CSV 引号结束后存在多余字符。") }; field.append(c)
            }
            index += 1
        }
        guard !quoted else { throw FinanceError.invalid("CSV 中有未闭合的引号。") }
        if !field.isEmpty || !row.isEmpty || closed { finishField(); rows.append(row) }
        return rows
    }
}
