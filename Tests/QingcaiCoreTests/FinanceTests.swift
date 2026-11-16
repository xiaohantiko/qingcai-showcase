import Foundation
import QingcaiCore

final class FinanceTests {
    let date = ChinaDate.make(2026, 10, 10)
    var quarter: TaxPeriod { .init(year: 2026, index: 4, cycle: .quarterly) }
    func companyDocument() -> FinanceDocument { var d = FinanceDocument(); d.company.setupConfirmed = true; return d }
    func revenue(_ amount: Decimal, invoice: InvoiceKind = .ordinary, settled: Bool = true, rate: Decimal = 1) -> LedgerEntry {
        LedgerEntry(title: "技术服务", counterparty: "测试客户", amount: amount, vatRate: rate, invoice: invoice, date: date, isSettled: settled, settlementDate: date)
    }
    func testMoneyUsesDecimalAndRejectsMalformedAmounts() {
        XCTAssertEqual(Money.rounded(Decimal(string: "0.105")!), Decimal(string: "0.11")!)
        XCTAssertEqual(Money.parse("123.45"), Decimal(string: "123.45")!)
        for invalid in ["1.001", "NaN", "1e8", "12,000", "", "1000000000001"] { XCTAssertNil(Money.parse(invalid)) }
    }
    func testUnpaidOrdinarySalesBelowThresholdAreExempt() {
        var d = companyDocument(); d.entries = [revenue(101_000, settled: false)]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.sales, 100_000); XCTAssertEqual(r.vat, 0); XCTAssertTrue(r.belowThreshold)
    }
    func testSpecialInvoiceRemainsTaxableBelowThreshold() {
        var d = companyDocument(); d.entries = [revenue(10_100, invoice: .special), revenue(20_200)]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.vat, 100); XCTAssertEqual(r.cityTax, Decimal(string: "3.5")!); XCTAssertEqual(r.education, 0)
    }
    func testExact2026ThresholdIsTaxableWhileEducationIncludesBoundary() {
        var d = companyDocument(); d.entries = [revenue(303_000)]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.sales, 300_000); XCTAssertFalse(r.belowThreshold); XCTAssertEqual(r.vat, 3_000)
        XCTAssertEqual(r.cityTax, 105); XCTAssertEqual(r.education, 0)
    }
    func testAboveThresholdAllSalesTaxedAndSurchargesReduced() {
        var d = companyDocument(); d.entries = [revenue(404_000)]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.vat, 4_000); XCTAssertEqual(r.cityTax, 140); XCTAssertEqual(r.education, 60); XCTAssertEqual(r.localEducation, 40)
    }
    func testMonthlyThresholdAndYearRollover() {
        var d = companyDocument(); d.company.cycle = .monthly; d.entries = [revenue(101_000)]
        let period = TaxPeriod(date: date, cycle: .monthly)
        XCTAssertEqual(TaxEngine.estimate(document: d, period: period).vat, 1_000)
        XCTAssertEqual(TaxPeriod(year: 2026, index: 4, cycle: .quarterly).shifted(1).id, "2027-Q1")
        XCTAssertEqual(TaxPeriod(year: 2026, index: 1, cycle: .monthly).shifted(-1).id, "2025-M12")
    }
    func testVATUsesRecognitionDateInsteadOfCashDate() {
        var d = companyDocument(); var e = revenue(404_000); e.settlementDate = ChinaDate.make(2027, 1, 10); d.entries = [e]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).vat, 4_000)
        e.date = ChinaDate.make(2027, 1, 10); d.entries = [e]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).vat, 0)
    }
    func testGeneralVATDeductionAndCarryForward() {
        var d = companyDocument(); d.company.taxpayer = .general
        d.entries = [revenue(106_000, rate: 6), LedgerEntry(kind: .expense, title: "采购", amount: 226_000, vatRate: 13, invoice: .special, date: date, deductible: true)]
        var f = FilingRecord(id: quarter.id); f.carriedInputVAT = 2_000; d.filings = [f]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.outputVAT, 6_000); XCTAssertEqual(r.inputVAT, 26_000); XCTAssertEqual(r.vat, 0); XCTAssertEqual(r.carryForward, 22_000)
    }
    func testOrdinaryExpenseDoesNotCreateInputCredit() {
        var d = companyDocument(); d.company.taxpayer = .general
        d.entries = [revenue(106_000, rate: 6), LedgerEntry(kind: .expense, title: "采购", amount: 113_000, vatRate: 13, invoice: .ordinary, date: date)]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).inputVAT, 0)
    }
    func testIncomeTaxIsYTDWithExplicitAdjustmentsAndPrepayments() {
        var d = companyDocument(); d.company.smallProfitEligible = true
        var old = revenue(101_000); old.date = ChinaDate.make(2026, 2, 1)
        d.entries = [old, revenue(101_000), LedgerEntry(kind: .expense, title: "运营", amount: 10_000, vatRate: 0, date: date)]
        var f = FilingRecord(id: quarter.id); f.adjustment = 10_000; f.prepaidIncomeTax = 3_000; d.filings = [f]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.ytdProfit, 200_000); XCTAssertEqual(r.effectiveIncomeRate, 5); XCTAssertEqual(r.incomeTax, 7_000)
    }
    func testPreferentialIncomeRateNeedsEligibilityAndCapsAtThreeMillion() {
        var d = companyDocument(); d.entries = [revenue(101_000)]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).incomeTax, 25_000)
        d.company.smallProfitEligible = true; d.entries = [revenue(4_040_000)]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).effectiveIncomeRate, 25)
    }
    func testTaxPolicyExpiresInsteadOfSilentlyUsingOldRates() {
        let r = TaxEngine.estimate(document: companyDocument(), period: TaxPeriod(year: 2028, index: 1, cycle: .quarterly))
        XCTAssertFalse(r.valid); XCTAssertEqual(r.vat, 0)
    }
    func testUnconfiguredCompanyAndUnsupportedRateBlockConfirmation() {
        XCTAssertFalse(TaxEngine.estimate(document: FinanceDocument(), period: quarter).valid)
        var d = companyDocument(); d.entries = [revenue(106_000, rate: 6)]
        XCTAssertFalse(TaxEngine.estimate(document: d, period: quarter).valid)
    }
    func testAssetPurchaseIsNotExpensedWhileDepreciationIs() {
        var d = companyDocument(); d.entries = [revenue(101_000), LedgerEntry(kind: .expense, title: "电脑购置", amount: 10_000, vatRate: 0, date: date, category: "固定资产购置"),
            LedgerEntry(kind: .expense, title: "电脑折旧", amount: 300, vatRate: 0, date: date, isSettled: false, category: "资产折旧", affectsCash: false)]
        XCTAssertEqual(TaxEngine.estimate(document: d, period: quarter).ytdProfit, 99_700)
    }
    func testCSVPreservesQuotesChineseNewlinesAndFormulaText() throws {
        var entry = revenue(10_100); entry.title = "=客户\"项目\",一"; entry.notes = "第一行\r\n第二行"; entry.affectsCash = false
        let text = LedgerCSV.encode([entry]); XCTAssertTrue(text.contains("'=客户"))
        let result = try LedgerCSV.decode(text)
        XCTAssertEqual(result[0].title, entry.title); XCTAssertEqual(result[0].notes, entry.notes); XCTAssertFalse(result[0].affectsCash)
        XCTAssertEqual(result[0].amount, entry.amount)
    }
    func testCSVRejectsBadDatesAndUnclosedQuotes() {
        XCTAssertNil(ChinaDate.parse("2026-02-30"))
        XCTAssertThrowsError(try LedgerCSV.parse("\"未闭合"))
        XCTAssertThrowsError(try LedgerCSV.decode("日期,金额\n2026-10-10,10"))
    }
    func testRepeatedCSVImportSkipsBothIDsAndIdenticalContent() {
        let e = revenue(101_000); var duplicate = e; duplicate.id = UUID()
        let result = LedgerCSV.merge([e, duplicate], into: [e])
        XCTAssertEqual(result.added, 0); XCTAssertEqual(result.skipped, 2)
    }
    func testJournalRejectsUnbalancedOrTwoSidedRows() {
        XCTAssertNil(JournalVoucher(date: date, summary: "服务费", lines: [.init(account: "1002", debit: 100), .init(account: "6001", credit: 100)]).validationError)
        XCTAssertNotNil(JournalVoucher(date: date, summary: "不平", lines: [.init(account: "1002", debit: 100), .init(account: "6001", credit: 99)]).validationError)
        XCTAssertNotNil(JournalVoucher(date: date, summary: "双边", lines: [.init(account: "1002", debit: 100, credit: 100), .init(account: "6001", credit: 1)]).validationError)
    }
    func testPayrollDoesNotConfuseNetPayAndEmployerCost() {
        let p = PayrollRecord(employee: "员工", month: date, gross: 15_000, personalInsurance: 1_700, incomeTax: 400, employerInsurance: 3_800)
        XCTAssertEqual(p.net, 12_900); XCTAssertEqual(p.cost, 18_800); XCTAssertNil(p.validationError)
    }
    func testDepreciationStartsFollowingMonthAndFinalMonthCatchesRounding() {
        let asset = FixedAsset(name: "设备", cost: 1_000, residualPercent: 0, lifeMonths: 3, purchaseDate: ChinaDate.make(2026, 9, 20))
        XCTAssertEqual(asset.depreciation(for: ChinaDate.make(2026, 9)), 0)
        XCTAssertEqual(asset.depreciation(for: date), Decimal(string: "333.33")!)
        XCTAssertEqual(asset.depreciation(for: ChinaDate.make(2026, 12)), Decimal(string: "333.34")!)
        XCTAssertEqual(asset.depreciation(for: ChinaDate.make(2027, 1)), 0)
    }
    func testBankImportAndExactMatching() throws {
        let rows = try BankLine.decode(BankLine.template); XCTAssertEqual(rows.count, 1)
        var e = revenue(10_100); e.settlementDate = ChinaDate.make(2026, 10, 26)
        XCTAssertTrue(rows[0].matches(e)); e.isSettled = false; XCTAssertFalse(rows[0].matches(e))
        XCTAssertThrowsError(try BankLine.decode("日期,摘要,收入,支出,流水号\n2026-10-26,错误,100,100,1"))
    }
    func testRepositoryRoundTripHistoryAndCorruptFileProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FinanceRepository(directory: root)
        var d = companyDocument(); d.entries = [revenue(101_000)]
        try repo.save(d); XCTAssertEqual(try repo.load(), d)
        d.company.name = "更正名称"; try repo.save(d)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("History").path).count, 1)
        try Data("损坏的数据".utf8).write(to: repo.file); XCTAssertThrowsError(try repo.load())
    }
    func testSnapshotIncludesAttachmentsAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FinanceRepository(directory: root.appendingPathComponent("source"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("test.pdf"); try Data("%PDF-1.4 test".utf8).write(to: pdf)
        var d = companyDocument(); var e = revenue(101_000); e.attachment = try repo.addAttachment(from: pdf); d.entries = [e]
        let backup = root.appendingPathComponent("backup"); try repo.exportSnapshot(d, to: backup)
        let restored = FinanceRepository(directory: root.appendingPathComponent("restored")); try restored.importAttachments(for: d, from: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.attachments.appendingPathComponent(e.attachment!).path))
        d.entries[0].attachment = "../../private.pdf"; XCTAssertThrowsError(try d.validated())
    }
    func testDocumentRejectsDanglingReferencesAndDuplicateIDs() {
        var d = companyDocument(); let e = revenue(10_100); d.entries = [e, e]; XCTAssertThrowsError(try d.validated())
        d.entries = []; var p = PayrollRecord(employee: "测试", month: date, gross: 1_000, personalInsurance: 0, incomeTax: 0, employerInsurance: 0); p.entryID = UUID(); d.payrolls = [p]
        XCTAssertThrowsError(try d.validated())
    }
    func testCapitalAndLoanPrincipalNeverBecomeTaxableBusinessRevenue() {
        var d = companyDocument(); var capital = revenue(500_000, rate: 0); capital.category = "股东出资"
        var loan = revenue(800_000, rate: 0); loan.category = "借款到账"
        let repayment = LedgerEntry(kind: .expense, title: "归还本金", amount: 100_000, vatRate: 0, date: date, category: "借款归还")
        d.entries = [revenue(101_000), capital, loan, repayment]
        let r = TaxEngine.estimate(document: d, period: quarter)
        XCTAssertEqual(r.sales, 100_000); XCTAssertEqual(r.vat, 0); XCTAssertEqual(r.ytdProfit, 100_000)
    }
    func testFinancingCannotCarryVATOrInputCredit() {
        var e = revenue(10_100); e.category = "股东出资"; XCTAssertNotNil(e.validationError)
        e.vatRate = 0; XCTAssertNil(e.validationError)
    }
    func testClaimSettlementStaysConsistentWithLinkedLedger() throws {
        var d = companyDocument()
        var e = LedgerEntry(kind: .expense, title: "差旅报销", amount: 500, vatRate: 0, date: date, isSettled: false)
        var claim = ExpenseClaim(employee: "员工", purpose: "差旅报销", amount: 500, date: date)
        claim.entryID = e.id; claim.status = .approved; d.entries = [e]; d.claims = [claim]
        e.isSettled = true; try LedgerMutation.upsert(e, in: &d); XCTAssertEqual(d.claims[0].status, .paid)
        e.isSettled = false; try LedgerMutation.upsert(e, in: &d); XCTAssertEqual(d.claims[0].status, .approved)
        e.amount = 600; XCTAssertThrowsError(try LedgerMutation.upsert(e, in: &d))
    }
    func testBankMatchedLedgerCannotBeChangedBeforeUnlinking() {
        var d = companyDocument(); var e = revenue(10_100); d.entries = [e]
        var bank = BankLine(id: "test", date: date, summary: "收款", kind: .income, amount: 10_100)
        bank.entryID = e.id; d.bankLines = [bank]; e.amount = 20_200
        XCTAssertThrowsError(try LedgerMutation.upsert(e, in: &d)); XCTAssertEqual(d.entries[0].amount, 10_100)
    }
}

