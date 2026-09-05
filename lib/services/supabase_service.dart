import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/walkthrough_models.dart';
import 'local_cache_service.dart';

/// Central data access layer.
///
/// IMPORTANT (per the concurrency spec): every read here is a plain
/// PostgREST call (`.select()`), which opens a connection, executes,
/// and closes — no `.channel().subscribe()` anywhere in this file.
///
/// CRITICAL ID DISTINCTION: Supabase Auth's user id (`auth.uid()`,
/// what `_client.auth.currentUser!.id` returns) is NOT the same UUID
/// as this app's internal `users.id`. Every foreign key and RLS policy
/// in the schema expects the INTERNAL id, looked up via `users` where
/// `auth_id = <the auth uid>`. Every method below goes through
/// `_internalUserId()` for exactly this reason.
class SupabaseService {
  final SupabaseClient _client = Supabase.instance.client;
  final LocalCacheService _cache = LocalCacheService();

  Future<String> _internalUserId() async {
    final authUserId = _client.auth.currentUser!.id;
    final row =
        await _client.from('users').select('id').eq('auth_id', authUserId).single();
    return row['id'] as String;
  }

  // ---------------- MODELS ----------------

  Future<MorealaModel?> getModel(String modelId) async {
    final row = await _client.from('models').select().eq('id', modelId).maybeSingle();
    if (row == null) return null;
    return MorealaModel.fromJson(row);
  }

  Future<bool> modelNeedsRefresh(String modelId) async {
    final row = await _client
        .from('models')
        .select('updated_at')
        .eq('id', modelId)
        .single();
    final serverUpdatedAt = DateTime.parse(row['updated_at']);
    final cachedStamp = await _cache.getModelStamp(modelId);
    return cachedStamp == null || serverUpdatedAt.isAfter(cachedStamp);
  }

  /// Edits a walkthrough's title/location/sharing after the fact —
  /// previously a typo meant deleting and starting over.
  Future<void> updateModel({
    required String modelId,
    required String title,
    String? campusLocation,
    required bool isShared,
  }) async {
    await _client.from('models').update({
      'title': title,
      'campus_location': campusLocation,
      'is_shared': isShared,
    }).eq('id', modelId);
  }

  Future<void> deleteModel(String modelId) async {
    // Clean up the actual R2 files first (best-effort — the edge
    // function itself won't block deletion over a cleanup failure).
    // The schema's `on delete cascade` foreign keys then take care of
    // photo_points, pins, notes, reviews, and any class tied to this
    // model when the row itself is deleted below.
    try {
      await _client.functions.invoke('delete-model-media', body: {'model_id': modelId});
    } catch (_) {
      // Non-fatal — proceed with deleting the model row regardless.
    }
    await _client.from('models').delete().eq('id', modelId);
  }

  // ---------------- PHOTO POINTS (node graph) ----------------

  Future<List<PhotoPoint>> getPhotoPoints(String modelId) async {
    final rows = await _client
        .from('photo_points')
        .select()
        .eq('model_id', modelId)
        .order('order_index');
    return rows.map<PhotoPoint>((r) => PhotoPoint.fromJson(r)).toList();
  }

  // ---------------- PINS ----------------

  Future<List<SpatialPin>> getPinsForPhotoPoint(String photoPointId) async {
    final rows =
        await _client.from('pins').select().eq('photo_point_id', photoPointId);
    return rows.map<SpatialPin>((r) => SpatialPin.fromJson(r)).toList();
  }

  Future<SpatialPin> createPin({
    required String photoPointId,
    required double x,
    required double y,
  }) async {
    final userId = await _internalUserId();
    final row = await _client
        .from('pins')
        .insert({
          'photo_point_id': photoPointId,
          'user_id': userId,
          'x': x,
          'y': y,
        })
        .select()
        .single();
    return SpatialPin.fromJson(row);
  }

  Future<void> deletePin(String pinId, {String? noteId}) async {
    if (noteId != null) {
      await _client.from('notes').delete().eq('id', noteId);
    }
    await _client.from('pins').delete().eq('id', pinId);
  }

  // ---------------- NOTES ----------------

  Future<StudyNote> createNote({
    String? pinId,
    required NoteType type,
    required Map<String, dynamic> content,
    String? mediaUrl,
  }) async {
    final userId = await _internalUserId();
    final row = await _client
        .from('notes')
        .insert({
          'pin_id': pinId,
          'owner_id': userId,
          'type': type.name,
          'content': content,
          'media_url': mediaUrl,
        })
        .select()
        .single();

    if (pinId != null) {
      await _client.from('pins').update({'note_id': row['id']}).eq('id', pinId);
    }

    if (type == NoteType.flashcard) {
      await _client.from('reviews').insert({
        'note_id': row['id'],
        'user_id': userId,
        'next_review_date': DateTime.now().toIso8601String(),
        'ease_factor': 2.5,
        'interval': 1,
        'repetitions': 0,
      });
    }

    return StudyNote.fromJson(row);
  }

