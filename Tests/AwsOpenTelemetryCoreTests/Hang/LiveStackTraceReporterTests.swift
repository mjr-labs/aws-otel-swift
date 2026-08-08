import XCTest
@testable import AwsOpenTelemetryCore
#if !os(watchOS)
  import CrashReporter
#endif

// MARK: - NoopLiveStackTraceReporter Tests

final class NoopLiveStackTraceReporterTests: XCTestCase {
  func testInitialization() {
    let collector = NoopLiveStackTraceReporter(maxStackTraceLength: 5000)
    XCTAssertEqual(collector.maxStackTraceLength, 5000)
  }

  func testDefaultInitialization() {
    let collector = NoopLiveStackTraceReporter()
    XCTAssertEqual(collector.maxStackTraceLength, 10000)
  }

  func testGenerateLiveStackTrace() {
    let collector = NoopLiveStackTraceReporter()
    XCTAssertNil(collector.generateLiveStackTrace())
  }

  func testFormatStackTrace() {
    let collector = NoopLiveStackTraceReporter()
    let data = Data()

    let result = collector.formatStackTrace(rawStackTrace: data)

    XCTAssertEqual(result.message, "Stack trace collection not available")
    XCTAssertEqual(result.stacktrace, "Stack trace collection not supported on this platform")
  }

  func testFormatStackTraceWithData() {
    let collector = NoopLiveStackTraceReporter()
    let data = "some data".data(using: .utf8)!

    let result = collector.formatStackTrace(rawStackTrace: data)

    XCTAssertEqual(result.message, "Stack trace collection not available")
    XCTAssertEqual(result.stacktrace, "Stack trace collection not supported on this platform")
  }
}

#if !os(watchOS)

  // MARK: - PLStackTraceReporterTests Tests

  final class PLLiveStackTraceReporterTests: XCTestCase {
    var collector: PLLiveStackTraceReporter!

    override func setUp() {
      super.setUp()
      collector = PLLiveStackTraceReporter(maxStackTraceLength: 1000)
    }

    override func tearDown() {
      collector = nil
      super.tearDown()
    }

    func testInitialization() {
      XCTAssertEqual(collector.maxStackTraceLength, 1000)
      XCTAssertNotNil(collector.reporter)
    }

    func testDefaultInitialization() {
      let defaultCollector = PLLiveStackTraceReporter()
      XCTAssertEqual(defaultCollector.maxStackTraceLength, 10000)
    }

    func testGenerateLiveStackTrace() {
      XCTAssertNoThrow(collector.generateLiveStackTrace())
    }

    func testFormatStackTraceWithInvalidData() {
      let invalidData = "invalid crash report data".data(using: .utf8)!
      let result = collector.formatStackTrace(rawStackTrace: invalidData)

      XCTAssertEqual(result.message, "Hang detected at unknown location")
      XCTAssertTrue(result.stacktrace.contains("Failed to parse stack trace"))
    }

    func testFormatStackTraceWithEmptyData() {
      let emptyData = Data()
      let result = collector.formatStackTrace(rawStackTrace: emptyData)

      XCTAssertEqual(result.message, "Hang detected at unknown location")
      XCTAssertTrue(result.stacktrace.contains("Failed to parse stack trace"))
    }

    func testMaxStackTraceLengthTruncation() {
      let shortCollector = PLLiveStackTraceReporter(maxStackTraceLength: 10)
      let longData = String(repeating: "a", count: 1000).data(using: .utf8)!
      let result = shortCollector.formatStackTrace(rawStackTrace: longData)

      XCTAssertTrue(result.stacktrace.count <= 1000)
    }

    func testGetFirstFrameOfMainWithLibraryAndOffset() {
      let stacktrace = """
      Thread 0:
      0   libsystem_kernel.dylib              0x00000001dccb1658 0x1dccab000 + 26200
      1   Foundation                          0x000000018a9b4c2c 0x18a707000 + 2808876
      """

      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertEqual(result, "libsystem_kernel.dylib + 26200")
    }

    func testGetFirstFrameOfMainWithAppHang() {
      let stacktrace = """
      Thread 0:
      0   libsystem_kernel.dylib              0x00000001dccb1658 0x1dccab000 + 26200
      1   Foundation                          0x000000018a9b4c2c 0x18a707000 + 2808876
      2   AwsHackerNewsDemo                   0x0000000100714984 0x1006dc000 + 231812
      """

      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertEqual(result, "libsystem_kernel.dylib + 26200")
    }

    func testGetFirstFrameOfMainWithDifferentLibrary() {
      let stacktrace = """
      Thread 0:
      0   CoreFoundation                      0x000000018baf9d90 0x18ba8d000 + 445840
      1   libdispatch.dylib                   0x0000000193a27c6c 0x193a17000 + 68716
      """

      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertEqual(result, "CoreFoundation + 445840")
    }

    func testGetFirstFrameOfMainWithInsufficientComponents() {
      let stacktrace = """
      Thread 0:
      0   MyApp
      """

      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertEqual(result, "unknown location")
    }

    func testGetFirstFrameOfMainWithNoMainThread() {
      let stacktrace = "Some other thread info"
      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertNil(result)
    }

    func testGetFirstFrameOfMainWithEmptyStacktrace() {
      let stacktrace = ""
      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertNil(result)
    }

    func testGetFirstFrameOfMainWithMalformedStacktrace() {
      let stacktrace = "Thread 0:\n0"
      let result = collector.getFirstFrameOfMain(stacktrace: stacktrace)
      XCTAssertEqual(result, "unknown location")
    }

    func testFormatStackTraceWithNilReportString() {
      let malformedData = Data([0x00, 0x01, 0x02, 0x03])
      let result = collector.formatStackTrace(rawStackTrace: malformedData)

      XCTAssertEqual(result.message, "Hang detected at unknown location")
      XCTAssertTrue(result.stacktrace.contains("Failed to"))
    }
  }
