import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_photo_maker_platform_interface.dart';

/// An implementation of [LivePhotoMakerPlatform] that uses method channels.
class MethodChannelLivePhotoMaker extends LivePhotoMakerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('live_photo_maker');

  @override
  Future<bool> create({
    String? coverImage,
    String? imagePath,
    String? voicePath,
    required int width,
    required int height,
    double? startSeconds,
  }) async {
    assert(Platform.isIOS, 'Live photo can only be used on the iOS platform.');

    assert(
        ((imagePath ?? '').isNotEmpty && (voicePath ?? '').isEmpty) ||
            ((imagePath ?? '').isEmpty && (voicePath ?? '').isNotEmpty),
        "Either imagePath or voicePath should have a value, and both cannot be empty.");

    late String movPath;
    if ((voicePath ?? '').isNotEmpty) {
      movPath = voicePath!;
    } else {
      movPath = await methodChannel.invokeMethod("image_to_mov", [imagePath, width.toString(), height.toString()]);
    }

    try {
      final String result = await methodChannel.invokeMethod(
        "create_live_photo",
        <String, dynamic>{
          'videoPath': movPath,
          if (coverImage != null && coverImage.isNotEmpty)
            'coverImage': coverImage,
          if (startSeconds != null) 'startSeconds': startSeconds,
        },
      );
      return result == 'success';
    } on PlatformException catch (e) {
      throw LivePhotoException(e.message ?? 'Live Photo creation failed.');
    }
  }

  @override
  Future<String> renderClip({
    required String sourcePath,
    required String outputPath,
    required double startSeconds,
    required double windowSeconds,
  }) async {
    try {
      final String path = await methodChannel.invokeMethod(
        'render_clip',
        <String, dynamic>{
          'sourcePath': sourcePath,
          'outputPath': outputPath,
          'startSeconds': startSeconds,
          'windowSeconds': windowSeconds,
        },
      );
      return path;
    } on PlatformException catch (e) {
      throw LivePhotoException(e.message ?? 'Could not render the clip.');
    }
  }

  @override
  Future<MotionSample?> measureMotion({
    required String sourcePath,
    required double startSeconds,
    required double windowSeconds,
  }) async {
    try {
      final Map<dynamic, dynamic>? raw = await methodChannel.invokeMethod(
        'measure_motion',
        <String, dynamic>{
          'sourcePath': sourcePath,
          'startSeconds': startSeconds,
          'windowSeconds': windowSeconds,
        },
      );
      if (raw == null) return null;
      return MotionSample(
        meanYDiff: (raw['meanYDiff'] as num).toDouble(),
        fps: (raw['fps'] as num).toDouble(),
        frameCount: (raw['frameCount'] as num).toInt(),
      );
    } on PlatformException {
      // Measurement is advisory; callers fall back to a default cap.
      return null;
    }
  }
}