// A dependency-free assertion runner also works with Apple's Command Line Tools,
// where XCTest is not shipped. Each named case below is executed on CI and locally.
private var checkFailures = 0
func check(_ condition: Bool, _ text: String, file: StaticString, line: UInt) {
    if !condition { checkFailures += 1; print("FAIL \(file):\(line) \(text)") }
}
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { check(lhs == rhs, "\(lhs) != \(rhs)", file: file, line: line) }
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { check(value, "expected true", file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { check(!value, "expected false", file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value == nil, "expected nil", file: file, line: line) }
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value != nil, "expected non-nil", file: file, line: line) }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); check(false, "expected an error", file: file, line: line) } catch {}
}

@main struct RunFinanceChecks {
    static func main() async {
        let suite = FinanceTests()
        let cases: [(String, () throws -> Void)] = [
            ("testMoneyUsesDecimalAndRejectsMalformedAmounts", suite.testMoneyUsesDecimalAndRejectsMalformedAmounts),
            ("testUnpaidOrdinarySalesBelowThresholdAreExempt", suite.testUnpaidOrdinarySalesBelowThresholdAreExempt),
            ("testSpecialInvoiceRemainsTaxableBelowThreshold", suite.testSpecialInvoiceRemainsTaxableBelowThreshold),
            ("testExact2026ThresholdIsTaxableWhileEducationIncludesBoundary", suite.testExact2026ThresholdIsTaxableWhileEducationIncludesBoundary),
            ("testAboveThresholdAllSalesTaxedAndSurchargesReduced", suite.testAboveThresholdAllSalesTaxedAndSurchargesReduced),
            ("testMonthlyThresholdAndYearRollover", suite.testMonthlyThresholdAndYearRollover),
            ("testVATUsesRecognitionDateInsteadOfCashDate", suite.testVATUsesRecognitionDateInsteadOfCashDate),
            ("testGeneralVATDeductionAndCarryForward", suite.testGeneralVATDeductionAndCarryForward),
            ("testOrdinaryExpenseDoesNotCreateInputCredit", suite.testOrdinaryExpenseDoesNotCreateInputCredit),
            ("testIncomeTaxIsYTDWithExplicitAdjustmentsAndPrepayments", suite.testIncomeTaxIsYTDWithExplicitAdjustmentsAndPrepayments),
            ("testPreferentialIncomeRateNeedsEligibilityAndCapsAtThreeMillion", suite.testPreferentialIncomeRateNeedsEligibilityAndCapsAtThreeMillion),
            ("testTaxPolicyExpiresInsteadOfSilentlyUsingOldRates", suite.testTaxPolicyExpiresInsteadOfSilentlyUsingOldRates),
            ("testUnconfiguredCompanyAndUnsupportedRateBlockConfirmation", suite.testUnconfiguredCompanyAndUnsupportedRateBlockConfirmation),
            ("testAssetPurchaseIsNotExpensedWhileDepreciationIs", suite.testAssetPurchaseIsNotExpensedWhileDepreciationIs),
            ("testCSVPreservesQuotesChineseNewlinesAndFormulaText", suite.testCSVPreservesQuotesChineseNewlinesAndFormulaText),
            ("testCSVRejectsBadDatesAndUnclosedQuotes", suite.testCSVRejectsBadDatesAndUnclosedQuotes),
            ("testRepeatedCSVImportSkipsBothIDsAndIdenticalContent", suite.testRepeatedCSVImportSkipsBothIDsAndIdenticalContent),
            ("testJournalRejectsUnbalancedOrTwoSidedRows", suite.testJournalRejectsUnbalancedOrTwoSidedRows),
            ("testPayrollDoesNotConfuseNetPayAndEmployerCost", suite.testPayrollDoesNotConfuseNetPayAndEmployerCost),
            ("testDepreciationStartsFollowingMonthAndFinalMonthCatchesRounding", suite.testDepreciationStartsFollowingMonthAndFinalMonthCatchesRounding),
            ("testBankImportAndExactMatching", suite.testBankImportAndExactMatching),
            ("testRepositoryRoundTripHistoryAndCorruptFileProtection", suite.testRepositoryRoundTripHistoryAndCorruptFileProtection),
            ("testSnapshotIncludesAttachmentsAndRejectsTraversal", suite.testSnapshotIncludesAttachmentsAndRejectsTraversal),
            ("testDocumentRejectsDanglingReferencesAndDuplicateIDs", suite.testDocumentRejectsDanglingReferencesAndDuplicateIDs),
            ("testCapitalAndLoanPrincipalNeverBecomeTaxableBusinessRevenue", suite.testCapitalAndLoanPrincipalNeverBecomeTaxableBusinessRevenue),
            ("testFinancingCannotCarryVATOrInputCredit", suite.testFinancingCannotCarryVATOrInputCredit),
            ("testClaimSettlementStaysConsistentWithLinkedLedger", suite.testClaimSettlementStaysConsistentWithLinkedLedger),
            ("testBankMatchedLedgerCannotBeChangedBeforeUnlinking", suite.testBankMatchedLedgerCannotBeChangedBeforeUnlinking)
        ]
        for (name, run) in cases {
            let before = checkFailures
            do { try run() } catch { checkFailures += 1; print("FAIL \(name): \(error)") }
            print("\(checkFailures == before ? "PASS" : "FAIL") \(name)")
        }
        let gateway = await runGatewayChecks()
        checkFailures += gateway.failures
        print("\(cases.count + gateway.count) cases, \(checkFailures) failures")
        if checkFailures > 0 { exit(1) }
    }
}