#endif

// MARK: - StackTrace Struct Tests

final class StackTraceTests: XCTestCase {
  func testStackTraceStruct() {
    let stackTrace = StackTrace(message: "Test message", stacktrace: "Test stacktrace")
    XCTAssertEqual(stackTrace.message, "Test message")
    XCTAssertEqual(stackTrace.stacktrace, "Test stacktrace")
  }
}

// MARK: - Protocol Conformance Tests

final class LiveStackTraceReporterProtocolTests: XCTestCase {
  func testPLLiveStackTraceReporterConformsToProtocol() {
    #if !os(watchOS)
      let collector: LiveStackTraceReporter = PLLiveStackTraceReporter(maxStackTraceLength: 1000)
      XCTAssertEqual(collector.maxStackTraceLength, 1000)
      XCTAssertNoThrow(collector.generateLiveStackTrace())

      let data = Data()
      let result = collector.formatStackTrace(rawStackTrace: data)
      XCTAssertNotNil(result.message)
      XCTAssertNotNil(result.stacktrace)
    #endif
  }

  func testNoopStackTraceCollectorConformsToProtocol() {
    let collector: LiveStackTraceReporter = NoopLiveStackTraceReporter(maxStackTraceLength: 2000)
    XCTAssertEqual(collector.maxStackTraceLength, 2000)
    XCTAssertNil(collector.generateLiveStackTrace())

    let data = Data()
    let result = collector.formatStackTrace(rawStackTrace: data)
    XCTAssertEqual(result.message, "Stack trace collection not available")
    XCTAssertEqual(result.stacktrace, "Stack trace collection not supported on this platform")
  }
}

// MARK: - REC-327: truncation must preserve the app's Binary Images entry

#if !os(watchOS)
  final class TruncatePreservingAppImageTests: XCTestCase {
    /// Shaped like a real PLCrashReporter iOS report: header, threads, then the
    /// image list last — which is why a plain prefix() always loses it. The
    /// system images outnumber the app's, as they do on a device (200-400).
    private func report(threadPadding: Int, images: Int) -> String {
      var s = "Incident Identifier: TEST\nProcess:  ReconcilyFlagship [1]\n\n"
      for t in 0..<threadPadding {
        s += "Thread \(t):\n0   libsystem_kernel.dylib  0x0000000252 0x252 + 3152\n"
      }
      s += "\nBinary Images:\n"
      for i in 0..<images {
        s += "0x1a\(i) - 0x1b\(i) CoreFoundation arm64  <cfuuid\(i)> /System/CoreFoundation\n"
      }
      // The main executable carries the "+" marker.
      s += "0x104 - 0x105 +ReconcilyFlagship arm64  <APPUUID1234> /var/ReconcilyFlagship\n"
      return s
    }

    func testAppImageSurvivesTruncation() {
      let full = report(threadPadding: 400, images: 300)
      XCTAssertGreaterThan(full.count, 10_000, "fixture must actually need truncating")

      let out = PLLiveStackTraceReporter.truncatePreservingAppImage(full, limit: 10_000)

      // The point of the ticket: the UUID is present.
      XCTAssertTrue(out.contains("APPUUID1234"), "app UUID must survive: \(out.suffix(200))")
      XCTAssertTrue(out.contains("+ReconcilyFlagship"))
      // And the head is still there, so the hang is still diagnosable.
      XCTAssertTrue(out.hasPrefix("Incident Identifier: TEST"))
      XCTAssertTrue(out.contains("Thread 0:"))
      // Budget is respected — this must not become an unbounded payload.
      XCTAssertLessThanOrEqual(out.count, 10_000)
    }

    func testSystemImagesAreNotDraggedIn() {
      // The whole reason for splicing rather than raising the cap: we pay ~150
      // chars for the app line, not tens of KB for 300 system images.
      let full = report(threadPadding: 400, images: 300)
      let out = PLLiveStackTraceReporter.truncatePreservingAppImage(full, limit: 10_000)
      XCTAssertFalse(out.contains("cfuuid200"), "system images must not ride along")
    }

    func testShortReportIsUntouched() {
      let short = "Incident Identifier: TEST\nThread 0:\nBinary Images:\n0x1 - 0x2 +App arm64 <U> /App\n"
      XCTAssertEqual(PLLiveStackTraceReporter.truncatePreservingAppImage(short, limit: 10_000), short)
    }

    func testNoAppImageFallsBackToPlainPrefixRatherThanFailing() {
      // A report with no "+" line (or a malformed one) must degrade to exactly
      // the OLD behaviour — never worse than before the patch.
      var full = "Incident Identifier: TEST\n"
      full += String(repeating: "Thread 1:\n0 lib 0x1 0x1 + 1\n", count: 500)
      full += "\nBinary Images:\n0x1 - 0x2 CoreFoundation arm64 <sys> /System/CF\n"
      let out = PLLiveStackTraceReporter.truncatePreservingAppImage(full, limit: 10_000)
      XCTAssertEqual(out, String(full.prefix(10_000)))
    }

    func testNoBinaryImagesSectionAtAllFallsBack() {
      var full = "Incident Identifier: TEST\n"
      full += String(repeating: "Thread 1:\n0 lib 0x1 0x1 + 1\n", count: 500)
      let out = PLLiveStackTraceReporter.truncatePreservingAppImage(full, limit: 10_000)
      XCTAssertEqual(out, String(full.prefix(10_000)))
    }
  }
#endif
