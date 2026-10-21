/// Saves decrypted chat media to the device photo library.
abstract class MediaSaver {
  Future<void> saveImage(String filePath);

  Future<void> saveVideo(String filePath);
}

class MediaSavePermissionDenied implements Exception {
  MediaSavePermissionDenied([this.message = 'Photo library permission denied']);

  final String message;

  @override
  String toString() => message;
}
