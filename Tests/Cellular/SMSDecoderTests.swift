import Foundation

@main enum SMSDecoderTests {
    struct Fixture: Decodable {
        var name: String; var pdu: String; var text: String?; var sender: String?
        var reference: Int?; var part: Int?; var total: Int?; var invalid: Bool?
    }
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath:CommandLine.arguments[1])
            process.arguments = ["sms", "ME", "--allow-mark-read"]; process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let result = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            precondition(result["success"] as? Bool == true, "Live SMS request failed (no content logged)")
            let decoded = SMSDecoder.parse(result["smsPdu"] as? String ?? "")
            precondition(!decoded.isEmpty && decoded.allSatisfy { $0.sender != "无法解码的短信" && !$0.body.isEmpty && !$0.timestamp.isEmpty })
            print("PASS: live SMS decoded locally; received=\(decoded.count); storageUsed=\(result["smsUsed"] ?? 0). Sender, timestamp and body deliberately not logged.")
            return
        }
        let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self,from:data)
        var messages:[SMSMessage] = []
        for (i,f) in fixtures.enumerated() {
            do {
                let m = try SMSDecoder.decode(f.pdu,index:i)
                precondition(f.invalid != true, "Expected rejection: \(f.name)")
                precondition(m.body == f.text && m.sender == f.sender && m.reference == f.reference && m.part == (f.part ?? 1) && m.total == (f.total ?? 1), "Mismatch: \(f.name)")
                messages.append(m)
            } catch { precondition(f.invalid == true,"Unexpected rejection: \(f.name)") }
        }
        let parts = messages.filter { $0.reference == 42 }
        let merged = SMSDecoder.assemble(parts.reversed())
        precondition(merged.count == 1 && merged[0].body == "第一部分第二部分")
        precondition(SMSDecoder.assemble([parts[0]])[0].body.contains("未收齐"))
        precondition(SMSDecoder.assemble(parts + [parts[0]]).count == 3)
        let list = "+CMGL: 1,0,,20\r\n\(fixtures[0].pdu)\r\n+CMGL: 2,2,,20\r\n\(fixtures[1].pdu)\r\nOK\r\n"
        precondition(SMSDecoder.parse(list).count == 1)
        precondition(SMSDecoder.parse("+CMGL: 1,0,,20\r\n").count == 1)
        // The default alphabet's extension table includes brace and euro.
        let extensionText = try SMSDecoder.gsm([0x1b,0x14],count:2)
        precondition(extensionText == "{")
        print("PASS: \(fixtures.count) PDU fixtures + concatenation/order/incomplete/conflict, inbox filtering, malformed entry, GSM extension.")
    }
}
