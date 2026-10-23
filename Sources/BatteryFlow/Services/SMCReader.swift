import Foundation
import IOKit

/// Battery SMC readings (direct gas gauge register reading with second-level refresh).
struct SMCBatteryReading: Sendable {
    var currentMa: Double?
    var voltageVolts: Double?
    var currentCapacityMah: Int?
    var maxCapacityMah: Int?
    var cycleCount: Int?
    var adapterInputWatts: Double?
    var adapterInputVoltageVolts: Double?
    var temperatureCelsius: Double?

    var hasAnyValue: Bool {
        currentMa != nil || voltageVolts != nil || maxCapacityMah != nil
            || currentCapacityMah != nil || cycleCount != nil
            || adapterInputWatts != nil
            || adapterInputVoltageVolts != nil || temperatureCelsius != nil
    }
}

/// Read-only access to AppleSMC battery registers.
///
/// Background: `AppleSmartBattery` IORegistry properties are snapshots maintained by powerd,
/// updating only roughly every 60s in testing; SMC keys `B0AC` / `B0AV` are continuously updated
/// by the gas gauge, so reading these SMC keys directly yields second-level current telemetry.
///
/// Implementation notes:
/// - Reading SMC **does not require root**; only writing charge limit keys (CH0B/CH0C/BCLM) requires a privileged helper.
/// - Swift structs cannot directly map C's `SMCKeyData_t` (Swift does not guarantee C memory layout),
///   so an 80-byte request packet is constructed and accessed via fixed offsets verified with C `offsetof`:
///   key=0, keyInfo.dataSize=28, keyInfo.dataType=32, result=40, data8=42, bytes=48.
/// - All 16/32-bit values are little-endian; `B0AC` is si16, `B0AV` is ui16.
enum SMCReader {
    static let currentKey = "B0AC"
    static let voltageKey = "B0AV"
    static let currentCapacityKey = "B0RM"
    static let maxCapacityKey = "B0FC"
    static let cycleCountKey = "B0CT"
    static let adapterPowerKey = "PDTR"
    static let adapterVoltageKey = "VD0R"
    static let temperatureKey = "TB0T"

    private static let packetSize = 80
    private static let kernelIndexSMC: UInt32 = 2
    private static let commandReadKeyInfo: UInt8 = 9
    private static let commandReadBytes: UInt8 = 5

    private static let resultOffset = 40
    private static let data8Offset = 42
    private static let dataSizeOffset = 28
    private static let dataTypeOffset = 32
    private static let payloadOffset = 48

    private static let typeSI16 = fourCC("si16")
    private static let typeUI16 = fourCC("ui16")
    private static let typeSI32 = fourCC("si32")
    private static let typeUI32 = fourCC("ui32")
    private static let typeFloat = fourCC("flt ")

    /// Reads a set of battery SMC keys; any missing key or read failure yields nil for that field.
    static func readBattery() -> SMCBatteryReading {
        var reading = SMCBatteryReading()
        guard let connection = openConnection() else { return reading }
        defer { IOServiceClose(connection) }

        if let current = readNumber(connection, key: currentKey) {
            reading.currentMa = current
        }
        if let voltageMv = readNumber(connection, key: voltageKey), voltageMv > 0 {
            reading.voltageVolts = voltageMv / 1000.0
        }
        if let currentCapacity = readNumber(connection, key: currentCapacityKey), currentCapacity >= 0 {
            reading.currentCapacityMah = Int(currentCapacity.rounded())
        }
        if let maxCapacity = readNumber(connection, key: maxCapacityKey), maxCapacity > 0 {
            reading.maxCapacityMah = Int(maxCapacity.rounded())
        }
        if let cycles = readNumber(connection, key: cycleCountKey), cycles >= 0 {
            reading.cycleCount = Int(cycles.rounded())
        }
        // Power/Temperature: range validation to prevent abnormal values on certain models
        if let adapterPower = readNumber(connection, key: adapterPowerKey), (0...300).contains(adapterPower) {
            reading.adapterInputWatts = adapterPower
        }
        if let adapterVoltage = readNumber(connection, key: adapterVoltageKey), (0...30).contains(adapterVoltage) {
            reading.adapterInputVoltageVolts = adapterVoltage
        }
        if let temperature = readNumber(connection, key: temperatureKey), (-20...120).contains(temperature) {
            reading.temperatureCelsius = temperature
        }
        return reading
    }