  /// Edits an existing text or flashcard note's content in place —
  /// previously the only way to fix a typo was delete-and-recreate.
  /// Not offered for audio notes (there's nothing text-based to edit).
  Future<void> updateNoteContent(String noteId, Map<String, dynamic> content) async {
    await _client.from('notes').update({'content': content}).eq('id', noteId);
  }

  // ---------------- REVIEWS (SM-2 due queue) ----------------

  Future<List<Map<String, dynamic>>> getDueReviews() async {
    final userId = await _internalUserId();
    final now = DateTime.now().toIso8601String();
    return await _client
        .from('reviews')
        .select('*, notes(*)')
        .eq('user_id', userId)
        .lte('next_review_date', now)
        .order('next_review_date');
  }

  Future<void> submitReview({
    required String noteId,
    required double easeFactor,
    required int interval,
    required int repetitions,
    required DateTime nextReviewDate,
  }) async {
    final userId = await _internalUserId();
    await _client.from('reviews').upsert({
      'note_id': noteId,
      'user_id': userId,
      'ease_factor': easeFactor,
      'interval': interval,
      'repetitions': repetitions,
      'next_review_date': nextReviewDate.toIso8601String(),
      'last_reviewed_at': DateTime.now().toIso8601String(),
    }, onConflict: 'note_id,user_id');
  }

  // ---------------- CAPTURE (stop-and-shoot / video walkthrough building) ----------------

  Future<Map<String, dynamic>?> getLastPhotoPoint(String modelId) async {
    return await _client
        .from('photo_points')
        .select()
        .eq('model_id', modelId)
        .order('order_index', ascending: false)
        .limit(1)
        .maybeSingle();
  }

  Future<PhotoPoint> createPhotoPointStop({
    required String modelId,
    required String forwardKey,
    required String leftKey,
    required String rightKey,
    String? previousPhotoPointId,
  }) async {
    final row = await _client
        .from('photo_points')
        .insert({
          'model_id': modelId,
          'photo_url_forward': forwardKey,
          'photo_url_left': leftKey,
          'photo_url_right': rightKey,
          'order_index': DateTime.now().millisecondsSinceEpoch,
          'linked_prev_id': previousPhotoPointId,
        })
        .select()
        .single();

    if (previousPhotoPointId != null) {
      await _client
          .from('photo_points')
          .update({'linked_next_id': row['id']}).eq('id', previousPhotoPointId);
    }

    return PhotoPoint.fromJson(row);
  }

  Future<void> createBranchLink({
    required String fromPhotoPointId,
    required String toPhotoPointId,
    required String label,
  }) async {
    await _client.from('photo_point_links').insert({
      'from_photo_point_id': fromPhotoPointId,
      'to_photo_point_id': toPhotoPointId,
      'label': label,
    });
  }

  Future<List<Map<String, dynamic>>> getBranchLinksFrom(String photoPointId) async {
    return await _client
        .from('photo_point_links')
        .select()
        .eq('from_photo_point_id', photoPointId);
  }

  Future<String> getUploadUrl(String objectKey) async {
    final response = await _client.functions.invoke(
      'r2-upload-url',
      body: {'object_key': objectKey},
    );
    final url = response.data?['url'] as String?;
    if (url == null) {
      throw Exception('r2-upload-url returned no url (status ${response.status})');
    }
    return url;
  }

  Future<void> markModelReady(String modelId) async {
    await _client.from('models').update({'status': 'ready'}).eq('id', modelId);
  }

  // ---------------- NOTES (view/create for a pin) ----------------

  Future<StudyNote?> getNoteById(String noteId) async {
    final row = await _client.from('notes').select().eq('id', noteId).maybeSingle();
    if (row == null) return null;
    return StudyNote.fromJson(row);
  }

  // ---------------- LECTURER CLASSES ----------------

  Future<List<Map<String, dynamic>>> getOwnedReadyModels() async {
    final userId = await _internalUserId();
    return await _client
        .from('models')
        .select()
        .eq('owner_id', userId)
        .eq('status', 'ready')
        .order('created_at', ascending: false);
  }

  Future<List<Map<String, dynamic>>> getOwnedClasses() async {
    final userId = await _internalUserId();
    return await _client
        .from('classes')
        .select('*, models(title)')
        .eq('owner_id', userId)
        .order('created_at', ascending: false);
  }

