import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'capture_screen.dart';
import 'payment_screen.dart';
import '../services/supabase_service.dart';

/// Lets a student/lecturer create a new walkthrough space (a `models`
/// row) and jump straight into CaptureScreen for it.
///
/// Per the spec's tier table, creating a NEW captured space (private
/// or shared) is what "a scan" means — it costs a scan credit, either
/// a Lecturer Pro's 5 free/month or a purchased 40 KSh credit. This is
/// enforced server-side via consume_scan_credit() (a SECURITY DEFINER
/// Postgres function), so a modified client can't just skip the check.
class CreateWalkthroughScreen extends StatefulWidget {
  const CreateWalkthroughScreen({super.key});

  @override
  State<CreateWalkthroughScreen> createState() => _CreateWalkthroughScreenState();
}

class _CreateWalkthroughScreenState extends State<CreateWalkthroughScreen> {
  final _supabase = SupabaseService();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  bool _isShared = false;
  bool _creating = false;
  String? _error;

  Future<void> _create() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give this walkthrough a name first.');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final allowed = await _supabase.consumeScanCredit();
      if (!allowed) {
        setState(() {
          _creating = false;
          _error = 'You\'re out of scans. Buy one to capture a new space.';
        });
        return;
      }

      final client = Supabase.instance.client;
      final authUserId = client.auth.currentUser!.id;
      final userRow =
          await client.from('users').select('id').eq('auth_id', authUserId).single();

      final modelRow = await client
          .from('models')
          .insert({
            'owner_id': userRow['id'],
            'title': title,
            'campus_location':
                _locationController.text.trim().isEmpty ? null : _locationController.text.trim(),
            'is_shared': _isShared,
            'status': 'processing',
          })
          .select()
          .single();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CaptureScreen(modelId: modelRow['id']),
        ),
      );
    } catch (e) {
      setState(() => _error = 'Could not create walkthrough: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Walkthrough')),
            body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Give this space a name — e.g. the room or building '
              'you\'re about to walk through and capture.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g. KU Science Complex Room 204',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Campus location (optional)',
                hintText: 'e.g. Kenyatta University',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share this space with other students'),
              subtitle: const Text(
                'If off, only you can see this walkthrough and any pins on it.',
                style: TextStyle(fontSize: 12),
              ),
              value: _isShared,
              onChanged: (v) => setState(() => _isShared = v),
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
              if (_error!.contains('out of scans'))
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PaymentScreen()),
                  ),
                  child: const Text('Buy a scan'),
                ),
              const SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: _creating ? null : _create,
              child: _creating
                  ? const SizedBox(
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Start capturing'),
            ),
          ],
        ),
      ),
    );
  }
}