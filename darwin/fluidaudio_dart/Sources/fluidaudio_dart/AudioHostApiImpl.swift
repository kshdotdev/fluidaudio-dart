import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Audio conversion utilities (FluidAudio's `AudioConverter` + `AudioWAV`).
final class AudioHostApiImpl: AudioHostApi {
  func resampleFile(
    path: String, completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard FileManager.default.fileExists(atPath: path) else {
      completion(
        .failure(PigeonError(code: "FileNotFound", message: "No file at \(path)", details: nil)))
      return
    }
    Task {
      do {
        let samples = try AudioConverter().resampleAudioFile(path: path)
        completion(.success(AudioBridge.typedData(from: samples)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func resample(
    float32Samples: FlutterStandardTypedData, fromRate: Double,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    let samples = AudioBridge.floats(from: float32Samples)
    Task {
      do {
        let resampled = try AudioConverter().resample(samples, from: fromRate)
        completion(.success(AudioBridge.typedData(from: resampled)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func encodeWav(
    float32Samples: FlutterStandardTypedData, sampleRate: Double,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    let samples = AudioBridge.floats(from: float32Samples)
    do {
      let wav = try AudioWAV.data(from: samples, sampleRate: sampleRate)
      completion(.success(FlutterStandardTypedData(bytes: wav)))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }
}
