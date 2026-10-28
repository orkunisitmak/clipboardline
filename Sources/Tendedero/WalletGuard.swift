import CryptoKit
import Foundation

/// Wallet Guard: local, network-free classification of copied text.
/// Shared behavior and vectors: contracts/wallet-guard.json. The Windows
/// counterpart is windows/lib/wallet-guard.cjs.
enum WalletGuardSecret: String, Equatable { case recoveryPhrase, privateKey }

enum WalletGuardClassification: Equatable {
    case none
    case secret(WalletGuardSecret, format: String)
    case address(chain: String, value: String)
}

enum WalletGuardAlert: Equatable {
    case hijack(original: String, replacement: String)
    case poisoning(address: String, similar: String)
}

struct WalletGuardVerdict: Equatable {
    var save = true
    var notice: WalletGuardSecret?
    var alert: WalletGuardAlert?
}

enum WalletGuardLimits {
    static let maximumInspectedCharacters = 16384
    static let maximumMnemonicRunWords = 48
    static let hijackWindow: TimeInterval = 3
    static let lookalikePrefix = 4
    static let lookalikeSuffix = 4
    static let historyAddresses = 200
    static let sessionAddresses = 32
}

enum WalletGuardClassifier {
    private static let wordIndex: [String: Int] = Dictionary(uniqueKeysWithValues: BIP39English.words.enumerated().map { ($1, $0) })
    private static let mnemonicLengths = [24, 21, 18, 15, 12]
    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base58Values: [Character: UInt32] = Dictionary(uniqueKeysWithValues: base58Alphabet.enumerated().map { ($1, UInt32($0)) })
    private static let curveOrder: [UInt8] = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    /// BIP32 private serializations: xprv, tprv, yprv, zprv, uprv, vprv, Yprv, Zprv.
    private static let extendedPrivate: Set<[UInt8]> = Set(["0488ade4", "04358394", "049d7878", "04b2430c", "044a4e28", "045f18bc", "0295b005", "02aa7a99"].map(hex))

