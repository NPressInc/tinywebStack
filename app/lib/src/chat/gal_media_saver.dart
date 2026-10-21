import 'package:gal/gal.dart';

import 'media_saver.dart';

class GalMediaSaver implements MediaSaver {
  Future<void> _ensureAlbumAccess() async {
    if (await Gal.hasAccess(toAlbum: true)) {
      return;
    }
    final granted = await Gal.requestAccess(toAlbum: true);
    if (!granted) {
      throw MediaSavePermissionDenied();
    }
  }

  @override
  Future<void> saveImage(String filePath) async {
    await _ensureAlbumAccess();
    try {
      await Gal.putImage(filePath);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        throw MediaSavePermissionDenied();
      }
      rethrow;
    }
  }

  @override
  Future<void> saveVideo(String filePath) async {
    await _ensureAlbumAccess();
    try {
      await Gal.putVideo(filePath);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        throw MediaSavePermissionDenied();
      }
      rethrow;
    }
  }
}
