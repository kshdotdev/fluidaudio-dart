#
# CocoaPods fallback for apps not yet using Flutter's Swift Package Manager
# integration (SPM is the primary, recommended path).
#
# NOTE: the FluidAudio pod on the CocoaPods trunk lags behind GitHub releases.
# If `pod install` resolves an old FluidAudio, add an override to your Podfile:
#   pod 'FluidAudio', :git => 'https://github.com/FluidInference/FluidAudio.git', :tag => 'v0.15.5'
#
Pod::Spec.new do |s|
  s.name             = 'fluidaudio_dart'
  s.version          = '0.1.0'
  s.summary          = 'Flutter bindings for FluidAudio: on-device ASR, VAD, diarization and TTS (CoreML/ANE).'
  s.description      = <<-DESC
Flutter/Dart bindings for the FluidAudio Swift library. On-device speech-to-text
(Parakeet, Qwen3), voice activity detection, speaker diarization, and text-to-speech
on Apple platforms via CoreML and the Apple Neural Engine.
                       DESC
  s.homepage         = 'https://github.com/kshdotdev/fluidaudio-dart'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Kauan Guesser' => 'kauan.guesser.c@conceptatech.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'fluidaudio_dart/Sources/fluidaudio_dart/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.dependency 'FluidAudio', '>= 0.15.5'
  s.ios.deployment_target = '17.0'
  s.osx.deployment_target = '14.0'

  # FluidAudio's CoreML models are Apple Silicon only.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS' => 'x86_64 i386' }
  s.swift_version = '5.10'
end
