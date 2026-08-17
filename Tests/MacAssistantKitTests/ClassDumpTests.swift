import XCTest
@testable import MacAssistantKit

final class ClassDumpTests: XCTestCase {

    // MARK: ObjC 类型编码解码

    func testDecodeScalarTypes() {
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("v"), 0).0, "void")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("i"), 0).0, "int")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("q"), 0).0, "long long")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("@"), 0).0, "id")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array(":"), 0).0, "SEL")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("#"), 0).0, "Class")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("*"), 0).0, "char *")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("B"), 0).0, "BOOL")
    }

    func testDecodeClassAndPointer() {
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("@\"NSString\""), 0).0, "NSString *")
        XCTAssertEqual(ObjCTypeDecoder.decode(Array("^i"), 0).0, "int *")
        let s = ObjCTypeDecoder.decode(Array("{CGRect=dddd}"), 0).0
        XCTAssertTrue(s.contains("struct") && s.contains("CGRect"), s)
    }

    func testMethodDeclarationNoArgs() {
        let d = ObjCTypeDecoder.methodDeclaration(selector: "count", typeEncoding: "q16@0:8", isClassMethod: false)
        XCTAssertEqual(d, "- (long long)count;")
    }

    func testMethodDeclarationOneArg() {
        let d = ObjCTypeDecoder.methodDeclaration(selector: "setName:", typeEncoding: "v24@0:8@16", isClassMethod: false)
        XCTAssertEqual(d, "- (void)setName:(id)arg1;")
    }

    func testMethodDeclarationTwoArgsClassMethod() {
        let d = ObjCTypeDecoder.methodDeclaration(selector: "makeA:b:", typeEncoding: "@32@0:8i16i20", isClassMethod: true)
        XCTAssertEqual(d, "+ (id)makeA:(int)arg1 b:(int)arg2;")
    }

    // MARK: 传统 method_list 解析

    private func craftMethodList(entsize: UInt32, count: UInt32, entries: [(UInt64, UInt64, UInt64)]) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8((v >> (8 * i)) & 0xff)) } }
        func u64(_ v: UInt64) { for i in 0..<8 { b.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) } }
        u32(entsize); u32(count)
        for e in entries { u64(e.0); u64(e.1); u64(e.2) }
        return b
    }

    func testParseTraditionalMethodList() {
        let bytes = craftMethodList(entsize: 24, count: 1, entries: [(0x1000, 0x2000, 0x3000)])
        let names: [UInt64: String] = [0x1000: "doThing", 0x2000: "v16@0:8"]
        let methods = ObjCRuntime.parseMethodListTraditional(bytes, at: 0, le: true, isClassMethod: false) { names[$0] }
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.selector, "doThing")
        XCTAssertEqual(methods.first?.declaration, "- (void)doThing;")
    }

    func testRelativeMethodListIsSkipped() {
        // entsize 带 0x80000000 相对方法列表标志 → 原生传统解析应跳过
        let bytes = craftMethodList(entsize: 0x8000_0000 | 12, count: 1, entries: [(0x1000, 0x2000, 0x3000)])
        let methods = ObjCRuntime.parseMethodListTraditional(bytes, at: 0, le: true, isClassMethod: false) { _ in "x" }
        XCTAssertTrue(methods.isEmpty)
        XCTAssertTrue(ObjCRuntime.isRelativeMethodList(bytes, at: 0, le: true))
    }

    func testDecodePropertyAttributes() {
        let declaration = ObjCPropertyDecoder.declaration(
            name: "title",
            attributes: #"T@"NSString",C,N,V_title"#
        )
        XCTAssertEqual(declaration, "@property (copy, nonatomic) NSString *title;")
        XCTAssertEqual(
            ObjCPropertyDecoder.declaration(name: "enabled", attributes: "TB,R,N"),
            "@property (readonly, nonatomic) BOOL enabled;"
        )
    }

    func testExportAggregateAndPerClassUsesSafeNames() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-export")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = HeaderDumpResult(
            headers: "@interface Demo\n@end\n",
            classNames: ["Demo", "../Unsafe"],
            classHeaders: [
                ClassHeader(name: "Demo", contents: "@interface Demo\n@end\n"),
                ClassHeader(name: "../Unsafe", contents: "@interface Unsafe\n@end\n")
            ],
            usedExternalTool: nil,
            warnings: [],
            facts: MachOFacts(archs: ["arm64"])
        )

        let aggregate = try ClassDumpService.export(
            result,
            to: root.appendingPathComponent("aggregate"),
            baseName: "Fixture App",
            mode: .aggregate
        )
        XCTAssertEqual(aggregate.files.first?.lastPathComponent, "Fixture_App-Headers.h")
        XCTAssertTrue(try String(contentsOf: aggregate.files[0]).hasSuffix("\n"))

        let split = try ClassDumpService.export(
            result,
            to: root.appendingPathComponent("split"),
            baseName: "Fixture",
            mode: .oneFilePerClass
        )
        XCTAssertTrue(split.files.contains { $0.lastPathComponent == "Demo.h" })
        XCTAssertFalse(split.files.contains { $0.path.contains("../") })
        XCTAssertTrue(split.files.contains { $0.lastPathComponent == "Fixture-Headers.h" })
    }

    func testEncryptedMinimalMachOIsBlocked() throws {
        func u32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) }
        }
        var bytes = u32(0xFEED_FACF) + u32(0x0100_000C) + u32(0)
        bytes += u32(6) + u32(1) + u32(24) + u32(0) + u32(0)
        bytes += u32(0x2C) + u32(24) + u32(0) + u32(0) + u32(1) + u32(0)
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-encrypted")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("Encrypted")
        try Data(bytes).write(to: binary)

        XCTAssertThrowsError(
            try ClassDumpService.dump(fileAt: binary, allowExternalFallback: false)
        ) { error in
            guard case ClassDumpError.encrypted = error else {
                return XCTFail("应返回 FairPlay 加密错误，实际为 \(error)")
            }
        }
    }

    func testCapabilityReportMarksRelativeMethodsAndSwiftAsPartial() {
        let fixture = ObjCClass(
            name: "Fixture",
            superName: "NSObject",
            instanceMethods: [ObjCMethod(selector: "run", typeEncoding: "v16@0:8", isClassMethod: false)],
            classMethods: [],
            ivars: [],
            protocols: ["Runnable"],
            properties: [ObjCProperty(name: "name", attributes: "T@,C")]
        )
        let report = ClassDumpService.capabilityReport(
            facts: MachOFacts(archs: ["arm64"], hasSwift: true),
            classes: [fixture],
            exportedClassCount: 1,
            skippedCount: 2,
            skipReasons: ["relative method list 不支持"]
        )
        XCTAssertEqual(report.completeness, .partial)
        XCTAssertEqual(report.methodCount, 1)
        XCTAssertEqual(report.propertyCount, 1)
        XCTAssertEqual(report.protocolCount, 1)
        XCTAssertEqual(report.skippedCount, 2)
        XCTAssertTrue(report.skipReasons.contains { $0.contains("Swift") })
    }

    func testEmptyAndChainedMachOCannotReportSuccess() throws {
        func u32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) }
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        var empty = u32(0xFEED_FACF) + u32(0x0100_000C) + u32(0)
        empty += u32(6) + u32(0) + u32(0) + u32(0) + u32(0)
        let emptyURL = root.appendingPathComponent("Empty")
        try Data(empty).write(to: emptyURL)
        XCTAssertThrowsError(try ClassDumpService.dump(fileAt: emptyURL, allowExternalFallback: false))

        var chained = u32(0xFEED_FACF) + u32(0x0100_000C) + u32(0)
        chained += u32(6) + u32(1) + u32(16) + u32(0) + u32(0)
        chained += u32(0x8000_0034) + u32(16) + u32(0) + u32(0)
        let chainedURL = root.appendingPathComponent("Chained")
        try Data(chained).write(to: chainedURL)
        XCTAssertThrowsError(try ClassDumpService.dump(fileAt: chainedURL, allowExternalFallback: false)) {
            guard case ClassDumpError.unsupportedBuiltIn = $0 else {
                return XCTFail("应明确报告 chained fixups 不支持，实际为 \($0)")
            }
        }
    }

    func testNativeDumpWithCompiledObjectiveCFixture() throws {
        guard ExternalTool.clang.isAvailable else {
            throw XCTSkip("缺少 clang")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Fixture.m")
        let dylib = root.appendingPathComponent("Fixture.dylib")
        try """
        #import <Foundation/Foundation.h>
        @protocol FixtureProtocol <NSObject>
        - (void)performAction;
        @end
        @interface FixtureClass : NSObject <FixtureProtocol>
        @property (nonatomic, copy) NSString *title;
        - (void)performAction;
        @end
        @implementation FixtureClass
        - (void)performAction {}
        @end
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = try ExternalTool.clang.run([
            "-dynamiclib", "-fobjc-arc", source.path,
            "-framework", "Foundation", "-Wl,-no_fixup_chains", "-o", dylib.path
        ])
        guard compile.succeeded else {
            throw XCTSkip("当前链接器无法生成传统指针 fixture：\(compile.combinedOutput)")
        }

        let result = try ClassDumpService.dump(
            fileAt: dylib,
            allowExternalFallback: false
        )
        XCTAssertTrue(result.classNames.contains("FixtureClass"), result.headers)
        XCTAssertTrue(result.headers.contains("FixtureProtocol"), result.headers)
        XCTAssertTrue(result.headers.contains("@property"), result.headers)
    }

    func testExternalClassDumpReadsGeneratedHeaderFiles() throws {
        guard ExternalTool.clang.isAvailable, ExternalTool.classDump.isAvailable else {
            throw XCTSkip("缺少 clang 或 class-dump")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-external")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ExternalFixture.m")
        let dylib = root.appendingPathComponent("ExternalFixture.dylib")
        try """
        #import <Foundation/Foundation.h>
        @interface ExternalFixture : NSObject
        - (NSString *)fixtureName;
        @end
        @implementation ExternalFixture
        - (NSString *)fixtureName { return @"fixture"; }
        @end
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = try ExternalTool.clang.run([
            "-dynamiclib", "-fobjc-arc", source.path,
            "-framework", "Foundation", "-o", dylib.path
        ])
        guard compile.succeeded else {
            throw XCTSkip("无法编译外部 Class Dump fixture：\(compile.combinedOutput)")
        }

        let result = try ClassDumpService.dump(
            fileAt: dylib,
            preferExternal: true,
            allowExternalFallback: true
        )
        XCTAssertTrue(result.headers.contains("@interface ExternalFixture"), result.headers)
        XCTAssertTrue(result.classNames.contains("ExternalFixture"))
        XCTAssertTrue(result.classHeaders.contains { $0.name == "ExternalFixture" })
    }

    func testRealIPAClassDumpWhenFixturePathIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MACASSISTANT_CLASSDUMP_IPA"],
              FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("未提供 MACASSISTANT_CLASSDUMP_IPA")
        }
        let result = try ClassDumpService.dump(
            fileAt: URL(fileURLWithPath: path),
            allowExternalFallback: true
        )
        XCTAssertFalse(result.headers.isEmpty)
        XCTAssertFalse(result.classHeaders.isEmpty)
        XCTAssertGreaterThan(result.classNames.count, 10)
        XCTAssertNotNil(result.usedExternalTool)
    }
}
