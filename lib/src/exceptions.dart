import 'package:flutter/services.dart';

/// Base class for all fluidaudio_dart errors.
///
/// [code] is the native error type name (e.g. `AsrModelsError`,
/// `DownloadError`); [message] carries the real Swift error description.
class FluidAudioException implements Exception {
  const FluidAudioException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'FluidAudioException($code): $message';
}

/// A model download or cache operation failed (network disabled, rate limit,
/// missing model, HuggingFace error).
class FluidDownloadException extends FluidAudioException {
  const FluidDownloadException(super.code, super.message);
}

/// The referenced native instance no longer exists (disposed or never created).
class FluidInstanceGoneException extends FluidAudioException {
  const FluidInstanceGoneException(super.code, super.message);
}

/// Converts a [PlatformException] thrown by a pigeon call into a typed
/// [FluidAudioException].
Never rethrowTyped(Object error) {
  if (error is PlatformException) {
    final code = error.code;
    final message = error.message ?? 'unknown native error';
    if (code.contains('Download')) {
      throw FluidDownloadException(code, message);
    }
    if (code == 'InstanceNotFound') {
      throw FluidInstanceGoneException(code, message);
    }
    throw FluidAudioException(code, message);
  }
  // ignore: only_throw_errors
  throw error;
}

/// Runs [action], converting [PlatformException]s to typed exceptions.
Future<T> wrapPlatformErrors<T>(Future<T> Function() action) async {
  try {
    return await action();
  } catch (error) {
    rethrowTyped(error);
  }
}
