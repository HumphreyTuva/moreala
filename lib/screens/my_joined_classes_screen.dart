import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import 'walkthrough_screen.dart';
import 'join_class_screen.dart';
import '../utils/error_utils.dart';import '../widgets/error_banner.dart';



/// snapshot.hasError The student-side equivalent of MyClassesScreen — every class the
/// current user has joined, so they can get back into a shared
/// walkthrough without needing to remember and retype the join code
/// each time.
class MyJoinedClassesScreen extends StatefulWidget {
  const MyJoinedClassesScreen({super.key});

  @override
  State<MyJoinedClassesScreen> createState() => _MyJoinedClassesScreenState();
}

class _MyJoinedClassesScreenState extends State<MyJoinedClassesScreen> {
  final _supabase = SupabaseService();
  late Future<List<Map<String, dynamic>>> _joinedFuture;

  @override
  void initState() {
    super.initState();
    _joinedFuture = _supabase.getJoinedClasses();
  }

  Future<void> _refresh() async {
    setState(() => _joinedFuture = _supabase.getJoinedClasses());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Classes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const JoinClassScreen()),
          );
          _refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('Join a class'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _joinedFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ErrorBanner(message: friendlyErrorMessage(snapshot.error!)),
                ),
              );
            }
                              
            final joined = snapshot.data ?? [];
            if (joined.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'You haven\'t joined any classes yet. Tap "Join a class" '
                        'and enter the code your lecturer shared.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.builder(
              itemCount: joined.length,
              itemBuilder: (context, i) {
                final entry = joined[i];
                final cls = entry['classes'];
                if (cls == null) return const SizedBox.shrink();
                final modelTitle = (cls['models'] as Map?)?['title'] ?? 'Unknown walkthrough';
                final isActive = cls['is_active'] == true;
                return ListTile(
                  leading: Icon(
                    isActive ? Icons.check_circle : Icons.pause_circle,
                    color: isActive ? Colors.cyanAccent : Colors.white38,
                  ),
                  title: Text(cls['class_code'] ?? ''),
                  subtitle: Text(modelTitle),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WalkthroughScreen(modelId: cls['model_id']),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}