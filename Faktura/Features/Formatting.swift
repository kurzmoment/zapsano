import Foundation
import FakturaCore

func money(_ amount: Decimal) -> String {
    amount.formatted(.currency(code: "CZK").locale(Locale(identifier: "cs_CZ")))
}
func unitRate(_ amount: Decimal) -> String {
    amount.formatted(.currency(code: "CZK").locale(Locale(identifier: "cs_CZ")).precision(.fractionLength(2...38)))
}
func decimalText(_ amount: Decimal) -> String {
    NSDecimalNumber(decimal: amount).stringValue.replacingOccurrences(of: ".", with: ",")
}
func dayText(_ day: CalendarDate) -> String { "\(day.day). \(day.month). \(day.year)" }