    static func classify(_ text: String) -> WalletGuardClassification {
        guard text.utf16.count <= WalletGuardLimits.maximumInspectedCharacters else { return .none }
        let value = trimmed(text)
        guard !value.isEmpty else { return .none }
        if containsMnemonic(value) { return .secret(.recoveryPhrase, format: "bip39") }
        if let format = privateKeyFormat(value) { return .secret(.privateKey, format: format) }
        if let chain = addressChain(value) { return .address(chain: chain, value: value) }
        return .none
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    // MARK: BIP39

    /// Every 12-24 word window inside a bounded run of wordlist words, so a
    /// labelled backup note is caught while the checksum rejects arbitrary words.
    private static func containsMnemonic(_ text: String) -> Bool {
        var runs = [[Int]](), run = [Int]()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for raw in text.lowercased().components(separatedBy: separators) where !raw.isEmpty {
            var token = Substring(raw)
            // Backup layouts number the words; numbers are not words.
            let numbered = token.first == "#" ? token.dropFirst() : token
            let digits = numbered.prefix(while: { $0.isASCII && $0.isNumber }).prefix(2)
            if !digits.isEmpty { token = numbered.dropFirst(digits.count).drop(while: { ".):-".contains($0) }) }
            token = token.drop(while: { "(\"'[".contains($0) })
            while let last = token.last, ")\"'].:!?".contains(last) { token = token.dropLast() }
            guard !token.isEmpty else { continue }
            if let index = wordIndex[String(token)] { run.append(index) } else { if !run.isEmpty { runs.append(run) }; run = [] }
        }
        if !run.isEmpty { runs.append(run) }
        for run in runs where (12...WalletGuardLimits.maximumMnemonicRunWords).contains(run.count) {
            for length in mnemonicLengths where length <= run.count {
                for start in 0...(run.count - length) where validMnemonic(Array(run[start..<(start + length)])) { return true }
            }
        }
        return false
    }

    private static func validMnemonic(_ indices: [Int]) -> Bool {
        var bits = [Bool]()
        for index in indices { for shift in stride(from: 10, through: 0, by: -1) { bits.append((index >> shift) & 1 == 1) } }
        let checksumBits = bits.count / 33, entropyBits = bits.count - checksumBits
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        for bit in 0..<entropyBits where bits[bit] { entropy[bit / 8] |= 0x80 >> UInt8(bit % 8) }
        let digest = Array(SHA256.hash(data: entropy))
        for bit in 0..<checksumBits where ((digest[0] >> UInt8(7 - bit)) & 1 == 1) != bits[entropyBits + bit] { return false }
        return true
    }

    // MARK: Private keys

    private static func privateKeyFormat(_ value: String) -> String? {
        var body = Substring(value)
        if body.hasPrefix("0x") { body = body.dropFirst(2) }
        if body.count == 64, body.allSatisfy(isASCIIHex) { return validScalar(hex(String(body))) ? "hex" : nil }
        if value.hasPrefix("["), value.hasSuffix("]"), value.allSatisfy({ $0.isWhitespace || $0 == "," || $0 == "[" || $0 == "]" || ($0.isASCII && $0.isNumber) }) {
            let parts = value.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 64 else { return nil }
            var bytes = [UInt8]()
            for part in parts {
                guard (1...3).contains(part.count), let number = Int(part), number <= 255 else { return nil }
                bytes.append(UInt8(number))
            }
            return solanaKeypair(bytes) ? "solanaKeypair" : nil
        }
        guard (50...115).contains(value.count), value.allSatisfy({ base58Values[$0] != nil }) else { return nil }
        if let payload = base58Check(value) {
            if payload[0] == 0x80 || payload[0] == 0xef, payload.count == 33 || (payload.count == 34 && payload[33] == 1),
               validScalar(Array(payload[1..<33])) { return "wif" }
            if payload.count == 78, extendedPrivate.contains(Array(payload[0..<4])), payload[45] == 0,
               validScalar(Array(payload[46...])) { return "extendedKey" }
        }
        if (85...88).contains(value.count), let bytes = base58(value), solanaKeypair(bytes) { return "solanaKeypair" }
        return nil
    }

    private static func isASCIIHex(_ character: Character) -> Bool { character.isASCII && character.isHexDigit }

    private static func validScalar(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else { return false }
        return bytes.lexicographicallyPrecedes(curveOrder)
    }

    /// A Solana keypair is an Ed25519 seed followed by its own public key.
    /// Deriving the public half rejects 64-byte transaction signatures.
    private static func solanaKeypair(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 64, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes[0..<32]) else { return false }
        return Array(key.publicKey.rawRepresentation) == Array(bytes[32...])
    }

    // MARK: Encodings

    static func base58(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, text.count <= 160 else { return nil }
        var number = [UInt8]()   // little-endian base-256 digits
        for character in text {
            guard var carry = base58Values[character] else { return nil }
            for index in number.indices {
                carry += UInt32(number[index]) * 58
                number[index] = UInt8(carry & 0xff); carry >>= 8
            }
            while carry > 0 { number.append(UInt8(carry & 0xff)); carry >>= 8 }
        }
        let zeros = text.prefix(while: { $0 == "1" }).count
        return [UInt8](repeating: 0, count: zeros) + number.reversed()
    }

    private static func base58Check(_ text: String) -> [UInt8]? {
        guard let bytes = base58(text), bytes.count >= 5 else { return nil }
        let payload = Array(bytes.dropLast(4))
        let checksum = Array(SHA256.hash(data: Array(SHA256.hash(data: payload)))).prefix(4)
        return Array(checksum) == Array(bytes.suffix(4)) ? payload : nil
    }

    private static func hex(_ text: String) -> [UInt8] {
        var bytes = [UInt8](), characters = Array(text.utf8)
        if characters.count % 2 == 1 { characters.insert(UInt8(ascii: "0"), at: 0) }
        for index in stride(from: 0, to: characters.count, by: 2) {
            bytes.append(UInt8(String(decoding: characters[index..<(index + 2)], as: UTF8.self), radix: 16) ?? 0)
        }
        return bytes
    }

    // MARK: Addresses

    static func addressChain(_ value: String) -> String? {
        if evm(value) { return "evm" }
        let lower = value.lowercased()
        if lower.hasPrefix("bc1") || lower.hasPrefix("tb1") { return segwit(value) }
        guard (25...44).contains(value.count), value.allSatisfy({ base58Values[$0] != nil }) else { return nil }
        if let payload = base58Check(value), payload.count == 21 {
            switch payload[0] {
            case 0x00, 0x05: return "bitcoin"
            case 0x6f, 0xc4: return "bitcoin-testnet"
            case 0x41: return "tron"
            default: break
            }
        }
        return value.count >= 32 && base58(value)?.count == 32 ? "solana" : nil
    }

