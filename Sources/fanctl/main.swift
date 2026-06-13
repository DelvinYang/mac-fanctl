import Darwin
import Foundation
import IOKit

enum SMCError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case ioKit(kern_return_t)
    case firmware(UInt8)
    case invalidKey(String)
    case invalidArgument(String)
    case unsafe(String)

    var description: String {
        switch self {
        case .connectionFailed(let message):
            return message
        case .ioKit(let code):
            return "IOKit error: 0x\(String(code, radix: 16))"
        case .firmware(let code):
            return "SMC firmware error: 0x\(String(code, radix: 16))"
        case .invalidKey(let key):
            return "Invalid SMC key: \(key)"
        case .invalidArgument(let message), .unsafe(let message):
            return message
        }
    }
}

enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCValue {
    let key: String
    let bytes: [UInt8]
    let size: UInt32
    let type: String
}

final class SMCConnection {
    private let connection: io_connect_t

    init() throws {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }

        let match = IOServiceMatching("AppleSMC")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == kIOReturnSuccess else {
            throw SMCError.connectionFailed("Failed to find AppleSMC service")
        }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw SMCError.connectionFailed("AppleSMC service is not available")
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }

        connection = conn
    }

    deinit {
        IOServiceClose(connection)
    }

    func readKey(_ key: String) throws -> SMCValue {
        let (param, info) = try fetchKeyInfo(key)
        var readParam = param
        readParam.keyInfo.dataSize = info.keyInfo.dataSize
        readParam.data8 = SMCCommand.readBytes.rawValue
        let output = try call(readParam)
        try checkFirmware(output.result)
        let rawBytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        return SMCValue(
            key: key,
            bytes: rawBytes,
            size: info.keyInfo.dataSize,
            type: decodeType(info.keyInfo.dataType)
        )
    }

    func writeKey(_ key: String, bytes: [UInt8]) throws {
        let (param, info) = try fetchKeyInfo(key)
        guard bytes.count == Int(info.keyInfo.dataSize) else {
            throw SMCError.invalidArgument("\(key) expects \(info.keyInfo.dataSize) bytes, got \(bytes.count)")
        }

        var writeParam = param
        writeParam.keyInfo.dataSize = info.keyInfo.dataSize
        writeParam.data8 = SMCCommand.writeBytes.rawValue
        writeParam.bytes = tuple32(bytes)
        let output = try call(writeParam)
        try checkFirmware(output.result)
    }

    func enumerateKeys(prefix: String?) throws -> [String] {
        let keyCount = try readKey("#KEY").uint32
        var keys: [String] = []
        keys.reserveCapacity(Int(min(keyCount, 4096)))

        for index in 0..<keyCount {
            var input = SMCParamStruct()
            input.data8 = SMCCommand.readIndex.rawValue
            input.data32 = index
            guard let output = try? call(input) else {
                continue
            }
            let key = fourCharString(output.key)
            if let prefix, !key.hasPrefix(prefix) {
                continue
            }
            keys.append(key)
        }

        return keys.sorted()
    }

    private func fetchKeyInfo(_ key: String) throws -> (SMCParamStruct, SMCParamStruct) {
        var input = SMCParamStruct()
        input.key = try fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        let output = try call(input)
        try checkFirmware(output.result)
        return (input, output)
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }
        return output
    }
}

struct FanInfo {
    let index: Int
    let actual: Float
    let target: Float
    let minimum: Float
    let maximum: Float
    let manual: Bool?
    let modeKey: String?
}

final class FanController {
    private let smc: SMCConnection
    private let modeKeyFormat: String
    private let hasForceTest: Bool

    init(smc: SMCConnection) {
        self.smc = smc
        if (try? smc.readKey("F0md")) != nil {
            modeKeyFormat = "F%dmd"
        } else if (try? smc.readKey("F0Md")) != nil {
            modeKeyFormat = "F%dMd"
        } else {
            modeKeyFormat = "F%dmd"
        }
        hasForceTest = (try? smc.readKey("Ftst")) != nil
    }

    var forceTestAvailable: Bool {
        hasForceTest
    }

    func fanCount() throws -> Int {
        Int(try smc.readKey("FNum").uint8)
    }

