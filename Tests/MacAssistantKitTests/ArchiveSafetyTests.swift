import XCTest
@testable import MacAssistantKit

final class ArchiveSafetyTests: XCTestCase {
    private func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendU32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    private func storedZIP(
        name: String,
        payload: Data = Data(),
        externalAttributes: UInt32 = 0
    ) -> Data {
        let nameData = Data(name.utf8)
        var local = Data()
        appendU32(0x04034b50, to: &local)
        appendU16(20, to: &local)
        appendU16(0, to: &local)
        appendU16(0, to: &local)
        appendU16(0, to: &local)
        appendU16(0, to: &local)
        appendU32(0, to: &local)
        appendU32(UInt32(payload.count), to: &local)
        appendU32(UInt32(payload.count), to: &local)
        appendU16(UInt16(nameData.count), to: &local)
        appendU16(0, to: &local)
        local.append(nameData)
        local.append(payload)

        var central = Data()
        appendU32(0x02014b50, to: &central)
        appendU16(0x031e, to: &central)
        appendU16(20, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU32(0, to: &central)
        appendU32(UInt32(payload.count), to: &central)
        appendU32(UInt32(payload.count), to: &central)
        appendU16(UInt16(nameData.count), to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU32(externalAttributes, to: &central)
        appendU32(0, to: &central)
        central.append(nameData)

        var result = local
        let centralOffset = result.count
        result.append(central)
        appendU32(0x06054b50, to: &result)
        appendU16(0, to: &result)
        appendU16(0, to: &result)
        appendU16(1, to: &result)
        appendU16(1, to: &result)
        appendU32(UInt32(central.count), to: &result)
        appendU32(UInt32(centralOffset), to: &result)
        appendU16(0, to: &result)
        return result
    }

    func testRejectsZIPTraversalAbsoluteAndNULPaths() {
        for name in ["../escape", "/absolute/file", "C:/Windows/file", "ok/\0bad"] {
            XCTAssertThrowsError(try ArchiveSafety.validateZIP(storedZIP(name: name)), name)
        }
    }

    func testRejectsZIPSymlinkEvenWhenTargetLooksRelative() {
        let symlinkMode = UInt32(0o120777) << 16
        XCTAssertThrowsError(
            try ArchiveSafety.validateZIP(
                storedZIP(name: "Payload/link", payload: Data("../escape".utf8), externalAttributes: symlinkMode)
            )
        )
    }

    func testRejectsZIPBombLimits() {
        let zip = storedZIP(name: "Payload/large", payload: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(
            try ArchiveSafety.validateZIP(
                zip,
                limits: ArchiveLimits(maxEntries: 10, maxSingleFileBytes: 16, maxTotalBytes: 64)
            )
        )
    }

    func testAcceptsNormalPayloadEntry() throws {
        let result = try ArchiveSafety.validateZIP(storedZIP(name: "Payload/Demo.app/Info.plist"))
        XCTAssertEqual(result.entryCount, 1)
    }
}
