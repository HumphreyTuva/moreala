class MorealaModel {
  final String id;
  final String ownerId;
  final String title;
  final bool isShared;
  final String? campusLocation;
  final String status; // processing | ready | failed

  MorealaModel({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.isShared,
    this.campusLocation,
    required this.status,
  });

  factory MorealaModel.fromJson(Map<String, dynamic> json) => MorealaModel(
        id: json['id'],
        ownerId: json['owner_id'],
        title: json['title'],
        isShared: json['is_shared'] ?? false,
        campusLocation: json['campus_location'],
        status: json['status'] ?? 'processing',
      );
}

enum LookDirection { forward, left, right }

class PhotoPoint {
  final String id;
  final String modelId;
  final String photoUrlForward;
  final String? photoUrlLeft;
  final String? photoUrlRight;
  final double heading;
  final int orderIndex;
  final String? linkedNextId;
  final String? linkedPrevId;

  PhotoPoint({
    required this.id,
    required this.modelId,
    required this.photoUrlForward,
    this.photoUrlLeft,
    this.photoUrlRight,
    required this.heading,
    required this.orderIndex,
    this.linkedNextId,
    this.linkedPrevId,
  });

  factory PhotoPoint.fromJson(Map<String, dynamic> json) => PhotoPoint(
        id: json['id'],
        modelId: json['model_id'],
        photoUrlForward: json['photo_url_forward'],
        photoUrlLeft: json['photo_url_left'],
        photoUrlRight: json['photo_url_right'],
        heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
        orderIndex: json['order_index'],
        linkedNextId: json['linked_next_id'],
        linkedPrevId: json['linked_prev_id'],
      );

  /// Returns the object key/URL for a given look direction, falling
  /// back to forward if that direction wasn't captured at this stop.
  String urlFor(LookDirection dir) {
    switch (dir) {
      case LookDirection.left:
        return photoUrlLeft ?? photoUrlForward;
      case LookDirection.right:
        return photoUrlRight ?? photoUrlForward;
      case LookDirection.forward:
        return photoUrlForward;
    }
  }
}

class SpatialPin {
  final String id;
  final String photoPointId;
  final String userId;
  final double x; // normalized 0.0-1.0
  final double y;
  final String? noteId;

  SpatialPin({
    required this.id,
    required this.photoPointId,
    required this.userId,
    required this.x,
    required this.y,
    this.noteId,
  });

  factory SpatialPin.fromJson(Map<String, dynamic> json) => SpatialPin(
        id: json['id'],
        photoPointId: json['photo_point_id'],
        userId: json['user_id'],
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        noteId: json['note_id'],
      );
}

enum NoteType { text, audio, flashcard }

class StudyNote {
  final String id;
  final String? pinId;
  final NoteType type;
  final Map<String, dynamic> content; // {body} or {question, answer}
  final String? mediaUrl;

  StudyNote({
    required this.id,
    this.pinId,
    required this.type,
    required this.content,
    this.mediaUrl,
  });

  factory StudyNote.fromJson(Map<String, dynamic> json) => StudyNote(
        id: json['id'],
        pinId: json['pin_id'],
        type: NoteType.values.firstWhere((t) => t.name == json['type']),
        content: Map<String, dynamic>.from(json['content']),
        mediaUrl: json['media_url'],
      );
}
