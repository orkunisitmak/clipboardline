import Foundation

/// Banking apps and web forms often copy a bare card number or IBAN without a
/// password-manager marker. A copy that consists only of such a value never
/// enters history. Text that merely contains one stays exact and is admitted,
/// because long digit runs in prose are usually order or tracking numbers.
enum SensitiveText {
    static let cardDigitCount = 13...19
    static let ibanLength = 15...34
    private static let ibanCheckRemainder = 1
    private static let ibanModulus = 97

    static func isPaymentIdentifier(_ text: String) -> Bool {
        guard let compact = compact(text) else { return false }
        return isCardNumber(compact) || isIBAN(compact)
    }

    /// Removes the whitespace and hyphens used for grouping; nil if anything else separates characters.
    private static func compact(_ text: String) -> [Unicode.Scalar]? {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "-" }
        guard !scalars.isEmpty, scalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || digit($0) != nil) }) else { return nil }
        // ASCII-only at this point, so uppercasing cannot change the scalar count.
        return Array(String(String.UnicodeScalarView(scalars)).uppercased().unicodeScalars)
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        ("0"..."9").contains(scalar) ? Int(scalar.value - 48) : nil
    }

    private static func isCardNumber(_ scalars: [Unicode.Scalar]) -> Bool {
        let digits = scalars.compactMap(digit)
        guard digits.count == scalars.count, cardDigitCount.contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, entry in
            guard entry.offset % 2 == 1 else { return total + entry.element }
            let doubled = entry.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    private static func isIBAN(_ scalars: [Unicode.Scalar]) -> Bool {
        guard ibanLength.contains(scalars.count),
              scalars[0...1].allSatisfy({ ("A"..."Z").contains($0) }),
              scalars[2...3].allSatisfy({ digit($0) != nil }) else { return false }
        // ISO 13616: move the country and check digits to the end, map A=10…Z=35, then mod 97.
        var remainder = 0
        for scalar in scalars[4...] + scalars[0..<4] {
            let value = digit(scalar) ?? Int(scalar.value - 55)
            remainder = (remainder * (value > 9 ? 100 : 10) + value) % ibanModulus
        }
        return remainder == ibanCheckRemainder
    }
}
