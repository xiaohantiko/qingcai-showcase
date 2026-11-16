import Foundation

public struct TaxEstimate {
    public var sales: Decimal = 0
    public var outputVAT: Decimal = 0
    public var inputVAT: Decimal = 0
    public var vat: Decimal = 0
    public var carryForward: Decimal = 0
    public var cityTax: Decimal = 0
    public var education: Decimal = 0
    public var localEducation: Decimal = 0
    public var ytdProfit: Decimal = 0
    public var incomeTax: Decimal = 0
    public var effectiveIncomeRate: Decimal = 25
    public var warnings: [String] = []
    public var belowThreshold = false
    public var valid = true
    public var surcharges: Decimal { cityTax + education + localEducation }
    public var vatAndSurcharges: Decimal { vat + surcharges }
}

public enum TaxEngine {
    /// 常规境内业务测算，不支持不动产、差额计税、出口或特殊行业。
    public static func estimate(document: FinanceDocument, period: TaxPeriod) -> TaxEstimate {
        var r = TaxEstimate()
        let company = document.company
        let entries = document.entries.filter { period.contains($0.date) }
        let income = entries.filter(\.isBusinessRevenue)
        let expenses = entries.filter { $0.kind == .expense && !LedgerEntry.nonOperatingCategories.contains($0.category) }
        let filing = document.filings.first { $0.id == period.id } ?? FilingRecord(id: period.id)
        r.sales = income.reduce(0) { $0 + $1.net }
        r.outputVAT = Money.rounded(income.reduce(0) { $0 + $1.vat })
        r.belowThreshold = r.sales < period.threshold
        if !company.setupConfirmed {
            r.valid = false; r.warnings.append("公司资料及税务参数尚未确认，结果仅供试算。")
        }
        if !period.supportsPolicy {
            r.valid = false; r.warnings.append("当前政策包仅适用于 2026–2027 年；该期间已停止输出税额。")
            return r
        }
        if company.taxpayer == .small {
            // 2026 年起为起征点，严格“未达到”；专票视为放弃对应交易免税。
            r.vat = Money.rounded(income.filter { !r.belowThreshold || $0.invoice == .special }.reduce(0) { $0 + $1.vat })
            if income.contains(where: { ![Decimal(0), 1, 3].contains($0.vatRate) }) {
                r.valid = false; r.warnings.append("小规模收入含非常规征收率，请确认身份及业务类型。")
            }
            if income.contains(where: { $0.vatRate == 0 }) {
                r.valid = false; r.warnings.append("存在 0% 收入；免税、零税率或特殊业务需另行复核，不能直接等同起征点免税。")
            }
        } else {
            r.inputVAT = Money.rounded(expenses.filter { $0.deductible && $0.invoice == .special }.reduce(0) { $0 + $1.vat })
            let difference = r.outputVAT - r.inputVAT - filing.carriedInputVAT
            r.vat = max(0, difference); r.carryForward = max(0, -difference)
        }
        let reduction: Decimal = company.sixTaxEligible ? Decimal(string: "0.5")! : 1
        r.cityTax = Money.rounded(r.vat * company.cityRate / 100 * reduction)
        // 财税〔2016〕12号：教育附加的销售额界限包含本数，与2026增值税起征点区分。
        if r.sales > period.threshold {
            r.education = Money.rounded(r.vat * Decimal(string: "0.03")! * reduction)
            r.localEducation = Money.rounded(r.vat * Decimal(string: "0.02")! * reduction)
        }
        let ytd = document.entries.filter { $0.date >= period.yearStart && $0.date < period.end }
        r.ytdProfit = ytd.reduce(0) { sum, entry in
            if entry.isBusinessRevenue {
                // 小规模未达起征点免税转入利润、附加税扣除等需在纳税调整中单独反映。
                return sum + entry.net
            }
            if !entry.isProfitExpense { return sum }
            let cost = company.taxpayer == .general && entry.deductible && entry.invoice == .special ? entry.net : entry.amount
            return sum - cost
        }
        r.ytdProfit = Money.rounded(r.ytdProfit + filing.adjustment)
        r.effectiveIncomeRate = company.smallProfitEligible && r.ytdProfit <= 3_000_000 ? 5 : 25
        r.incomeTax = max(0, Money.rounded(max(0, r.ytdProfit) * r.effectiveIncomeRate / 100) - filing.prepaidIncomeTax)
        if company.smallProfitEligible && r.ytdProfit > 3_000_000 {
            r.warnings.append("累计应纳税所得额超过 300 万元，试算已改用 25%；请复核优惠资格。")
        }
        r.warnings.append("所得税按年累计利润与手工纳税调整估算，需补齐以前期间账目、免税转入收益、附加税扣除、折旧、不得扣除支出等；已预缴金额必须手工核对。")
        if entries.contains(where: { $0.invoice == .none }) { r.warnings.append("本期存在待补凭证的账目；已计入试算，需复核税前扣除。") }
        if company.cycle == .monthly { r.warnings.append("增值税按月展示；企业所得税栏为截至本月的年累计测算，不能当作月度申报应缴款。") }
        return r
    }
}

public enum PolicySources {
    public static let checked = "2026-10-26"
    public static let links: [(String, String)] = [
        ("2026 年第 10 号 · 起征点与 1% 优惠", "https://fgk.chinatax.gov.cn/zcfgk/c102416/c5247434/content.html"),
        ("2026 年第 4 号 · 专票与放弃免税", "https://zhejiang.chinatax.gov.cn/art/2026/2/2/art_8409_84409.html"),
        ("增值税法 · 2026 年起施行", "https://fgk.chinatax.gov.cn/zcfgk/c100009/c5237365/content.html"),
        ("小型微利企业 · 所得税优惠条件", "https://www.chinatax.gov.cn/chinatax/n810356/n3010387/c5220435/content.html"),
        ("六税两费 · 减半征收", "https://www.chinatax.gov.cn/chinatax/n810356/n3010387/c5211123/content.html"),
        ("教育费附加 · 10 万 / 30 万界限", "https://tianjin.chinatax.gov.cn/11200000000/0300/030005/20220422172919377.shtml")
    ]
}
