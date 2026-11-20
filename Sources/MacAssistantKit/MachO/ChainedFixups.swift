import Foundation

/// 只读还原 `LC_DYLD_CHAINED_FIXUPS` 里的指针。
///
/// 布局来自公开的 Mach-O `fixup-chains`：64 位 rebase/bind、arm64e userland / userland24。
/// 不读取、不链接 dsdump。FairPlay 加密段不在这里处理。
struct ChainedFixupTable {
    enum Slot: Equatable {
        case rebase(UInt64)
        case bind(String?)
    }

    let usesChains: Bool
    let slots: [Int: Slot]
    let unsupportedFormats: [UInt16]
    let symbolsCompressed: Bool
    /// 有 load command，但 header 越界或版本不对，不能把槽里的原始字当成地址。
    let malformed: Bool

    func slot(at fileOffset: Int) -> Slot? { slots[fileOffset] }

    /// 没有这条 load command 时返回 nil，调用方按传统绝对指针读取。
    static func parse(
        _ b: [UInt8],
        sliceOffset: Int,
        littleEndian le: Bool,
        segments: [MachOSegment]
    ) -> ChainedFixupTable? {
        guard let command = chainedFixupsCommand(b, sliceOffset: sliceOffset, littleEndian: le) else {
            return nil
        }
        let payload = sliceOffset + command.dataoff
        guard command.datasize >= 28, payload >= 0, payload + command.datasize <= b.count else {
            return ChainedFixupTable(
                usesChains: true, slots: [:], unsupportedFormats: [], symbolsCompressed: false, malformed: true
            )
        }
        let fixupsVersion = MachOInspector.readU32(b, payload, le)
        guard fixupsVersion == 0 else {
            return ChainedFixupTable(
                usesChains: true, slots: [:], unsupportedFormats: [], symbolsCompressed: false, malformed: true
            )
        }
        let startsOffset = Int(MachOInspector.readU32(b, payload + 4, le))
        let importsOffset = Int(MachOInspector.readU32(b, payload + 8, le))
        let symbolsOffset = Int(MachOInspector.readU32(b, payload + 12, le))
        let importsCount = Int(MachOInspector.readU32(b, payload + 16, le))
        let importsFormat = MachOInspector.readU32(b, payload + 20, le)
        let symbolsFormat = MachOInspector.readU32(b, payload + 24, le)
        guard startsOffset >= 0, importsOffset >= 0, symbolsOffset >= 0,
              startsOffset < command.datasize, importsOffset <= command.datasize, symbolsOffset <= command.datasize,
              importsCount >= 0, importsCount < 1_000_000
        else {
            return ChainedFixupTable(
                usesChains: true, slots: [:], unsupportedFormats: [], symbolsCompressed: false, malformed: true
            )
        }

        let symbolsCompressed = symbolsFormat != 0
        let imports = symbolsCompressed
            ? []
            : importNames(
                b,
                payload: payload,
                payloadSize: command.datasize,
                importsOffset: importsOffset,
                symbolsOffset: symbolsOffset,
                count: importsCount,
                format: importsFormat,
                littleEndian: le
            )
        let imageBase = segments.first { $0.filesize > 0 }.map { $0.vmaddr &- $0.fileoff } ?? 0
        var slots: [Int: Slot] = [:]
        var unsupported: [UInt16] = []
        walkChains(
            b,
            payload: payload,
            payloadSize: command.datasize,
            startsOffset: startsOffset,
            littleEndian: le,
            segments: segments,
            sliceOffset: sliceOffset,
            imageBase: imageBase,
            imports: imports,
            slots: &slots,
            unsupported: &unsupported
        )
        return ChainedFixupTable(
            usesChains: true,
            slots: slots,
            unsupportedFormats: Array(Set(unsupported)).sorted(),
            symbolsCompressed: symbolsCompressed,
            malformed: false
        )
    }
}

enum ChainedFixupPointer {
    struct Decoded: Equatable {
        var next: UInt64
        var stride: Int
        var rebase: UInt64?
        var bindOrdinal: UInt64?
    }

    /// `format` 是 `dyld_chained_starts_in_segment.pointer_format`。
    static func decode(raw: UInt64, format: UInt16, imageBase: UInt64) -> Decoded? {
        switch format {
        case 2, 6:
            return decode64(raw, targetIsOffset: format == 6, imageBase: imageBase)
        case 1, 7, 9, 10, 12:
            let stride = (format == 7 || format == 10) ? 4 : 8
            let unauthIsOffset = format != 1 && format != 10
            let ordinalBits = format == 12 ? 24 : 16
            return decodeArm64e(
                raw,
                stride: stride,
                unauthTargetIsOffset: unauthIsOffset,
                ordinalBits: ordinalBits,
                imageBase: imageBase
            )
        default:
            return nil
        }
    }