    func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = try smc.readKey(fanKey("F%dAc", index)).rpm
        let target = try smc.readKey(fanKey("F%dTg", index)).rpm
        let minimum = try smc.readKey(fanKey("F%dMn", index)).rpm
        let maximum = try smc.readKey(fanKey("F%dMx", index)).rpm
        let modeKey = fanKey(modeKeyFormat, index)
        let manual = try? smc.readKey(modeKey).uint8 == 1
        return FanInfo(
            index: index,
            actual: actual,
            target: target,
            minimum: minimum,
            maximum: maximum,
            manual: manual,
            modeKey: modeKey
        )
    }

    func setFan(_ index: Int, rpm requestedRPM: Float, allowRisk: Bool) throws {
        guard allowRisk else {
            throw SMCError.unsafe("Refusing to write SMC without --i-understand-risk")
        }
        guard geteuid() == 0 else {
            throw SMCError.unsafe("Run set/auto with sudo")
        }

        let info = try fanInfo(index)
        let lowerBound = max(info.minimum, info.actual, info.target)
        guard requestedRPM >= lowerBound else {
            throw SMCError.unsafe(
                "Refusing to lower fan target below current safe floor \(Int(lowerBound)) RPM"
            )
        }
        guard requestedRPM <= info.maximum else {
            throw SMCError.unsafe("Requested \(Int(requestedRPM)) RPM exceeds max \(Int(info.maximum)) RPM")
        }

        let targetKey = fanKey("F%dTg", index)
        let targetValue = try smc.readKey(targetKey)
        try enableManualMode(index)
        do {
            try smc.writeKey(targetKey, bytes: rpmBytes(requestedRPM, size: targetValue.size))
        } catch {
            try? autoFan(index, allowRisk: true)
            throw error
        }
    }

    func autoFan(_ index: Int, allowRisk: Bool) throws {
        guard allowRisk else {
            throw SMCError.unsafe("Refusing to write SMC without --i-understand-risk")
        }
        guard geteuid() == 0 else {
            throw SMCError.unsafe("Run set/auto with sudo")
        }

        let modeKey = fanKey(modeKeyFormat, index)
        if let size = try? smc.readKey(modeKey).size {
            try smc.writeKey(modeKey, bytes: [UInt8](repeating: 0, count: Int(size)))
        }

        let targetKey = fanKey("F%dTg", index)
        if let targetSize = try? smc.readKey(targetKey).size {
            try smc.writeKey(targetKey, bytes: rpmBytes(0, size: targetSize))
        }

        if hasForceTest && !otherFansManual(except: index) {
            try? smc.writeKey("Ftst", bytes: [0])
        }
    }

    private func enableManualMode(_ index: Int) throws {
        let modeKey = fanKey(modeKeyFormat, index)
        let size = try smc.readKey(modeKey).size
        let bytes = [UInt8](repeating: 0, count: Int(size)).enumerated().map { offset, _ in
            offset == 0 ? UInt8(1) : UInt8(0)
        }

        do {
            try smc.writeKey(modeKey, bytes: bytes)
            return
        } catch {
            guard hasForceTest else {
                throw error
            }
        }

        try smc.writeKey("Ftst", bytes: [1])
        usleep(500_000)
        for _ in 0..<100 {
            do {
                try smc.writeKey(modeKey, bytes: bytes)
                return
            } catch {
                usleep(100_000)
            }
        }
        throw SMCError.unsafe("Timed out while enabling manual fan mode")
    }

    private func otherFansManual(except index: Int) -> Bool {
        guard let count = try? fanCount() else {
            return true
        }
        for fan in 0..<count where fan != index {
            let modeKey = fanKey(modeKeyFormat, fan)
            if let value = try? smc.readKey(modeKey), value.uint8 == 1 {
                return true
            }
        }
        return false
    }

    private func fanKey(_ format: String, _ index: Int) -> String {
        String(format: format, index)
    }
}

extension SMCValue {
    var uint8: UInt8 {
        bytes.first ?? 0
    }

