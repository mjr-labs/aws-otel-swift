/*
 * Copyright Amazon.com, Inc. or its affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

import Foundation
import OpenTelemetryApi

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// One main-thread run loop cycle being measured as a candidate hang.
///
/// The two clocks are deliberately different. `wallStart` exists only to
/// timestamp the reported span, because that is what a span requires. The
/// measurement itself is taken from `uptimeStart`, which is monotonic:
/// `CFAbsoluteTimeGetCurrent()` is the wall clock and can be stepped by an NTP
/// correction part-way through a cycle, and that step lands directly in the
/// reported duration.
struct HangWindow {
  let wallStart: CFAbsoluteTime
  let uptimeStart: DispatchTime

  var elapsed: CFAbsoluteTime {
    let now = DispatchTime.now().uptimeNanoseconds
    let start = uptimeStart.uptimeNanoseconds
    guard now > start else { return 0 }
    return CFAbsoluteTime(now - start) / 1_000_000_000
  }
}

/// Instrumentation for detecting and reporting application hangs
public class AwsHangInstrumentation {
  let tracer: Tracer
  let logger: Logger

  let hangThreshold: CFAbsoluteTime = 0.25 // 250ms
  let hangPredetectionThreshold: CFAbsoluteTime

  /// Upper bound on a duration we are willing to call a hang.
  ///
  /// iOS terminates a foreground app whose main thread stops responding. The
  /// most permissive documented watchdog limit is around 20 seconds (launch,
  /// `0x8badf00d`); other lifecycle transitions are killed nearer 10. A block
  /// that a live app actually SURVIVES therefore cannot approach a minute.
  /// Anything longer did not measure a hang - it measured a stopped process or
  /// a stepped clock - and letting it through corrupts every maximum and
  /// percentile drawn from the metric afterwards.
  let maxPlausibleHangDuration: CFAbsoluteTime

  var _hangWindow: HangWindow?
  var _rawStackTrace: Data?
  var _reportInFlight = false
  var _isForeground = true
  var _lifecycleObservers: [NSObjectProtocol] = []
  let syncQueue = DispatchQueue(label: "\(AwsInstrumentationScopes.HANG).sync")
  let watchdogQueue = DispatchQueue(label: AwsInstrumentationScopes.HANG, qos: .userInitiated)
  let reportingQueue = DispatchQueue(label: "\(AwsInstrumentationScopes.HANG).report", qos: .utility)

  var hangWindow: HangWindow? {
    get { syncQueue.sync { _hangWindow } }
    set { syncQueue.sync { _hangWindow = newValue } }
  }

  var rawStackTrace: Data? {
    get { syncQueue.sync { _rawStackTrace } }
    set { syncQueue.sync { _rawStackTrace = newValue } }
  }

  var reportInFlight: Bool {
    get { syncQueue.sync { _reportInFlight } }
    set { syncQueue.sync { _reportInFlight = newValue } }
  }

  /// Whether the app is between `willEnterForeground` and `didEnterBackground`.
  var isForeground: Bool {
    syncQueue.sync { _isForeground }
  }

  let stackTraceCollector: LiveStackTraceReporter
  var monitoringTimer: DispatchSourceTimer?

  static let shared = AwsHangInstrumentation()

  public init(
    stackTraceCollector: LiveStackTraceReporter? = nil,
    maxPlausibleHangDuration: CFAbsoluteTime = 60.0
  ) {
    let collector: LiveStackTraceReporter
    if let stackTraceCollector {
      collector = stackTraceCollector
    } else {
      #if !os(watchOS)
        collector = PLLiveStackTraceReporter()
      #else
        collector = NoopLiveStackTraceReporter()
      #endif
    }
    hangPredetectionThreshold = hangThreshold * 2 / 3 // lower threshold to collect stacktrace during ongoing hangs
    self.maxPlausibleHangDuration = maxPlausibleHangDuration
    tracer = OpenTelemetry.instance.tracerProvider.get(instrumentationName: AwsInstrumentationScopes.HANG)
    logger = OpenTelemetry.instance.loggerProvider.get(instrumentationScopeName: AwsInstrumentationScopes.HANG)
    self.stackTraceCollector = collector
    observeAppLifecycle()
    startWatchdog()
  }

  deinit {
    let observers = syncQueue.sync { _lifecycleObservers }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func startWatchdog() {
    DispatchQueue.main.async {
      self.setupRunLoopObserver()
    }

    watchdogQueue.async {
      self.startBackgroundMonitoring()
    }
  }

  /// Track whether the app is in the foreground, and discard any measurement
  /// that is open across the transition.
  ///
  /// `didEnterBackground` is the load-bearing half, and it has to be this
  /// notification rather than `willEnterForeground`: it is delivered while the
  /// app is still running, so it can close the open window BEFORE the process
  /// is suspended. A resume notification arrives too late to help - it is
  /// dispatched in a later run loop pass, after the interrupted cycle has
  /// already completed and reported.
  ///
  /// Note that a process launched directly into the background is assumed
  /// foreground here (`UIApplication.shared` is unavailable to app extensions,
  /// so it cannot be consulted). `maxPlausibleHangDuration` is the backstop for
  /// that case.
  func observeAppLifecycle() {
    #if canImport(UIKit) && !os(watchOS)
      let center = NotificationCenter.default
      // `queue: nil` delivers synchronously on the posting thread, which for
      // these notifications is the main thread. An OperationQueue would defer
      // the block to a later pass and reintroduce the race described above.
      let background = center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.setForeground(false)
      }
      let foreground = center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.setForeground(true)
      }
      syncQueue.sync { _lifecycleObservers = [background, foreground] }
    #endif
  }

  func setForeground(_ foreground: Bool) {
    syncQueue.sync {
      _isForeground = foreground
      // Whatever was open spans a foreground/background transition, so it may
      // span a suspension. It cannot be trusted and is not reported.
      _hangWindow = nil
      _rawStackTrace = nil
    }
  }

  // The run loop observer gives us hang boundaries precisely: `afterWaiting`
  // opens a cycle of main-thread work and `beforeWaiting` closes it.
  //
  // What it does NOT do on its own is survive the app being moved to the
  // background, and the comment here used to claim that it did. iOS suspends a
  // backgrounded process wherever it happens to be. If that is mid-cycle, the
  // run loop resumes minutes or hours later and the next `beforeWaiting` bills
  // the entire suspension as one continuous main-thread block - in production
  // that produced a single reported "hang" of three and a half hours. Hence the
  // explicit foreground tracking above: no window is opened while the app is
  // backgrounded, and any window open across a transition is discarded.
  func setupRunLoopObserver() {
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { [weak self] _, activity in
      self?.handleRunLoopActivity(activity)
    }

    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
  }

  func handleRunLoopActivity(_ activity: CFRunLoopActivity) {
    if activity == CFRunLoopActivity.afterWaiting {
      beginHangWindow()
    } else if activity == CFRunLoopActivity.beforeWaiting {
      endHangWindow()
    }
  }

  func beginHangWindow() {
    // A backgrounded app can be suspended at any moment, so a window opened now
    // would measure the suspension rather than the main thread.
    guard isForeground else { return }
    hangWindow = HangWindow(wallStart: CFAbsoluteTimeGetCurrent(), uptimeStart: DispatchTime.now())
  }

  func endHangWindow() {
    guard let window = hangWindow else {
      AwsInternalLogger.debug("Activity is BeforeWaiting without an open hang window")
      return
    }

    let hangDuration = window.elapsed
    if hangDuration >= hangThreshold {
      if hangDuration <= maxPlausibleHangDuration {
        reportHang(startTime: window.wallStart, endTime: window.wallStart + hangDuration)
      } else {
        AwsInternalLogger.debug("Discarding implausible hang of \(hangDuration)s: the process was stopped, not the main thread")
      }
    }
    hangWindow = nil // if main thread is resolved, then there is no ongoing hang anymore
    rawStackTrace = nil // if main thread is resolved, then any cached stack trace is no longer relevant
  }

  // We need to use the "background ping" strategy to preemptively collect the live stack
  // trace before the main thread has recovered. This must be done from a background thread
  // because the main thread is obviously unavailable during a hang.
  func startBackgroundMonitoring() {
    monitoringTimer = DispatchSource.makeTimerSource(queue: watchdogQueue)
    monitoringTimer?.schedule(deadline: .now(), repeating: .milliseconds(100))
    monitoringTimer?.setEventHandler { [weak self] in
      self?.checkForOngoingHang()
    }
    monitoringTimer?.resume()
  }

  func checkForOngoingHang() {
    // There must be an ongoing hang
    guard let window = hangWindow else {
      return
    }

    let hangDuration = window.elapsed

    // We only need to record stack trace once per hang
    guard rawStackTrace == nil else {
      return
    }

    // Collect the live stack trace because there is an ongoing hang that is likely to exceed our hang threshold
    if hangDuration >= hangPredetectionThreshold { // We rely on LiveStackTraceReporter to safely generate live reports
      guard let liveReportData = stackTraceCollector.generateLiveStackTrace() else {
        AwsInternalLogger.debug("Failed to generate live stack trace")
        return
      }
      rawStackTrace = liveReportData
    }
  }

  func reportHang(startTime: CFAbsoluteTime, endTime: CFAbsoluteTime) {
    // If a report is still being formatted, do not start another one: a slow
    // report must never be able to re-trip the detector.
    guard !reportInFlight else {
      AwsInternalLogger.debug("Hang report already in flight; skipping")
      return
    }
    if let stackTrace = rawStackTrace {
      reportInFlight = true
      // Formatting runs off the main thread: PLCrashReport parsing plus text
      // formatting can take over a second on device, which exceeds
      // hangThreshold and would itself be detected as a fresh hang if run on
      // the main queue.
      reportingQueue.async {
        defer { self.reportInFlight = false }
        let span = self.tracer.spanBuilder(spanName: AwsHangSemConv.name)
          .setStartTime(time: Date(timeIntervalSinceReferenceDate: startTime))
          .setAttribute(key: AwsHangSemConv.type, value: "hang")
          .startSpan()

        let liveStackTrace = self.stackTraceCollector.formatStackTrace(rawStackTrace: stackTrace)
        span.setAttribute(key: AwsHangSemConv.message, value: liveStackTrace.message)
        span.setAttribute(key: AwsHangSemConv.stacktrace, value: liveStackTrace.stacktrace)
        span.end(time: Date(timeIntervalSinceReferenceDate: endTime))
      }
    } else {
      let span = tracer.spanBuilder(spanName: AwsHangSemConv.name)
        .setStartTime(time: Date(timeIntervalSinceReferenceDate: startTime))
        .setAttribute(key: AwsHangSemConv.type, value: "hang")
        .setAttribute(key: AwsHangSemConv.message, value: "Hang detected at unknown location")
        .setAttribute(key: AwsHangSemConv.stacktrace, value: "No stack trace captured")
        .startSpan()
      span.end(time: Date(timeIntervalSinceReferenceDate: endTime))
    }
  }
}