    private static func evm(_ value: String) -> Bool {
        guard value.count == 42, value.hasPrefix("0x") else { return false }
        let body = String(value.dropFirst(2))
        guard body.allSatisfy(isASCIIHex) else { return false }
        if body == body.lowercased() || body == body.uppercased() { return true }
        let hash = Keccak256.hash(Array(body.lowercased().utf8))
        for (index, character) in body.enumerated() where character.isLetter {
            let nibble = index % 2 == 0 ? hash[index / 2] >> 4 : hash[index / 2] & 0x0f
            if (nibble >= 8) != character.isUppercase { return false }
        }
        return true
    }

    private static let bech32Alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// BIP173 / BIP350 segwit addresses for bc and tb.
    private static func segwit(_ value: String) -> String? {
        guard value.count <= 90, value == value.lowercased() || value == value.uppercased() else { return nil }
        let text = value.lowercased()
        guard let separator = text.lastIndex(of: "1") else { return nil }
        let hrp = String(text[..<separator]), dataPart = text[text.index(after: separator)...]
        guard hrp == "bc" || hrp == "tb", dataPart.count >= 7 else { return nil }
        var data = [UInt8]()
        for character in dataPart {
            guard let index = bech32Alphabet.firstIndex(of: character) else { return nil }
            data.append(UInt8(index))
        }
        let expanded = hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 } + data
        let version = data[0]
        guard version <= 16, polymod(expanded) == (version == 0 ? 1 : 0x2bc830a3) else { return nil }
        var accumulator = 0, bits = 0, program = [UInt8]()
        for digit in data[1..<(data.count - 6)] {
            accumulator = ((accumulator << 5) | Int(digit)) & 0xfff; bits += 5
            if bits >= 8 { bits -= 8; program.append(UInt8((accumulator >> bits) & 0xff)) }
        }
        guard bits < 5, (accumulator << (8 - bits)) & 0xff == 0 else { return nil }
        guard (2...40).contains(program.count), version != 0 || program.count == 20 || program.count == 32 else { return nil }
        return hrp == "bc" ? "bitcoin" : "bitcoin-testnet"
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check: UInt32 = 1
        for value in values {
            let top = check >> 25
            check = ((check & 0x1ffffff) << 5) ^ UInt32(value)
            for bit in 0..<5 where (top >> UInt32(bit)) & 1 == 1 { check ^= generator[bit] }
        }
        return check
    }

    // MARK: Lookalike comparison

    /// Case-insensitive encodings compare in lower case; base58 is case-sensitive.
    static func comparable(chain: String, value: String) -> String {
        let lower = value.lowercased()
        return chain == "evm" || lower.hasPrefix("bc1") || lower.hasPrefix("tb1") ? lower : value
    }

    static func distinctive(chain: String, value: String) -> String {
        let value = comparable(chain: chain, value: value)
        if chain == "evm" { return String(value.dropFirst(2)) }
        if value.hasPrefix("bc1") || value.hasPrefix("tb1") { return String(value.dropFirst(4)) } // hrp, separator, witness version
        return chain == "solana" ? value : String(value.dropFirst()) // base58 version character
    }
}

