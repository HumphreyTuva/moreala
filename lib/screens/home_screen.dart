import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'create_walkthrough_screen.dart';
import 'capture_screen.dart';
import 'walkthrough_screen.dart';
import 'my_classes_screen.dart';
import 'payment_screen.dart';
import 'review_queue_screen.dart';
import 'change_password_screen.dart';
import '../services/supabase_service.dart';
import 'my_joined_classes_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _supabase = SupabaseService();
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
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this walkthrough?'),
        content: Text(
          '"${model['title']}" and every pin, note, and stop inside it will be permanently deleted. This can\'t be undone.',
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
        await _supabase.deleteModel(model['id']);
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

  Future<void> _editModel(Map<String, dynamic> model) async {
    final titleController = TextEditingController(text: model['title'] ?? '');
    final locationController = TextEditingController(text: model['campus_location'] ?? '');
    bool isShared = model['is_shared'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Walkthrough'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: locationController,
                decoration: const InputDecoration(labelText: 'Campus location'),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Shared with other students'),
                value: isShared,
                onChanged: (v) => setDialogState(() => isShared = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      try {
        await _supabase.updateModel(
          modelId: model['id'],
          title: titleController.text.trim(),
          campusLocation: locationController.text.trim().isEmpty ? null : locationController.text.trim(),
          isShared: isShared,
        );
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save changes: $e')),
          );
        }
      }
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
            tooltip: 'My classes',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyJoinedClassesScreen()),
            ),
          ),


          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'change_password') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
                );
              } else if (value == 'logout') {
                _logout();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'change_password', child: Text('Change password')),
              PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
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


                                    trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, color: Colors.white70),
                        tooltip: 'Edit',
                        onPressed: () => _editModel(m),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        tooltip: 'Delete',
                        onPressed: () => _confirmDelete(m),
                      ),
                    ],
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