    private static func decode64(_ raw: UInt64, targetIsOffset: Bool, imageBase: UInt64) -> Decoded {
        let bind = (raw >> 63) & 1
        let next = (raw >> 51) & 0xFFF
        if bind == 1 {
            return Decoded(next: next, stride: 4, rebase: nil, bindOrdinal: raw & 0xFF_FFFF)
        }
        let target = raw & ((UInt64(1) << 36) - 1)
        let high8 = (raw >> 36) & 0xFF
        return Decoded(
            next: next,
            stride: 4,
            rebase: rebaseAddress(target: target, high8: high8, addImageBase: targetIsOffset, imageBase: imageBase),
            bindOrdinal: nil
        )
    }

    private static func decodeArm64e(
        _ raw: UInt64,
        stride: Int,
        unauthTargetIsOffset: Bool,
        ordinalBits: Int,
        imageBase: UInt64
    ) -> Decoded {
        let auth = (raw >> 63) & 1
        let bind = (raw >> 62) & 1
        let next = (raw >> 51) & 0x7FF
        if bind == 1 {
            let mask: UInt64 = ordinalBits >= 64 ? .max : (UInt64(1) << ordinalBits) - 1
            return Decoded(next: next, stride: stride, rebase: nil, bindOrdinal: raw & mask)
        }
        if auth == 1 {
            let target = raw & 0xFFFF_FFFF
            return Decoded(next: next, stride: stride, rebase: imageBase &+ target, bindOrdinal: nil)
        }
        let target = raw & ((UInt64(1) << 43) - 1)
        let high8 = (raw >> 43) & 0xFF
        return Decoded(
            next: next,
            stride: stride,
            rebase: rebaseAddress(target: target, high8: high8, addImageBase: unauthTargetIsOffset, imageBase: imageBase),
            bindOrdinal: nil
        )
    }

    private static func rebaseAddress(
        target: UInt64,
        high8: UInt64,
        addImageBase: Bool,
        imageBase: UInt64
    ) -> UInt64 {
        var value = addImageBase ? imageBase &+ target : target
        if high8 != 0 {
            value = (high8 << 56) | (value & 0x00FF_FFFF_FFFF_FFFF)
        }
        return value
    }
}

private struct ChainedFixupsCommand {
    let dataoff: Int
    let datasize: Int
}

private func chainedFixupsCommand(
    _ b: [UInt8],
    sliceOffset: Int,
    littleEndian le: Bool
) -> ChainedFixupsCommand? {
    guard sliceOffset + 32 <= b.count else { return nil }
    let magic = MachOInspector.readU32(b, sliceOffset, true)
    let is64 = magic == 0xFEED_FACF || magic == 0xCFFA_EDFE
    guard is64 else { return nil }
    let headerSize = 32
    let ncmds = Int(MachOInspector.readU32(b, sliceOffset + 16, le))
    guard ncmds >= 0, ncmds < 100_000 else { return nil }
    var p = sliceOffset + headerSize
    for _ in 0..<ncmds {
        guard p + 8 <= b.count else { return nil }
        let cmd = MachOInspector.readU32(b, p, le)
        let cmdsize = Int(MachOInspector.readU32(b, p + 4, le))
        guard cmdsize >= 8, p + cmdsize <= b.count else { return nil }
        if cmd == 0x8000_0034, p + 16 <= b.count {
            return ChainedFixupsCommand(
                dataoff: Int(MachOInspector.readU32(b, p + 8, le)),
                datasize: Int(MachOInspector.readU32(b, p + 12, le))
            )
        }
        p += cmdsize
    }
    return nil
}

private func importNames(
    _ b: [UInt8],
    payload: Int,
    payloadSize: Int,
    importsOffset: Int,
    symbolsOffset: Int,
    count: Int,
    format: UInt32,
    littleEndian le: Bool
) -> [String] {
    let entrySize: Int
    switch format {
    case 1: entrySize = 4
    case 2: entrySize = 8
    case 3: entrySize = 16
    default: return []
    }
    let importsAt = payload + importsOffset
    let symbolsAt = payload + symbolsOffset
    guard importsAt >= payload, symbolsAt >= payload,
          importsAt + count * entrySize <= payload + payloadSize,
          symbolsAt <= payload + payloadSize
    else { return [] }
    var names: [String] = []
    names.reserveCapacity(count)
    for index in 0..<count {
        let entry = importsAt + index * entrySize
        let nameOffset: Int
        switch format {
        case 3:
            let word = MachOInspector.readU64(b, entry, le)
            nameOffset = Int(word >> 32)
        default:
            let word = MachOInspector.readU32(b, entry, le)
            nameOffset = Int(word >> 9)
        }
        let stringAt = symbolsAt + nameOffset
        guard nameOffset >= 0, stringAt >= symbolsAt, stringAt < payload + payloadSize else {
            names.append("")
            continue
        }
        names.append(MachOInspector.cString(b, stringAt, max: 4096))
    }
    return names
}