/// EIP-55 needs Keccak-256 (the original padding, not NIST SHA3-256).
enum Keccak256 {
    private static let rounds: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A, 0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    private static let rotation = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var padded = input + [UInt8](repeating: 0, count: rate - input.count % rate)
        padded[input.count] ^= 0x01; padded[padded.count - 1] ^= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for offset in stride(from: 0, to: padded.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var word: UInt64 = 0
                for byte in 0..<8 { word |= UInt64(padded[offset + lane * 8 + byte]) << UInt64(8 * byte) }
                state[lane] ^= word
            }
            for round in rounds {
                var column = [UInt64](repeating: 0, count: 5)
                for x in 0..<5 { column[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] }
                for x in 0..<5 {
                    let delta = column[(x + 4) % 5] ^ rotate(column[(x + 1) % 5], 1)
                    for y in stride(from: 0, to: 25, by: 5) { state[x + y] ^= delta }
                }
                var moved = [UInt64](repeating: 0, count: 25)
                for x in 0..<5 { for y in 0..<5 { moved[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(state[x + 5 * y], rotation[x + 5 * y]) } }
                for y in stride(from: 0, to: 25, by: 5) {
                    for x in 0..<5 { state[x + y] = moved[x + y] ^ (~moved[(x + 1) % 5 + y] & moved[(x + 2) % 5 + y]) }
                }
                state[0] ^= round
            }
        }
        var output = [UInt8]()
        for lane in 0..<4 { for byte in 0..<8 { output.append(UInt8((state[lane] >> UInt64(8 * byte)) & 0xff)) } }
        return output
    }

    private static func rotate(_ value: UInt64, _ count: Int) -> UInt64 {
        count == 0 ? value : (value << UInt64(count)) | (value >> UInt64(64 - count))
    }
}

/// Stateful decisions for one clipboard watcher. Only public addresses are
/// remembered (in memory, bounded); secrets are classified and dropped.
@MainActor
final class WalletGuard {
    static let defaultsKey = "walletGuardEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private struct Seen { let chain: String; let value: String; let key: String; let at: TimeInterval; let context: String? }
    private let now: () -> TimeInterval
    private var last: Seen?
    private var session = [(chain: String, value: String)]()

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func reset() { last = nil; session = [] }

    /// Turning the setting off forgets the last copied address and the
    /// session list, so a later copy is never compared with them.
    func settingChanged(_ enabled: Bool) { if !enabled { reset() } }

    /// - Parameters:
    ///   - context: identity of the frontmost application, or nil when unknown.
    ///   - history: recent saved texts, newest first.
    func inspect(_ text: String, enabled: Bool = true, context: String?, history: () -> [String]) -> WalletGuardVerdict {
        guard enabled else { reset(); return WalletGuardVerdict() }
        let time = now()
        switch WalletGuardClassifier.classify(text) {
        case .secret(let kind, _):
            last = nil
            return WalletGuardVerdict(save: false, notice: kind, alert: nil)
        case .none:
            last = nil
            return WalletGuardVerdict()
        case .address(let chain, let value):
            let key = WalletGuardClassifier.comparable(chain: chain, value: value)
            var alert: WalletGuardAlert?
            if let previous = last, previous.chain == chain, previous.key != key,
               time - previous.at >= 0, time - previous.at <= WalletGuardLimits.hijackWindow + 0.000_000_1,
               previous.context == nil || context == nil || previous.context == context {
                alert = .hijack(original: previous.value, replacement: value)
            }
            if alert == nil, let similar = lookalike(chain: chain, value: value, key: key, history: history()) {
                alert = .poisoning(address: value, similar: similar)
            }
            last = Seen(chain: chain, value: value, key: key, at: time, context: context)
            session.removeAll { WalletGuardClassifier.comparable(chain: $0.chain, value: $0.value) == key }
            session.insert((chain, value), at: 0)
            if session.count > WalletGuardLimits.sessionAddresses { session.removeLast(session.count - WalletGuardLimits.sessionAddresses) }
            return WalletGuardVerdict(save: true, notice: nil, alert: alert)
        }
    }

    private func lookalike(chain: String, value: String, key: String, history: [String]) -> String? {
        let body = WalletGuardClassifier.distinctive(chain: chain, value: value)
        let prefix = WalletGuardLimits.lookalikePrefix, suffix = WalletGuardLimits.lookalikeSuffix
        let saved = history.prefix(WalletGuardLimits.historyAddresses).lazy.compactMap { text -> (chain: String, value: String)? in
            guard text.utf16.count <= 256 else { return nil }
            let value = WalletGuardClassifier.trimmed(text)
            return WalletGuardClassifier.addressChain(value).map { ($0, value) }
        }
        for candidate in session + Array(saved) where candidate.chain == chain {
            guard WalletGuardClassifier.comparable(chain: candidate.chain, value: candidate.value) != key else { continue }
            let other = WalletGuardClassifier.distinctive(chain: candidate.chain, value: candidate.value)
            if other.count == body.count, other.prefix(prefix) == body.prefix(prefix), other.suffix(suffix) == body.suffix(suffix) { return candidate.value }
        }
        return nil
    }
}
