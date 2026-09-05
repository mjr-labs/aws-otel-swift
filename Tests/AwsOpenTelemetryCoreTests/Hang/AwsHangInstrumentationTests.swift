import XCTest
@testable import AwsOpenTelemetryCore
@testable import TestUtils
import OpenTelemetryApi
import OpenTelemetrySdk

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

class MockStackTraceCollector: LiveStackTraceReporter {
  var maxStackTraceLength: Int
  var shouldReturnStackTrace: Bool = true
  var mockStackTraceData: Data = "mock stack trace data".data(using: .utf8)!
  var mockStackTrace: StackTrace = .init(
    message: "Hang detected at MockFunction",
    stacktrace: "Thread 0:\n0 MockFunction + 123\n1 AnotherFunction + 456"
  )
  var formattedOnMainThread: Bool?
  var formatCallCount = 0
  var formatBlocker: DispatchSemaphore?

  required init(maxStackTraceLength: Int = 10000) {
    self.maxStackTraceLength = maxStackTraceLength
  }

  func generateLiveStackTrace() -> Data? {
    return shouldReturnStackTrace ? mockStackTraceData : nil
  }

  func formatStackTrace(rawStackTrace: Data) -> StackTrace {
    formattedOnMainThread = Thread.isMainThread
    formatCallCount += 1
    formatBlocker?.wait()
    return mockStackTrace
  }
}

final class AwsHangInstrumentationTests: XCTestCase {
  var mockStackTraceCollector: MockStackTraceCollector!
  var spanExporter: InMemorySpanExporter!
  var instrumentation: AwsHangInstrumentation!

  override func setUp() {
    super.setUp()
    mockStackTraceCollector = MockStackTraceCollector()
    spanExporter = InMemorySpanExporter.register()
    instrumentation = AwsHangInstrumentation(stackTraceCollector: mockStackTraceCollector)
  }

  override func tearDown() {
    spanExporter.clear()
    instrumentation = nil
    mockStackTraceCollector = nil
    spanExporter = nil
    super.tearDown()
  }

  // SimpleSpanProcessor hands spans to the exporter on its own queue, so spans
  // are not visible immediately after span.end(); poll with a deadline.
  private func waitForExportedSpanCount(_ count: Int, timeout: TimeInterval = 1.0) {
    let deadline = Date().addingTimeInterval(timeout)
    while spanExporter.getExportedSpans().count < count, Date() < deadline {
      usleep(10000)
    }
  }

  // A window whose measurement started `seconds` ago, without having to block
  // the test thread for that long. The uptime clock is the one that is read.
  private func window(startedSecondsAgo seconds: CFAbsoluteTime) -> HangWindow {
    let nowUptime = DispatchTime.now().uptimeNanoseconds
    let offset = UInt64(seconds * 1_000_000_000)
    return HangWindow(
      wallStart: CFAbsoluteTimeGetCurrent() - seconds,
      uptimeStart: DispatchTime(uptimeNanoseconds: nowUptime > offset ? nowUptime - offset : 0)
    )
  }

