import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import 'create_class_screen.dart';
import 'class_roster_screen.dart';

class MyClassesScreen extends StatefulWidget {
  const MyClassesScreen({super.key});

  @override
  State<MyClassesScreen> createState() => _MyClassesScreenState();
}

class _MyClassesScreenState extends State<MyClassesScreen> {
  final _supabase = SupabaseService();
  late Future<List<Map<String, dynamic>>> _classesFuture;

  @override
  void initState() {
    super.initState();
    _classesFuture = _supabase.getOwnedClasses();
  }

  Future<void> _refresh() async {
    setState(() => _classesFuture = _supabase.getOwnedClasses());
  }

  Future<void> _toggleActive(Map<String, dynamic> cls) async {
    final newValue = !(cls['is_active'] == true);
    try {
      await _supabase.setClassActive(cls['id'], newValue);
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e')),
        );
      }
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> cls) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this class?'),
        content: Text(
          '"${cls['class_code']}" and its full roster will be permanently deleted. '
          'The walkthrough itself is NOT affected — only the class and who joined it. '
          'This can\'t be undone.\n\nIf you just want to stop new students joining, '
          'use "Deactivate" instead — that keeps the roster intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _supabase.deleteClass(cls['id']);
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Classes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CreateClassScreen()),
          );
          _refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('New Class'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _classesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final classes = snapshot.data ?? [];
            if (classes.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No classes yet. Tap "New Class" to create a join code '
                        'for one of your finished walkthroughs.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.builder(
              itemCount: classes.length,
              itemBuilder: (context, i) {
                final c = classes[i];
                final modelTitle = (c['models'] as Map?)?['title'] ?? 'Unknown walkthrough';
                final isActive = c['is_active'] == true;
                return ListTile(
                  leading: Icon(
                    isActive ? Icons.check_circle : Icons.pause_circle,
                    color: isActive ? Colors.cyanAccent : Colors.white38,
                  ),
                  title: Text(c['class_code'] ?? ''),
                  subtitle: Text(modelTitle),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'toggle') {
                        _toggleActive(c);
                      } else if (value == 'delete') {
                        _confirmDelete(c);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(isActive ? 'Deactivate' : 'Reactivate'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ClassRosterScreen(
                        classId: c['id'],
                        classCode: c['class_code'],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}