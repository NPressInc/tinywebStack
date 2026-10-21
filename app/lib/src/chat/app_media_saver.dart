import 'gal_media_saver.dart';
import 'media_saver.dart';

/// Production photo-library saver (Gal); inject in UI, use fakes in tests.
final MediaSaver appMediaSaver = GalMediaSaver();
