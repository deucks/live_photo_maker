import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'live_photo_maker_method_channel.dart';

/// Thrown when the native side reports why a Live Photo could not be
/// created — the message names the failing stage (retime, resize, key
/// photo, metadata write, library save).
class LivePhotoException implements Exception {
  LivePhotoException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class LivePhotoMakerPlatform extends PlatformInterface {
  /// Constructs a LivePhotoMakerPlatform.
  LivePhotoMakerPlatform() : super(token: _token);

  static final Object _token = Object();

  static final LivePhotoMakerPlatform _instance = MethodChannelLivePhotoMaker();

  /// The default instance of [LivePhotoMakerPlatform] to use.
  ///
  /// Defaults to [MethodChannelLivePhotoMaker].
  static LivePhotoMakerPlatform get instance => _instance;


  Future<bool> create({
    String? coverImage,
    String? imagePath,
    String? voicePath,
    required int width,
    required int height,
    double? startSeconds,
  }) {
    throw UnimplementedError('create() has not been implemented.');
  }

  Future<String> renderClip({
    required String sourcePath,
    required String outputPath,
    required double startSeconds,
    required double windowSeconds,
  }) {
    throw UnimplementedError('renderClip() has not been implemented.');
  }

  Future<MotionSample?> measureMotion({
    required String sourcePath,
    required double startSeconds,
    required double windowSeconds,
  }) {
    throw UnimplementedError('measureMotion() has not been implemented.');
  }
}

/// Motion statistics for a source window, measured on a 160-wide decode
/// so the numbers are comparable with ffmpeg's `signalstats` YDIF.
class MotionSample {
  const MotionSample({
    required this.meanYDiff,
    required this.fps,
    required this.frameCount,
  });

  /// Mean absolute luma change between consecutive frames.
  final double meanYDiff;

  /// Frame rate measured from presentation timestamps.
  final double fps;

  final int frameCount;

  /// Motion per second of source — the scale-invariant quantity a speed
  /// budget should be divided by.
  double get motionRate => meanYDiff * fps;
}