  Future<Map<String, dynamic>> createClass({
    required String modelId,
    required String classCode,
  }) async {
    final userId = await _internalUserId();
    return await _client
        .from('classes')
        .insert({
          'owner_id': userId,
          'model_id': modelId,
          'class_code': classCode.toUpperCase(),
        })
        .select()
        .single();
  }

  /// Toggles a class active/inactive rather than deleting outright —
  /// students who already joined keep their history, but the class
  /// stops being joinable/usable while inactive. See deleteClass for
  /// permanent removal.
  Future<void> setClassActive(String classId, bool isActive) async {
    await _client.from('classes').update({'is_active': isActive}).eq('id', classId);
  }

  Future<void> deleteClass(String classId) async {
    // class_members cascades on delete per the schema, so the roster
    // goes with it — this is a genuine permanent delete, not a soft
    // deactivate. setClassActive is the safer default for "I'm done
    // teaching this" — this is for "I created this by mistake."
    await _client.from('classes').delete().eq('id', classId);
  }

  Future<List<Map<String, dynamic>>> getClassRoster(String classId) async {
    return await _client
        .from('class_members')
        .select('joined_at, users(name, email)')
        .eq('class_id', classId)
        .order('joined_at');
  }

  // ---------------- CLASSES ----------------

  Future<Map<String, dynamic>?> joinClassByCode(String classCode) async {
    final userId = await _internalUserId();
    final classRow = await _client
        .from('classes')
        .select()
        .eq('class_code', classCode.toUpperCase())
        .eq('is_active', true)
        .maybeSingle();
    if (classRow == null) return null;

    await _client.from('class_members').upsert({
      'class_id': classRow['id'],
      'user_id': userId,
    }, onConflict: 'class_id,user_id');

    return classRow;
  }

  Future<List<Map<String, dynamic>>> getJoinedClasses() async {
    final userId = await _internalUserId();
    return await _client
        .from('class_members')
        .select('joined_at, classes(id, class_code, is_active, model_id, models(title))')
        .eq('user_id', userId)
        .order('joined_at', ascending: false);
  }

  // ---------------- PAYMENTS (M-Pesa) ----------------

  Future<String> initiatePayment({
    required String purpose,
    required String phoneNumber,
  }) async {
    final response = await _client.functions.invoke(
      'mpesa-initiate',
      body: {'purpose': purpose, 'phone_number': phoneNumber},
    );
    final checkoutId = response.data?['checkout_request_id'] as String?;
    if (checkoutId == null) {
      throw Exception(response.data?['error'] ?? 'Failed to start payment (status ${response.status})');
    }
    return checkoutId;
  }

  Future<String> getPaymentStatus(String checkoutRequestId) async {
    final row = await _client
        .from('payments')
        .select('status')
        .eq('checkout_request_id', checkoutRequestId)
        .single();
    return row['status'] as String;
  }

  // ---------------- SCAN CREDITS ----------------

  Future<bool> consumeScanCredit() async {
    final userId = await _internalUserId();
    final result = await _client.rpc('consume_scan_credit', params: {'p_user_id': userId});
    return result as bool;
  }

  Future<int> getScanCredits() async {
    final userId = await _internalUserId();
    final row = await _client.from('users').select('scan_credits').eq('id', userId).single();
    return row['scan_credits'] as int;
  }

  // ---------------- REVIEWS DUE TODAY ----------------

  Future<Map<String, dynamic>?> getReviewState(String noteId) async {
    final userId = await _internalUserId();
    return await _client
        .from('reviews')
        .select()
        .eq('note_id', noteId)
        .eq('user_id', userId)
        .maybeSingle();
  }

  Future<List<Map<String, dynamic>>> getDueReviewsWithContext() async {
    final userId = await _internalUserId();
    final now = DateTime.now().toIso8601String();
    return await _client
        .from('reviews')
        .select('*, notes(*)')
        .eq('user_id', userId)
        .lte('next_review_date', now)
        .order('next_review_date');
  }

  // ---------------- VOICE NOTES (Supabase Storage, per spec) ----------------

  Future<String> uploadVoiceNote(Uint8List bytes) async {
    final userId = await _internalUserId();
    final path = '$userId/${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _client.storage.from('voice-notes').uploadBinary(path, bytes);
    return path;
  }

  Future<String> getVoiceNoteSignedUrl(String path) async {
    return await _client.storage.from('voice-notes').createSignedUrl(path, 60 * 10);
  }

  // ---------------- VIDEO CAPTURE (on-device extraction) ----------------
  // (No new methods needed — uses getUploadUrl, createPhotoPointStop,
  // and markModelReady, all already defined above.)
}