    // MARK: - IOKit

    private static func openConnection() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        return connection
    }

    private static func readNumber(_ connection: io_connect_t, key: String) -> Double? {
        guard let value = readKey(connection, key: key) else { return nil }
        return decode(value)
    }

    private static func readKey(_ connection: io_connect_t, key: String) -> SMCKeyValue? {
        var input = makePacket()
        var output = makePacket()
        writeFourCC(key, into: &input, at: 0)
        input[data8Offset] = commandReadKeyInfo

        var outputSize = packetSize
        guard callStruct(connection, input: &input, output: &output, outputSize: &outputSize) == KERN_SUCCESS,
              output[resultOffset] == 0 else { return nil }

        let dataSize = Int(readUInt32LE(output, at: dataSizeOffset))
        let dataType = readUInt32LE(output, at: dataTypeOffset)
        guard dataSize > 0, dataSize <= 32 else { return nil }

        input = makePacket()
        output = makePacket()
        writeFourCC(key, into: &input, at: 0)
        writeUInt32LE(UInt32(dataSize), into: &input, at: dataSizeOffset)
        input[data8Offset] = commandReadBytes

        outputSize = packetSize
        guard callStruct(connection, input: &input, output: &output, outputSize: &outputSize) == KERN_SUCCESS,
              output[resultOffset] == 0 else { return nil }

        let bytes = Array(output[payloadOffset..<(payloadOffset + dataSize)])
        return SMCKeyValue(type: dataType, bytes: bytes)
    }

    private static func callStruct(
        _ connection: io_connect_t,
        input: inout [UInt8],
        output: inout [UInt8],
        outputSize: inout Int
    ) -> kern_return_t {
        input.withUnsafeMutableBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    kernelIndexSMC,
                    inputBuffer.baseAddress,
                    packetSize,
                    outputBuffer.baseAddress,
                    &outputSize
                )
            }
        }
    }

    // MARK: - Decoding

    private struct SMCKeyValue {
        let type: UInt32
        let bytes: [UInt8]
    }

    private static func decode(_ value: SMCKeyValue) -> Double? {
        switch value.type {
        case typeSI16:
            guard value.bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: readUInt16LE(value.bytes)))
        case typeUI16:
            guard value.bytes.count >= 2 else { return nil }
            return Double(readUInt16LE(value.bytes))
        case typeSI32:
            guard value.bytes.count >= 4 else { return nil }
            return Double(Int32(bitPattern: readUInt32LE(value.bytes, at: 0)))
        case typeUI32:
            guard value.bytes.count >= 4 else { return nil }
            return Double(readUInt32LE(value.bytes, at: 0))
        case typeFloat:
            guard value.bytes.count >= 4 else { return nil }
            return Double(Float(bitPattern: readUInt32LE(value.bytes, at: 0)))
        default:
            return nil
        }
    }

    // MARK: - Byte Utilities

    private static func makePacket() -> [UInt8] {
        [UInt8](repeating: 0, count: packetSize)
    }

    /// The SMC key field is a native-endian UInt32 (consistent with C `_strtoul`),
    /// which appears reversed in memory byte order on little-endian machines ("B0AC" -> 42 30 41 43? No,
    /// writing 0x42304143 puts 43 41 30 42 in memory). Must be written as a numeric value, not as string bytes.
    private static func writeFourCC(_ key: String, into buffer: inout [UInt8], at offset: Int) {
        writeUInt32LE(fourCC(key), into: &buffer, at: offset)
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int = 0) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
