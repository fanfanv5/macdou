import Foundation

struct SMSMessage: Equatable {
    var index: Int
    var sender: String
    var timestamp: String
    var body: String
    var reference: Int? = nil
    var part = 1
    var total = 1
    var coding = 0
}

enum SMSDecoder {
    enum Invalid: Error { case malformed, unsupported }
    static let alphabet = Array("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
    static let extended: [Int: String] = [10:"\u{0C}",20:"^",40:"{",41:"}",47:"\\",60:"[",61:"~",62:"]",64:"|",101:"€"]
    static func gsm(_ bytes: [UInt8], count: Int, bitOffset: Int = 0) throws -> String {
        guard count >= 0, bitOffset >= 0, bitOffset + count * 7 <= bytes.count * 8 else { throw Invalid.malformed }
        var result = "", escape = false
        for i in 0..<count {
            let bit = bitOffset + i * 7, byte = bit / 8, shift = bit % 8
            let word = Int(bytes[byte]) | (byte + 1 < bytes.count ? Int(bytes[byte + 1]) << 8 : 0)
            let value = (word >> shift) & 127
            if escape { result += extended[value] ?? " "; escape = false }
            else if value == 27 { escape = true }
            else { result.append(alphabet[value]) }
        }
        if escape { result += " " }; return result
    }
    static func decode(_ hex: String, index: Int) throws -> SMSMessage {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0, chars.count <= 1024 else { throw Invalid.malformed }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let value = UInt8(String(decoding: chars[i...i+1], as: UTF8.self), radix: 16) else { throw Invalid.malformed }
            bytes.append(value)
        }
        var cursor = 0
        func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, cursor + count <= bytes.count else { throw Invalid.malformed }
            defer { cursor += count }; return Array(bytes[cursor..<cursor+count])
        }
        func byte() throws -> Int { Int(try take(1)[0]) }
        let smsc = try byte(); _ = try take(smsc)
        let first = try byte(); guard first & 3 == 0 else { throw Invalid.unsupported }
        let addressLength = try byte(), addressType = try byte()
        guard addressLength > 0, addressLength <= 24 else { throw Invalid.malformed }
        let address = try take((addressLength + 1) / 2)
        let sender: String
        if addressType & 0x70 == 0x50 { sender = try gsm(address, count: addressLength * 4 / 7) }
        else {
            let digits = Array("0123456789*#abc")
            let nibbles = address.flatMap { [Int($0 & 15), Int($0 >> 4)] }.prefix(addressLength)
            guard nibbles.allSatisfy({ $0 < 15 }) else { throw Invalid.malformed }
            sender = (addressType & 0x70 == 0x10 ? "+" : "") + String(nibbles.map { digits[$0] })
        }
        _ = try byte(); let dcs = try byte(), stamp = try take(7)
        func decimal(_ value: UInt8) throws -> Int {
            guard value & 15 <= 9, value >> 4 <= 9 else { throw Invalid.malformed }
            return Int(value & 15) * 10 + Int(value >> 4)
        }
        let time = try stamp.prefix(6).map(decimal)
        guard (1...12).contains(time[1]), (1...31).contains(time[2]), time[3] < 24, time[4] < 60, time[5] < 60 else { throw Invalid.malformed }
        let quarters = try decimal(stamp[6] & 0xF7)
        guard quarters <= 56 else { throw Invalid.malformed }
        let timestamp = String(format:"%04d-%02d-%02d %02d:%02d:%02d %@%02d:%02d", 2000 + time[0], time[1], time[2], time[3], time[4], time[5], stamp[6] & 8 == 0 ? "+" : "-", quarters / 4, quarters % 4 * 15)
        let coding: Int
        if dcs < 128 && dcs & 32 == 0 { coding = (dcs >> 2) & 3 }
        else if dcs & 0xF0 == 0xE0 { coding = 2 }
        else if dcs & 0xE0 == 0xC0 { coding = 0 }
        else if dcs & 0xF0 == 0xF0 { coding = dcs & 4 == 0 ? 0 : 1 }
        else { throw Invalid.unsupported }
        let length = try byte()
        guard length <= (coding == 0 ? 160 : 140) else { throw Invalid.malformed }
        let data = try take(coding == 0 ? (length * 7 + 7) / 8 : length)
        var headerBytes = 0, reference: Int?, part = 1, total = 1
        if first & 64 != 0 {
            guard let head = data.first else { throw Invalid.malformed }
            headerBytes = Int(head) + 1; guard headerBytes <= data.count else { throw Invalid.malformed }
            var i = 1
            while i < headerBytes {
                guard i + 2 <= headerBytes else { throw Invalid.malformed }
                let type = data[i], size = Int(data[i + 1]); i += 2
                guard i + size <= headerBytes else { throw Invalid.malformed }
                if type == 0 && size == 3 { reference = Int(data[i]); total = Int(data[i+1]); part = Int(data[i+2]) }
                if type == 8 && size == 4 { reference = 65536 + Int(data[i]) * 256 + Int(data[i+1]); total = Int(data[i+2]); part = Int(data[i+3]) }
                // Do not silently misdecode binary ports or national-language shift tables.
                if [4,5,0x24,0x25].contains(type) { throw Invalid.unsupported }
                i += size
            }
            guard total > 0, part > 0, part <= total else { throw Invalid.malformed }
        }
        let body: String
        if coding == 0 {
            let skip = (headerBytes * 8 + 6) / 7
            body = try gsm(data, count: length - skip, bitOffset: skip * 7)
        } else if coding == 2 {
            let content = Data(data.dropFirst(headerBytes))
            guard content.count % 2 == 0, let decoded = String(data: content, encoding: .utf16BigEndian) else { throw Invalid.malformed }
            body = decoded
        } else { throw Invalid.unsupported }
        return SMSMessage(index: index, sender: sender, timestamp: timestamp, body: body,
            reference: reference, part: part, total: total, coding: dcs)
    }
    static func parse(_ response: String) -> [SMSMessage] {
        let lines = response.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var messages: [SMSMessage] = []
        for i in lines.indices where lines[i].hasPrefix("+CMGL:") {
            let fields = lines[i].dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let index = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                let status = Int(fields[1].trimmingCharacters(in: .whitespaces)), status == 0 || status == 1 else { continue }
            do {
                guard i + 1 < lines.count else { throw Invalid.malformed }
                messages.append(try decode(lines[i+1].trimmingCharacters(in: .whitespaces), index: index))
            } catch {
                messages.append(SMSMessage(index:index, sender:"无法解码的短信", timestamp:"", body:"该短信格式不受支持或数据不完整；原短信仍保留在模块中。"))
            }
        }
        return assemble(messages)
    }
    static func assemble(_ messages: [SMSMessage]) -> [SMSMessage] {
        var result = messages.filter { $0.reference == nil }
        let groups = Dictionary(grouping: messages.filter { $0.reference != nil }) {
            "\($0.sender)|\($0.reference!)|\($0.total)|\($0.coding)|\($0.timestamp.prefix(13))"
        }
        for parts in groups.values {
            let ordered = parts.sorted { $0.part < $1.part }
            if Set(parts.map(\.part)).count != parts.count {
                result += parts.map { var p = $0; p.body = "[分段标识冲突，未自动合并]\n" + p.body; return p }; continue
            }
            var combined = ordered[0]
            combined.body = ordered.map(\.body).joined()
            if parts.count != combined.total {
                combined.body = "[长短信未收齐：\(parts.count)/\(combined.total) 段；当前为 \(ordered.map { String($0.part) }.joined(separator:","))]\n" + combined.body
            }
            combined.index = parts.map(\.index).min()!; result.append(combined)
        }
        return result.sorted { $0.timestamp == $1.timestamp ? $0.index > $1.index : $0.timestamp > $1.timestamp }
    }
    static func display(_ messages: [SMSMessage]) -> String {
        messages.isEmpty ? "当前存储区没有收到的短信。" : messages.map {
            "\($0.sender)   ·   \($0.timestamp)\n\($0.body)"
        }.joined(separator: "\n\n────────────────────────────────\n\n")
    }
}
