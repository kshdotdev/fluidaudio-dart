import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Maps Swift errors to PigeonError, preserving the real error message
/// (unlike the Rust bridge, which collapses everything to -1).
enum ErrorMapping {
  static func map(_ error: Error) -> PigeonError {
    let message =
      (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    return PigeonError(
      code: String(describing: type(of: error)),
      message: message,
      details: nil
    )
  }

  static func instanceNotFound(_ id: Int64, kind: String) -> PigeonError {
    PigeonError(
      code: "InstanceNotFound",
      message: "No live \(kind) instance with id \(id); it was disposed or never created.",
      details: nil
    )
  }
}
