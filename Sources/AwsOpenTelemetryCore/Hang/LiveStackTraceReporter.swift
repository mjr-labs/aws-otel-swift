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
#if !os(watchOS)
  import CrashReporter
#endif

public struct StackTrace {
  let message: String
  let stacktrace: String
}

public protocol LiveStackTraceReporter {
  var maxStackTraceLength: Int { get }
  func generateLiveStackTrace() -> Data?
  func formatStackTrace(rawStackTrace: Data) -> StackTrace
  init(maxStackTraceLength: Int)
}

#if !os(watchOS)
  public class PLLiveStackTraceReporter: LiveStackTraceReporter {
    let reporter: PLCrashReporter
    public let maxStackTraceLength: Int

    public required init(maxStackTraceLength: Int = 10 * 1000) {
      self.maxStackTraceLength = maxStackTraceLength
      let config = PLCrashReporterConfig(
        signalHandlerType: .BSD,
        symbolicationStrategy: [] // empty list means no symbolication, and implies a ~20 ms fetch time
        // To get on-device symbolication during development, set symbolicationStrategy to
        // - `.all` (2 sec blocking delay)
        // - `.symbolTable` (1 sec blocking delay)
      )
      // PLCrashReporter is designed for crash reports but we are able to take advantage of its live report feature,
      // which is perfect for collecting stack traces associated with app hangs. This does not interfere with other
      // crash reporters because we are not using the crash report feature.
      reporter = PLCrashReporter(configuration: config)
    }

    public func generateLiveStackTrace() -> Data? {
      return reporter.generateLiveReport()
    }

    public func formatStackTrace(rawStackTrace: Data) -> StackTrace {
      var stacktrace = "Failed to collect stack trace"
      var message = "Hang detected at unknown location"
      do {
        let crashReport = try PLCrashReport(data: rawStackTrace)
        if let fullStacktrace = PLCrashReportTextFormatter.stringValue(for: crashReport, with: PLCrashReportTextFormatiOS) {
          stacktrace = Self.truncatePreservingAppImage(fullStacktrace, limit: maxStackTraceLength)
          let firstFrame = getFirstFrameOfMain(stacktrace: stacktrace) ?? "unknown location"
          message = "Hang detected at \(firstFrame)"
        } else {
          AwsInternalLogger.error("PLLiveStackTraceReporter: Failed to format crash report to string")
        }
      } catch {
        AwsInternalLogger.error("PLLiveStackTraceReporter: Failed to parse crash report: \(error)")
        stacktrace = "Failed to parse stack trace: \(error)"
      }
      return StackTrace(message: message, stacktrace: stacktrace)
    }


    /// REC-327: truncate WITHOUT throwing away the app's own `Binary Images`
    /// entry — the only line that makes a symbolication provable.
    ///
    /// The report is `header + threads… + "Binary Images:" + one line per
    /// loaded image`. A plain `prefix(limit)` takes the head, so the image list
    /// — which lives at the very end — is always the first thing lost. Measured
    /// on live prod hang spans (2026-08-08): EVERY report is exactly 10,000
    /// chars, cut mid-frame around thread 12, and NOT ONE contains a
    /// `Binary Images` section. So no hang this estate has ever collected can
    /// be proven to match the build that produced it; two investigations
    /// (REC-263, REC-298) shipped that caveat independently.
    ///
    /// ⚠️ The fix is NOT simply a bigger limit, and the measurement is why. The
    /// image list is 200-400 lines of ~120 chars — tens of KB — to obtain ONE
    /// line of value: the app's own UUID. Raising the cap to fit it all would
    /// multiply every hang payload several-fold for that single datum, and the
    /// system images are already symbolicated by anyone who needs them.
    /// So: keep the head as before, and splice back only the app's own entry.
    ///
    /// The app's line is identified by the `+` marker PLCrashReporter puts on
    /// the main executable, which is exactly the "which binary is THIS build"
    /// question. If no such line is found the result is the plain prefix —
    /// unchanged behaviour, never worse than before.
    static func truncatePreservingAppImage(_ full: String, limit: Int) -> String {
      guard full.count > limit else { return full }

      let head = String(full.prefix(limit))
      guard let imagesRange = full.range(of: "Binary Images:") else { return head }

      // The main executable's line carries a "+" before the image name.
      let appLine = full[imagesRange.upperBound...]
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first { $0.contains(" +") }
      guard let appLine else { return head }

      let suffix = "\n\nBinary Images (app only — REC-327):\n" + appLine.trimmingCharacters(in: .whitespaces)
      // Keep the TOTAL within the caller's budget: the spliced tail is the
      // point of the exercise, so the head yields the room for it.
      let room = max(0, limit - suffix.count)
      return String(full.prefix(room)) + suffix
    }

    // For simplicity, we only do library name + offset to help with grouping. If we include the full first frame, then
    // unfortunately every exception message becomes unique.
    func getFirstFrameOfMain(stacktrace: String) -> String? {
      guard let firstFrameLine = stacktrace.components(separatedBy: "Thread 0:\n0").dropFirst().first?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) else {
        return nil
      }

      // Extract library name and offset from frame like:
      // "   libsystem_kernel.dylib              0x00000001dccb1658 0x1dccab000 + 26200"
      let components = firstFrameLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
      guard components.count >= 4,
            let libraryName = components.first,
            let offsetString = components.last else {
        return "unknown location"
      }

      return "\(libraryName) + \(offsetString)"
    }
  }
#endif

// Noop implementation for platforms where PLCrashReporter is not available
public class NoopLiveStackTraceReporter: LiveStackTraceReporter {
  public let maxStackTraceLength: Int

  public required init(maxStackTraceLength: Int = 10 * 1000) {
    self.maxStackTraceLength = maxStackTraceLength
  }

  public func generateLiveStackTrace() -> Data? {
    return nil
  }

  public func formatStackTrace(rawStackTrace: Data) -> StackTrace {
    return StackTrace(message: "Stack trace collection not available", stacktrace: "Stack trace collection not supported on this platform")
  }
}
