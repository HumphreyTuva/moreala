import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'create_walkthrough_screen.dart';
import 'capture_screen.dart';
import 'walkthrough_screen.dart';
import 'join_class_screen.dart';
import 'my_classes_screen.dart';
import 'payment_screen.dart';
import 'review_queue_screen.dart';

/// Landing screen after login. Fetches the user's own row once (name,
/// plan_tier) alongside their walkthroughs, so lecturer-only features
/// (creating class codes) are gated the way the spec's tier table
/// describes — the blueprint only defines Free Student vs Lecturer
/// Pro via `users.plan_tier`; there is no separate "admin" role in
/// the spec, so that distinction isn't invented here.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_HomeData> _load() async {
    final client = Supabase.instance.client;
    final authUserId = client.auth.currentUser!.id;
    final userRow = await client
        .from('users')
        .select('id, plan_tier')
        .eq('auth_id', authUserId)
        .single();

    final models = await client
        .from('models')
        .select()
        .eq('owner_id', userRow['id'])
        .order('created_at', ascending: false);

    return _HomeData(
      isLecturer: userRow['plan_tier'] == 'lecturer',
      models: List<Map<String, dynamic>>.from(models),
    );
  }

  Future<void> _refresh() async {
    setState(() => _dataFuture = _load());
  }

  Future<void> _logout() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // If the session is already broken/expired (e.g. after a
      // password-recovery session expired mid-use), a normal sign-out
      // can fail trying to invalidate it server-side. Falling back to
      // a LOCAL-only sign-out guarantees the user can always escape
      // back to the login screen regardless of session state.
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Walkthroughs'),
        actions: [
          FutureBuilder<_HomeData>(
            future: _dataFuture,
            builder: (context, snapshot) {
              final isLecturer = snapshot.data?.isLecturer ?? false;
              if (!isLecturer) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.school),
                tooltip: 'My classes (lecturer)',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyClassesScreen()),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.style),
            tooltip: 'Due today',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReviewQueueScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.payment),
            tooltip: 'Pay with M-Pesa',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PaymentScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Join a class',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const JoinClassScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CreateWalkthroughScreen()),
          );
          _refresh();
        },
        icon: const Icon(Icons.add_a_photo),
        label: const Text('New Walkthrough'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_HomeData>(
          future: _dataFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load: ${snapshot.error}'));
            }
            final models = snapshot.data?.models ?? [];
            if (models.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 80),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No walkthroughs yet. Tap "New Walkthrough" to capture your first space.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, i) {
                final m = models[i];
                final isReady = m['status'] == 'ready';
                return ListTile(
                  leading: Icon(
                    isReady ? Icons.check_circle : Icons.hourglass_top,
                    color: isReady ? Colors.cyanAccent : Colors.white38,
                  ),
                  title: Text(m['title'] ?? 'Untitled'),
                  subtitle: Text(
                    '${m['campus_location'] ?? 'No location set'} · ${m['status']}',
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => isReady
                            ? WalkthroughScreen(modelId: m['id'])
                            : CaptureScreen(modelId: m['id']),
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

class _HomeData {
  final bool isLecturer;
  final List<Map<String, dynamic>> models;
  _HomeData({required this.isLecturer, required this.models});
}