    var uint32: UInt32 {
        guard bytes.count >= 4 else {
            return 0
        }
        return bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    var rpm: Float {
        if size == 4, bytes.count >= 4 {
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }
        if bytes.count >= 2 {
            let raw = bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
            return Float(raw) / 4.0
        }
        return 0
    }

    var printable: String {
        switch type {
        case "flt ", "flt":
            return String(format: "%.2f", rpm)
        case "ui8 ":
            return "\(uint8)"
        case "ui32":
            return "\(uint32)"
        default:
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "0x\(hex)"
        }
    }
}

func rpmBytes(_ value: Float, size: UInt32) -> [UInt8] {
    if size == 4 {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0.prefix(4)) }
    }
    let raw = UInt16(value * 4.0)
    return [UInt8(raw >> 8), UInt8(raw & 0xff)]
}

func checkFirmware(_ result: UInt8) throws {
    if result != 0 {
        throw SMCError.firmware(result)
    }
}

func fourCharCode(_ key: String) throws -> UInt32 {
    guard key.utf8.count == 4 else {
        throw SMCError.invalidKey(key)
    }
    return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func fourCharString(_ value: UInt32) -> String {
    let chars = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: chars, encoding: .ascii) ?? "????"
}

func decodeType(_ value: UInt32) -> String {
    let chars = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: chars, encoding: .ascii) ?? "????"
}

func tuple32(_ bytes: [UInt8]) -> SMCParamStruct.Bytes32 {
    let padded = bytes + [UInt8](repeating: 0, count: max(0, 32 - bytes.count))
    return (
        padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7],
        padded[8], padded[9], padded[10], padded[11], padded[12], padded[13], padded[14], padded[15],
        padded[16], padded[17], padded[18], padded[19], padded[20], padded[21], padded[22], padded[23],
        padded[24], padded[25], padded[26], padded[27], padded[28], padded[29], padded[30], padded[31]
    )
}

func printUsage() {
    print("""
    Usage:
      fanctl status
      fanctl keys [prefix]
      fanctl read <SMC_KEY>
      sudo fanctl set <fan> <rpm> --i-understand-risk
      sudo fanctl auto <fan> --i-understand-risk

    Notes:
      set refuses to lower the target below the current actual RPM.
      auto returns the fan to macOS thermal management.
    """)
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        printUsage()
        return
    }

    let smc = try SMCConnection()
    let fans = FanController(smc: smc)

    switch command {
    case "status":
        let count = try fans.fanCount()
        print("Fans: \(count)")
        print("Ftst unlock key: \(fans.forceTestAvailable ? "available" : "not available")")
        for fan in 0..<count {
            let info = try fans.fanInfo(fan)
            let manual = info.manual.map { $0 ? "Manual" : "Auto" } ?? "Unknown"
            print(
                "Fan \(fan): actual \(Int(info.actual)) RPM, target \(Int(info.target)) RPM, min \(Int(info.minimum)) RPM, max \(Int(info.maximum)) RPM, mode \(manual), modeKey \(info.modeKey ?? "?")"
            )
        }
    case "keys":
        let prefix = args.dropFirst().first
        for key in try smc.enumerateKeys(prefix: prefix) {
            if let value = try? smc.readKey(key) {
                print("\(key) \(value.type) \(value.printable)")
            } else {
                print("\(key)")
            }
        }
    case "read":
        guard args.count == 2 else {
            throw SMCError.invalidArgument("read requires exactly one key")
        }
        let value = try smc.readKey(args[1])
        print("\(value.key) \(value.type) \(value.printable)")
    case "set":
        guard args.count >= 3 else {
            throw SMCError.invalidArgument("set requires <fan> <rpm>")
        }
        guard let fan = Int(args[1]), let rpm = Float(args[2]) else {
            throw SMCError.invalidArgument("fan and rpm must be numbers")
        }
        try fans.setFan(fan, rpm: rpm, allowRisk: args.contains("--i-understand-risk"))
        print("Set fan \(fan) target to \(Int(rpm)) RPM")
    case "auto":
        guard args.count >= 2, let fan = Int(args[1]) else {
            throw SMCError.invalidArgument("auto requires <fan>")
        }
        try fans.autoFan(fan, allowRisk: args.contains("--i-understand-risk"))
        print("Returned fan \(fan) to automatic control")
    case "help", "-h", "--help":
        printUsage()
    default:
        throw SMCError.invalidArgument("Unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    fputs("fanctl: \(error)\n", stderr)
    exit(1)
}
