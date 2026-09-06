import Foundation
import IOKit

// structs copied verbatim from macstate SMCService.swift (private decls re-declared here)
private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

private struct SMCKeyDataVers {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: IOByteCount32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    var bytesArray: [UInt8] {
        [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
         bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
         bytes.16, bytes.17, bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
         bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29, bytes.30, bytes.31]
    }
}

let kernelIndex: UInt32 = 2
var conn: io_connect_t = 0

private func encodeSMCKey(_ key: String) -> UInt32? {
    guard key.utf8.count == 4 else { return nil }
    return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func decodeSMCType(_ raw: UInt32) -> String {
    let c1 = Character(UnicodeScalar((raw >> 24) & 0xFF) ?? " ")
    let c2 = Character(UnicodeScalar((raw >> 16) & 0xFF) ?? " ")
    let c3 = Character(UnicodeScalar((raw >> 8) & 0xFF) ?? " ")
    let c4 = Character(UnicodeScalar(raw & 0xFF) ?? " ")
    return String([c1, c2, c3, c4])
}

private func callSMC(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
    let inputSize = MemoryLayout<SMCKeyData>.stride
    var outputSize = MemoryLayout<SMCKeyData>.stride
    return IOConnectCallStructMethod(conn, kernelIndex, &input, inputSize, &output, &outputSize) == KERN_SUCCESS
}

private func readValueOnce(forKey key: String) -> (dataType: String, bytes: [UInt8])? {
    guard connectionOK, let encodedKey = encodeSMCKey(key) else { return nil }
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = encodedKey
    input.data8 = SMCCommand.readKeyInfo.rawValue
    guard callSMC(input: &input, output: &output) else { return nil }
    let keyInfo = output.keyInfo
    guard keyInfo.dataSize > 0, keyInfo.dataSize <= 32 else { return nil }
    input.keyInfo.dataSize = keyInfo.dataSize
    input.data8 = SMCCommand.readBytes.rawValue
    guard callSMC(input: &input, output: &output) else { return nil }
    return (decodeSMCType(keyInfo.dataType), Array(output.bytesArray.prefix(Int(keyInfo.dataSize))))
}

private func parseNumericValue(bytes: [UInt8], dataType: String) -> Double? {
    guard !bytes.isEmpty else { return nil }
    switch dataType {
    case "sp78":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 256.0
    case "sp87":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 128.0
    case "sp96":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 64.0
    case "spb4":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 16.0
    case "fpe2":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw) / 4.0
    case "flt ":
        guard bytes.count >= 4 else { return nil }
        var value: Float = 0
        var b = Array(bytes.prefix(4))
        memcpy(&value, &b, 4)
        return value.isFinite ? Double(value) : nil
    case "ui8 ":
        return Double(bytes[0])
    case "ui16":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw)
    case "ui32":
        guard bytes.count >= 4 else { return nil }
        let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Double(raw)
    case "sp5a":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 1024.0
    case "sp69":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / 512.0
    case "fp1f":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw) / 32768.0
    case "fp4c":
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw) / 4096.0
    default:
        return nil
    }
}

var connectionOK = false

let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0 else { print("no AppleSMC service"); exit(1) }
let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
IOObjectRelease(service)
print("IOServiceOpen: 0x\(String(openResult, radix: 16))  structStride=\(MemoryLayout<SMCKeyData>.stride)")
guard openResult == KERN_SUCCESS else { exit(1) }
connectionOK = true

// read #KEY count
var count = 0
if let v = readValueOnce(forKey: "#KEY"), v.bytes.count >= 4 {
    count = Int(v.bytes[0]) << 24 | Int(v.bytes[1]) << 16 | Int(v.bytes[2]) << 8 | Int(v.bytes[3])
}
print("total keys: \(count)")

let out = fopen("/tmp/smc_all_keys.txt", "w")
var numericCount = 0
for i in 0..<max(count, 1) {
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.data8 = SMCCommand.readIndex.rawValue
    input.data32 = UInt32(i)
    guard callSMC(input: &input, output: &output) else { continue }
    let raw = output.key
    let key = String([
        Character(UnicodeScalar((raw >> 24) & 0xFF) ?? " "),
        Character(UnicodeScalar((raw >> 16) & 0xFF) ?? " "),
        Character(UnicodeScalar((raw >> 8) & 0xFF) ?? " "),
        Character(UnicodeScalar(raw & 0xFF) ?? " "),
    ])

    var line: String
    if let v = readValueOnce(forKey: key) {
        if let num = parseNumericValue(bytes: v.bytes, dataType: v.dataType) {
            line = "\(key)\t\(v.dataType)\t\(v.bytes.count)\t\(num)"
            numericCount += 1
        } else {
            let hex = v.bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
            line = "\(key)\t\(v.dataType)\t\(v.bytes.count)\t\(hex)"
        }
    } else {
        line = "\(key)\t?\t?\tERR"
    }
    line.withCString { fputs($0, out); fputs("\n", out) }
}
fclose(out)
print("numeric keys: \(numericCount)")
IOServiceClose(conn)
