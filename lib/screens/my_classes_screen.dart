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
                return ListTile(
                  leading: Icon(
                    c['is_active'] == true ? Icons.check_circle : Icons.pause_circle,
                    color: c['is_active'] == true ? Colors.cyanAccent : Colors.white38,
                  ),
                  title: Text(c['class_code'] ?? ''),
                  subtitle: Text(modelTitle),
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
