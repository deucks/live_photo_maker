import 'live_photo_maker_platform_interface.dart';

export 'live_photo_maker_platform_interface.dart'
    show LivePhotoException, MotionSample;

class LivePhotoMaker {
  /// [coverImage] Still shown when the Live Photo isn't animating. Omit it
  /// and the key photo is lifted from the processed clip itself.
  /// [imagePath] Picture content of live photos
  /// [voicePath] Video content of live photos
  /// [startSeconds] Where in [voicePath] the kept window begins. The window
  /// is clamped so it always fits inside the source. Omit to take the middle.
  ///
  /// Throws [LivePhotoException] with the native failure reason when
  /// creation or the library save fails.
  static Future<bool> create({
    String? coverImage,
    String? imagePath,
    String? voicePath,
    required int width,
    required int height,
    double? startSeconds,
  }) async {
    return LivePhotoMakerPlatform.instance.create(
      coverImage: coverImage,
      imagePath: imagePath,
      voicePath: voicePath,
      width: width,
      height: height,
      startSeconds: startSeconds,
    );
  }

  /// Renders the Live Photo paired clip in one pass: takes
  /// [windowSeconds] of source from [startSeconds] and retimes it onto
  /// the ~0.92s paired duration at 1080x1920/60fps, bt709.
  ///
  /// The output matches the contract [create] looks for, so passing it
  /// straight to [create] copies it through without re-encoding.
  static Future<String> renderClip({
    required String sourcePath,
    required String outputPath,
    required double startSeconds,
    required double windowSeconds,
  }) {
    return LivePhotoMakerPlatform.instance.renderClip(
      sourcePath: sourcePath,
      outputPath: outputPath,
      startSeconds: startSeconds,
      windowSeconds: windowSeconds,
    );
  }

  /// Measures motion across a source window, or null if it could not be
  /// measured. Used to decide how fast a clip can safely play before
  /// iOS's wallpaper motion check rejects it.
  static Future<MotionSample?> measureMotion({
    required String sourcePath,
    required double startSeconds,
    required double windowSeconds,
  }) {
    return LivePhotoMakerPlatform.instance.measureMotion(
      sourcePath: sourcePath,
      startSeconds: startSeconds,
      windowSeconds: windowSeconds,
    );
  }
}
