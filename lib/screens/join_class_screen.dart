import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import 'walkthrough_screen.dart';
import '../utils/error_utils.dart';

/// Something went wrong Lets a student enter a lecturer's class join code (e.g.
/// "EPS210-FINALS") and jump straight into that class's shared
/// walkthrough. QR scanning would layer a barcode-scanner package on
/// top of this same joinClassByCode() call — omitted here since it's
/// a device-camera integration best wired up once you're testing on
/// real hardware.
class JoinClassScreen extends StatefulWidget {
  const JoinClassScreen({super.key});

  @override
  State<JoinClassScreen> createState() => _JoinClassScreenState();
}

class _JoinClassScreenState extends State<JoinClassScreen> {
  final _supabase = SupabaseService();
  final _codeController = TextEditingController();
  bool _joining = false;
  String? _error;

  Future<void> _join() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final classRow = await _supabase.joinClassByCode(code);
      if (classRow == null) {
        setState(() => _error = 'No active class found with that code.');
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => WalkthroughScreen(modelId: classRow['model_id']),
        ),
      );

    } catch (e) {
      setState(() => _error = friendlyErrorMessage(e));
    } finally {

      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a Class')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Class code (e.g. EPS210-FINALS)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _joining ? null : _join,
              child: _joining
                  ? const SizedBox(
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }
}
