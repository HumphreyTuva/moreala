import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// Handles on-device caching of walkthrough photo packages so repeat
/// study sessions read from disk instead of re-downloading from R2.
///
/// Layout on disk:
///   <appDocsDir>/moreala_cache/<modelId>/stamp.json   { updatedAt }
///   <appDocsDir>/moreala_cache/<modelId>/<photoPointId>_forward.webp
///   <appDocsDir>/moreala_cache/<modelId>/<photoPointId>_left.webp
///   <appDocsDir>/moreala_cache/<modelId>/<photoPointId>_right.webp
class LocalCacheService {
  Future<Directory> _modelDir(String modelId) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/moreala_cache/$modelId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<DateTime?> getModelStamp(String modelId) async {
    final dir = await _modelDir(modelId);
    final stampFile = File('${dir.path}/stamp.json');
    if (!await stampFile.exists()) return null;
    final data = jsonDecode(await stampFile.readAsString());
    return DateTime.parse(data['updatedAt']);
  }

  Future<void> setModelStamp(String modelId, DateTime updatedAt) async {
    final dir = await _modelDir(modelId);
    final stampFile = File('${dir.path}/stamp.json');
    await stampFile.writeAsString(jsonEncode({'updatedAt': updatedAt.toIso8601String()}));
  }

  /// Downloads (via a pre-signed URL, see r2-signed-url edge function)
  /// and caches a single photo if not already present locally.
  Future<File> getOrDownload({
    required String modelId,
    required String cacheKey, // e.g. "<photoPointId>_forward"
    required Future<String> Function() fetchSignedUrl,
  }) async {
    final dir = await _modelDir(modelId);
    final file = File('${dir.path}/$cacheKey.webp');
    if (await file.exists()) return file;

    final signedUrl = await fetchSignedUrl();
    final response = await http.get(Uri.parse(signedUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to download $cacheKey: HTTP ${response.statusCode}');
    }
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }

  Future<bool> isModelCached(String modelId) async {
    final dir = await _modelDir(modelId);
    final stampFile = File('${dir.path}/stamp.json');
    return stampFile.exists();
  }

  Future<void> clearModel(String modelId) async {
    final dir = await _modelDir(modelId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