  // Give the span processor a chance to hand anything over before asserting that
  // it did not. Kept well under hangThreshold so blocking here cannot itself be
  // picked up as a hang by any other live instrumentation instance.
  private func settle(_ seconds: TimeInterval = 0.15) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      usleep(10000)
    }
  }

  func testInitialization() {
    XCTAssertEqual(instrumentation.hangThreshold, 0.25)
    XCTAssertEqual(instrumentation.hangPredetectionThreshold, 0.25 * 2 / 3)
    XCTAssertNotNil(instrumentation.stackTraceCollector)
    XCTAssertEqual(instrumentation.maxPlausibleHangDuration, 60.0)
    XCTAssertNil(instrumentation.hangWindow)
    XCTAssertNil(instrumentation.rawStackTrace)
    XCTAssertTrue(instrumentation.isForeground)
  }

  func testCheckForOngoingHangWithoutHangStart() {
    instrumentation.hangWindow = nil
    instrumentation.checkForOngoingHang()
    XCTAssertNil(instrumentation.rawStackTrace)
  }

  func testCheckForOngoingHangWithExistingStackTrace() {
    instrumentation.hangWindow = window(startedSecondsAgo: 0)
    instrumentation.rawStackTrace = "existing".data(using: .utf8)!

    instrumentation.checkForOngoingHang()

    XCTAssertEqual(instrumentation.rawStackTrace, "existing".data(using: .utf8)!)
  }

  func testCheckForOngoingHangBelowThreshold() {
    instrumentation.hangWindow = window(startedSecondsAgo: 0.1)
    instrumentation.rawStackTrace = nil

    instrumentation.checkForOngoingHang()

    XCTAssertNil(instrumentation.rawStackTrace)
  }

  func testCheckForOngoingHangAboveThreshold() {
    instrumentation.hangWindow = window(startedSecondsAgo: 0.2)
    instrumentation.rawStackTrace = nil
    mockStackTraceCollector.shouldReturnStackTrace = true

    instrumentation.checkForOngoingHang()

    XCTAssertNotNil(instrumentation.rawStackTrace)
    XCTAssertEqual(instrumentation.rawStackTrace, mockStackTraceCollector.mockStackTraceData)
  }

  func testReportHangWithStackTrace() {
    let startTime: CFAbsoluteTime = 12345.0
    let endTime: CFAbsoluteTime = 12345.5
    let testStackTrace = "test stack trace".data(using: .utf8)!

    instrumentation.rawStackTrace = testStackTrace
    instrumentation.reportHang(startTime: startTime, endTime: endTime)

    // Formatting and span creation happen on reportingQueue; drain it, then
    // wait for the processor to hand the span to the exporter.
    instrumentation.reportingQueue.sync {}
    waitForExportedSpanCount(1)

    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)

    let span = spanExporter.getExportedSpans().first!
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.attributes["exception.type"]?.description, "hang")
    XCTAssertEqual(span.attributes["exception.message"]?.description, mockStackTraceCollector.mockStackTrace.message)
    XCTAssertEqual(span.attributes["exception.stacktrace"]?.description, mockStackTraceCollector.mockStackTrace.stacktrace)
  }

  func testReportHangFormatsOffMainThread() {
    instrumentation.rawStackTrace = "test stack trace".data(using: .utf8)!
    instrumentation.reportHang(startTime: 12345.0, endTime: 12345.5)

    instrumentation.reportingQueue.sync {}

    XCTAssertEqual(mockStackTraceCollector.formattedOnMainThread, false)
  }

  func testReportHangSuppressedWhileReportInFlight() {
    let blocker = DispatchSemaphore(value: 0)
    mockStackTraceCollector.formatBlocker = blocker
    instrumentation.rawStackTrace = "test stack trace".data(using: .utf8)!

    // First report starts formatting and blocks on the semaphore.
    instrumentation.reportHang(startTime: 12345.0, endTime: 12345.5)

    // Wait until formatting has actually begun before attempting the second report.
    let formatStarted = XCTestExpectation(description: "Formatting started")
    DispatchQueue.global().async {
      while self.mockStackTraceCollector.formatCallCount == 0 {
        usleep(1000)
      }
      formatStarted.fulfill()
    }
    wait(for: [formatStarted], timeout: 1.0)

    // A hang detected while the first report is still formatting must be dropped.
    instrumentation.reportHang(startTime: 12346.0, endTime: 12346.5)

    blocker.signal()
    instrumentation.reportingQueue.sync {}
    waitForExportedSpanCount(1)

    XCTAssertEqual(mockStackTraceCollector.formatCallCount, 1)
    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)
    XCTAssertFalse(instrumentation.reportInFlight)
  }

  func testReportHangWithoutStackTrace() {
    let startTime: CFAbsoluteTime = 12345.0
    let endTime: CFAbsoluteTime = 12345.5

    instrumentation.rawStackTrace = nil
    instrumentation.reportHang(startTime: startTime, endTime: endTime)

    let expectation = XCTestExpectation(description: "Span creation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)

    let span = spanExporter.getExportedSpans().first!
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.attributes["exception.type"]?.description, "hang")
    XCTAssertEqual(span.attributes["exception.message"]?.description, "Hang detected at unknown location")
    XCTAssertEqual(span.attributes["exception.stacktrace"]?.description, "No stack trace captured")
  }

  // MARK: - Suspension is not a hang

  // The control for every test below it: with nothing else intervening, a window
  // this long IS reported. Without this, a fix that simply stopped reporting
  // would pass the suppression tests.
  func testHangIsReportedWhenNothingIntervenes() {
    instrumentation.hangWindow = window(startedSecondsAgo: 0.4)

    instrumentation.endHangWindow()
    waitForExportedSpanCount(1)

    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)
    XCTAssertEqual(spanExporter.getExportedSpans().first?.name, "device.hang")
  }

  // The defect: iOS suspends a backgrounded process mid-run-loop-cycle, and the
  // cycle completes on resume hours later.
  func testNoHangReportedAcrossBackgroundSuspension() {
    // afterWaiting - an ordinary foreground cycle opens.
    instrumentation.handleRunLoopActivity(.afterWaiting)
    XCTAssertNotNil(instrumentation.hangWindow)

    // didEnterBackground, delivered while the app is still running.
    instrumentation.setForeground(false)
    XCTAssertNil(instrumentation.hangWindow)

    // The process is suspended here for an arbitrarily long time, then resumes
    // and finishes the interrupted cycle.
    instrumentation.handleRunLoopActivity(.beforeWaiting)
    settle()

    XCTAssertEqual(spanExporter.getExportedSpans().count, 0)
  }

  // Even a window that was already long when the app backgrounded is dropped
  // rather than reported, so nothing is billed up to the moment of suspension.
  func testOpenWindowIsDiscardedOnBackgrounding() {
    instrumentation.hangWindow = window(startedSecondsAgo: 0.4)
    instrumentation.rawStackTrace = "cached".data(using: .utf8)!

    instrumentation.setForeground(false)
    instrumentation.endHangWindow()
    settle()

    XCTAssertNil(instrumentation.hangWindow)
    XCTAssertNil(instrumentation.rawStackTrace)
    XCTAssertEqual(spanExporter.getExportedSpans().count, 0)
  }

  // A backgrounded app can be suspended at any moment, so no window is opened at
  // all while it is in the background.
  func testNoWindowOpenedWhileBackgrounded() {
    instrumentation.setForeground(false)

    instrumentation.handleRunLoopActivity(.afterWaiting)
    XCTAssertNil(instrumentation.hangWindow)

    instrumentation.handleRunLoopActivity(.beforeWaiting)
    settle()

    XCTAssertEqual(spanExporter.getExportedSpans().count, 0)
  }

  // ...and measurement resumes on return, rather than being wedged off for the
  // rest of the process lifetime.
  func testMeasurementResumesAfterReturningToForeground() {
    instrumentation.setForeground(false)
    instrumentation.setForeground(true)

    instrumentation.handleRunLoopActivity(.afterWaiting)

    XCTAssertTrue(instrumentation.isForeground)
    XCTAssertNotNil(instrumentation.hangWindow)
  }

  #if canImport(UIKit) && !os(watchOS)
    // Proves the lifecycle notifications are actually wired to setForeground,
    // and not merely that setForeground behaves when called by a test.
    func testAppLifecycleNotificationsDriveForegroundState() {
      instrumentation.handleRunLoopActivity(.afterWaiting)
      XCTAssertNotNil(instrumentation.hangWindow)

      NotificationCenter.default.post(
        name: UIApplication.didEnterBackgroundNotification, object: nil
      )
      XCTAssertFalse(instrumentation.isForeground)
      XCTAssertNil(instrumentation.hangWindow)

      NotificationCenter.default.post(
        name: UIApplication.willEnterForegroundNotification, object: nil
      )
      XCTAssertTrue(instrumentation.isForeground)
    }
  #endif

  // MARK: - Plausibility ceiling

  // The backstop for any stall we get no lifecycle notification for: a process
  // stopped by the debugger, a background launch, a stepped clock.
  func testImplausiblyLongHangIsDiscarded() {
    let strict = AwsHangInstrumentation(
      stackTraceCollector: mockStackTraceCollector, maxPlausibleHangDuration: 0.3
    )
    strict.hangWindow = window(startedSecondsAgo: 0.4)

    strict.endHangWindow()
    settle()

    XCTAssertNil(strict.hangWindow)
    XCTAssertEqual(spanExporter.getExportedSpans().count, 0)
  }

  // MARK: - Duration is measured on the monotonic clock

  // wallStart is a span timestamp, not a measurement. If the duration were
  // computed from it, this window would read as decades rather than ~120ms.
  func testElapsedIgnoresTheWallClockStart() {
    let w = HangWindow(wallStart: 0, uptimeStart: DispatchTime.now())

    usleep(120_000)

    XCTAssertEqual(w.elapsed, 0.12, accuracy: 0.1)
  }

  func testSharedInstance() {
    let shared1 = AwsHangInstrumentation.shared
    let shared2 = AwsHangInstrumentation.shared

    XCTAssertTrue(shared1 === shared2)
  }

  func testQueueConfiguration() {
    XCTAssertNotNil(instrumentation.syncQueue)
    XCTAssertNotNil(instrumentation.watchdogQueue)

    let syncQueueLabel = instrumentation.syncQueue.label
    let watchdogQueueLabel = instrumentation.watchdogQueue.label

    XCTAssertTrue(syncQueueLabel.contains(AwsInstrumentationScopes.HANG))
    XCTAssertEqual(watchdogQueueLabel, AwsInstrumentationScopes.HANG)
  }
}
