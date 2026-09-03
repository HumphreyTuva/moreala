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

    // A new flashcard needs an initial reviews row, due immediately,
    // or it's invisible to the "Due Today" queue until it's already
    // been reviewed once some other way.
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

  // ---------------- CAPTURE (stop-and-shoot walkthrough building) ----------------

  Future<Map<String, dynamic>?> getLastPhotoPoint(String modelId) async {
    return await _client
        .from('photo_points')
        .select()
        .eq('model_id', modelId)
        .order('order_index', ascending: false)
        .limit(1)
        .maybeSingle();
  }

  /// Creates a new stop.
  ///
  /// [previousPhotoPointId] is now explicit rather than looked up
  /// automatically — that's a deliberate change to support branching.
  /// The old behavior (always link to whatever's globally last in the
  /// model) breaks the moment a model has more than one line: a new
  /// stop captured in Branch B would incorrectly get linked as if it
  /// continued Branch A. The caller (CaptureScreen) now tracks its own
  /// "last stop in *this* capture session" and passes it in. Pass null
  /// to start a stop with no backward link at all — used for the
  /// first stop of a brand-new branch (its connection to the rest of
  /// the graph is recorded separately via photo_point_links, not
  /// linked_prev_id).
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
          // No longer required to be gapless/sequential per line now
          // that branches exist — just needs to sort reasonably and
          // stay unique. Millisecond timestamp does that.
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

  /// Records a branch connection: "from this stop, there's also a
  /// path (labeled e.g. 'Left doorway') leading to that stop." Kept
  /// entirely separate from linked_prev_id/linked_next_id, which stay
  /// scoped to a single straight line — a stop can have any number of
  /// outgoing branch links in addition to its normal forward/back.
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
}