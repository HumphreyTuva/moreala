import 'package:flutter/material.dart';
import '../services/supabase_service.dart';

/// Shows the class code prominently (for projecting to a lecture hall)
/// and the "Seen By" roster — every student who has joined, in the
/// order they joined. This is a plain PostgREST read on pull-to-refresh,
/// not a live subscription — consistent with the "no Realtime for
/// browsing" rule used everywhere else, since a lecturer checking their
/// roster doesn't need push updates, just a fast read when they look.
class ClassRosterScreen extends StatefulWidget {
  final String classId;
  final String classCode;
  const ClassRosterScreen({super.key, required this.classId, required this.classCode});

  @override
  State<ClassRosterScreen> createState() => _ClassRosterScreenState();
}

class _ClassRosterScreenState extends State<ClassRosterScreen> {
  final _supabase = SupabaseService();
  late Future<List<Map<String, dynamic>>> _rosterFuture;

  @override
  void initState() {
    super.initState();
    _rosterFuture = _supabase.getClassRoster(widget.classId);
  }

  Future<void> _refresh() async {
    setState(() => _rosterFuture = _supabase.getClassRoster(widget.classId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Class Roster')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            color: Colors.cyanAccent.withOpacity(0.08),
            child: Column(
              children: [
                const Text('Join code', style: TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  widget.classCode,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const Text('Project this for students to join',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _rosterFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Failed to load: ${snapshot.error}'));
                  }
                  final roster = snapshot.data ?? [];
                  if (roster.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 60),
                        Center(
                          child: Text(
                            'No one has joined yet.\nPull down to refresh.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    itemCount: roster.length,
                    itemBuilder: (context, i) {
                      final entry = roster[i];
                      final user = entry['users'] ?? {};
                      return ListTile(
                        leading: const Icon(Icons.person, color: Colors.cyanAccent),
                        title: Text(user['name'] ?? 'Unknown'),
                        subtitle: Text(user['email'] ?? ''),
                        trailing: Text(
                          _formatJoinedAt(entry['joined_at']),
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatJoinedAt(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
