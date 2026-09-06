import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import 'class_roster_screen.dart';
import '../utils/error_utils.dart';

/// Could not create class Lets the current user create a class join code (e.g. "EPS210-FINALS")
/// pointing at one of their own finished ("ready") walkthroughs, so
/// students can join and study the shared space together.
class CreateClassScreen extends StatefulWidget {
  const CreateClassScreen({super.key});

  @override
  State<CreateClassScreen> createState() => _CreateClassScreenState();
}

class _CreateClassScreenState extends State<CreateClassScreen> {
  final _supabase = SupabaseService();
  final _codeController = TextEditingController();
  late Future<List<Map<String, dynamic>>> _modelsFuture;
  String? _selectedModelId;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _modelsFuture = _supabase.getOwnedReadyModels();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final code = _codeController.text.trim();
    if (_selectedModelId == null) {
      setState(() => _error = 'Pick which walkthrough this class studies.');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = 'Give the class a join code.');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final classRow = await _supabase.createClass(
        modelId: _selectedModelId!,
        classCode: code,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ClassRosterScreen(
            classId: classRow['id'],
            classCode: classRow['class_code'],
          ),
        ),
      );

    } catch (e) {
      final message = e.toString();
      if (message.contains('SocketException') || message.contains('Failed host lookup')) {
        setState(() => _error = friendlyErrorMessage(e));
      } else {
        // Most likely failure otherwise: the unique(class_code)
        // constraint — someone (possibly the lecturer themselves,
        // retrying) already used this exact code.
        setState(() => _error = 'Could not create class — that code may already be taken. Try a different one.');
      }
    } finally {

      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Class')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick a finished walkthrough for students to study, '
                'and give the class a join code.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _modelsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final models = snapshot.data ?? [];
                  if (models.isEmpty) {
                    return const Text(
                      'You don\'t have any finished walkthroughs yet. '
                      'Capture and finish one first.',
                      style: TextStyle(color: Colors.orangeAccent),
                    );
                  }
                  return DropdownButtonFormField<String>(
                    initialValue: _selectedModelId,
                    decoration: const InputDecoration(
                      labelText: 'Walkthrough',
                      border: OutlineInputBorder(),
                    ),
                    items: models
                        .map((m) => DropdownMenuItem(
                              value: m['id'] as String,
                              child: Text(m['title'] ?? 'Untitled'),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedModelId = v),
                  );
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Class join code',
                  hintText: 'e.g. EPS210-FINALS',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              ElevatedButton(
                onPressed: _creating ? null : _create,
                child: _creating
                    ? const SizedBox(
                        height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create class'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