private func walkChains(
    _ b: [UInt8],
    payload: Int,
    payloadSize: Int,
    startsOffset: Int,
    littleEndian le: Bool,
    segments: [MachOSegment],
    sliceOffset: Int,
    imageBase: UInt64,
    imports: [String],
    slots: inout [Int: ChainedFixupTable.Slot],
    unsupported: inout [UInt16]
) {
    let starts = payload + startsOffset
    guard starts + 4 <= payload + payloadSize, starts + 4 <= b.count else { return }
    let segCount = Int(MachOInspector.readU32(b, starts, le))
    guard segCount > 0, segCount < 10_000, starts + 4 + segCount * 4 <= b.count else { return }
    let maxSlots = 5_000_000
    for segIndex in 0..<segCount {
        let infoRel = Int(MachOInspector.readU32(b, starts + 4 + segIndex * 4, le))
        if infoRel == 0 { continue }
        let info = starts + infoRel
        guard infoRel > 0, info + 22 <= b.count, info + 22 <= payload + payloadSize else { continue }
        let size = Int(MachOInspector.readU32(b, info, le))
        let pageSize = Int(readU16(b, info + 4, le))
        let pointerFormat = readU16(b, info + 6, le)
        let segmentOffset = MachOInspector.readU64(b, info + 8, le)
        let pageCount = Int(readU16(b, info + 20, le))
        guard size >= 22, info + size <= b.count, pageSize >= 4, pageCount >= 0, pageCount < 1_000_000 else { continue }
        guard ChainedFixupPointer.decode(raw: 0, format: pointerFormat, imageBase: imageBase) != nil else {
            unsupported.append(pointerFormat)
            continue
        }
        let availableEntries = min((size - 22) / 2, 1_000_000)
        guard pageCount <= availableEntries else { continue }
        var pageStarts: [UInt16] = []
        pageStarts.reserveCapacity(availableEntries)
        for entry in 0..<availableEntries {
            pageStarts.append(readU16(b, info + 22 + entry * 2, le))
        }
        for pageIndex in 0..<pageCount {
            let startsOnPage = chainStartOffsets(pageStarts[pageIndex], pageStarts: pageStarts)
            for offsetInPage in startsOnPage {
                guard offsetInPage < pageSize else { continue }
                let pageVM = imageBase &+ segmentOffset &+ UInt64(pageIndex * pageSize) &+ UInt64(offsetInPage)
                walkOneChain(
                    b,
                    startVM: pageVM,
                    format: pointerFormat,
                    imageBase: imageBase,
                    segments: segments,
                    sliceOffset: sliceOffset,
                    imports: imports,
                    littleEndian: le,
                    slots: &slots,
                    maxSlots: maxSlots
                )
                if slots.count >= maxSlots { return }
            }
        }
    }
}

private func chainStartOffsets(_ pageStart: UInt16, pageStarts: [UInt16]) -> [Int] {
    if pageStart == 0xFFFF { return [] }
    if pageStart & 0x8000 == 0 { return [Int(pageStart)] }
    var index = Int(pageStart & 0x7FFF)
    var offsets: [Int] = []
    var steps = 0
    while index >= 0, index < pageStarts.count, steps < 64 {
        let entry = pageStarts[index]
        offsets.append(Int(entry & 0x7FFF))
        steps += 1
        if entry & 0x8000 != 0 { break }
        index += 1
    }
    return offsets
}

private func walkOneChain(
    _ b: [UInt8],
    startVM: UInt64,
    format: UInt16,
    imageBase: UInt64,
    segments: [MachOSegment],
    sliceOffset: Int,
    imports: [String],
    littleEndian le: Bool,
    slots: inout [Int: ChainedFixupTable.Slot],
    maxSlots: Int
) {
    var vm = startVM
    var seen: Set<Int> = []
    var steps = 0
    while steps < 1_000_000, slots.count < maxSlots {
        steps += 1
        guard let fileOff = fileOffset(forVMAddr: vm, segments: segments, sliceOffset: sliceOffset),
              fileOff + 8 <= b.count,
              seen.insert(fileOff).inserted
        else { return }
        let raw = MachOInspector.readU64(b, fileOff, le)
        guard let decoded = ChainedFixupPointer.decode(raw: raw, format: format, imageBase: imageBase) else { return }
        if let ordinal = decoded.bindOrdinal {
            let index = Int(ordinal)
            let name = (index >= 0 && index < imports.count && !imports[index].isEmpty) ? imports[index] : nil
            slots[fileOff] = .bind(name)
        } else if let rebase = decoded.rebase {
            slots[fileOff] = .rebase(rebase)
        }
        if decoded.next == 0 || decoded.stride <= 0 { return }
        vm &+= decoded.next &* UInt64(decoded.stride)
    }
}

private func fileOffset(forVMAddr vmaddr: UInt64, segments: [MachOSegment], sliceOffset: Int) -> Int? {
    guard vmaddr != 0 else { return nil }
    for seg in segments where seg.filesize > 0 {
        if vmaddr >= seg.vmaddr, vmaddr < seg.vmaddr &+ seg.filesize {
            return sliceOffset + Int(seg.fileoff &+ (vmaddr &- seg.vmaddr))
        }
    }
    return nil
}

private func readU16(_ b: [UInt8], _ offset: Int, _ le: Bool) -> UInt16 {
    guard offset + 2 <= b.count else { return 0 }
    let low = UInt16(b[offset])
    let high = UInt16(b[offset + 1])
    return le ? (low | (high << 8)) : (high | (low << 8))
}
