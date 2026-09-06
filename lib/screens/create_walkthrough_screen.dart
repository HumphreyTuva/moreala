import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'capture_screen.dart';
import 'video_capture_screen.dart';
import 'payment_screen.dart';
import '../services/supabase_service.dart';
import '../utils/error_utils.dart';

enum _CaptureMode { photos, video }

/// Could not create walkthrough Lets a student/lecturer create a new walkthrough space (a `models`
/// row) and choose how to capture it:
///   - Photos (stop-and-shoot): reliable, tested, works with no extra
///     setup. Recommended default.
///   - Video: matches the spec's original video+keyframe-extraction
///     workflow. Requires the keyframe-extractor worker to be
///     deployed and reachable — if it isn't, this mode will show a
///     clear error rather than hanging silently.
///
/// Per the spec's tier table, creating a NEW captured space (private
/// or shared) is what "a scan" means — it costs a scan credit either
/// way, enforced server-side via consume_scan_credit().
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
  _CaptureMode _mode = _CaptureMode.photos;
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
          builder: (_) => _mode == _CaptureMode.photos
              ? CaptureScreen(modelId: modelRow['id'])
              : VideoCaptureScreen(modelId: modelRow['id']),
        ),
      );

    } catch (e) {
      setState(() => _error = friendlyErrorMessage(e));
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
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
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
              const SizedBox(height: 20),
              const Text('Capture method', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              RadioListTile<_CaptureMode>(
                contentPadding: EdgeInsets.zero,
                value: _CaptureMode.photos,
                groupValue: _mode,
                title: const Text('Photos (recommended)'),
                subtitle: const Text(
                  'Stop at each spot and take Forward/Left/Right photos. Reliable, works offline-tolerant.',
                  style: TextStyle(fontSize: 12),
                ),
                onChanged: (v) => setState(() => _mode = v!),
              ),
              
              RadioListTile<_CaptureMode>(
                contentPadding: EdgeInsets.zero,
                value: _CaptureMode.video,
                groupValue: _mode,
                title: const Text('Video (experimental)'),
                subtitle: const Text(
                  'Record one continuous walkthrough video; stops are extracted right on your phone afterward. Faster to record, but processing can take a bit — no Left/Right angles per stop.',
                  style: TextStyle(fontSize: 12),
                ),
                onChanged: (v) => setState(() => _mode = v!),
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
      ),
    );
  }
}