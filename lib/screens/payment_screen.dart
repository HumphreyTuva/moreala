import 'dart:async';
import 'package:flutter/material.dart';
import '../services/supabase_service.dart';

/// Lets the current user buy a private scan or upgrade to Lecturer Pro
/// via M-Pesa STK push. Triggers the push, then polls the `payments`
/// row every couple seconds until mpesa-webhook has updated its status
/// (this is a plain repeated read, not a live subscription — matching
/// the "no Realtime for routine reads" rule used everywhere else in
/// the app; a payment confirmation waiting a few seconds for a poll is
/// an acceptable trade for not holding open a socket for it).
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

enum _PaymentState { form, waiting, success, failed }

class _PaymentScreenState extends State<PaymentScreen> {
  final _supabase = SupabaseService();
  final _phoneController = TextEditingController();
  String _purpose = 'scan';
  _PaymentState _state = _PaymentState.form;
  String? _error;
  Timer? _pollTimer;

  static const _prices = {
    'scan': 'KSh 40 — one private scan',
    'lecturer_monthly': 'KSh 500 — Lecturer Pro (monthly)',
    'lecturer_semester': 'KSh 1,200 — Lecturer Pro (semester)',
  };

  @override
  void dispose() {
    _pollTimer?.cancel();
    _phoneController.dispose();
    super.dispose();
  }

    /// Translates common technical failures — especially "no internet"
  /// — into plain language instead of showing a raw SocketException
  /// or similar, which reads as a crash to someone who's just offline.
  String _friendlyPaymentError(Object e) {
    final message = e.toString();
    if (message.contains('SocketException') ||
        message.contains('Failed host lookup') ||
        message.contains('Network is unreachable')) {
      return 'You appear to be offline. Check your internet connection and try again.';
    }
    return 'Could not start payment. Please try again in a moment.';
  }

  Future<void> _pay() async {
    final phone = _normalizePhoneNumber(_phoneController.text);
    if (phone == null) {
      setState(() => _error = 'That doesn\'t look like a valid Safaricom number.');
      return;
    }

    setState(() {
      _state = _PaymentState.waiting;
      _error = null;
    });

    try {
      final checkoutId = await _supabase.initiatePayment(purpose: _purpose, phoneNumber: phone);
      _startPolling(checkoutId);
    } catch (e) {
      setState(() {
        _state = _PaymentState.form;
        _error = _friendlyPaymentError(e);
      });
    }
  }

  /// Accepts Kenyan numbers in any common format — 0700144600,
  /// 700144600, 0113631232, with spaces or dashes, with or without a
  /// leading 254 — and normalizes to the 2547XXXXXXXX / 2541XXXXXXXX
  /// shape Safaricom's STK push API requires. Returns null if the
  /// cleaned digits don't match a valid Safaricom mobile number shape.
  String? _normalizePhoneNumber(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');

    String normalized;
    if (digits.startsWith('254') && digits.length == 12) {
      normalized = digits;
    } else if (digits.startsWith('0') && digits.length == 10) {
      normalized = '254${digits.substring(1)}';
    } else if (digits.length == 9) {
      normalized = '254$digits';
    } else {
      return null;
    }

    // Safaricom mobile numbers are 254 followed by 7xxxxxxxx (older
    // Safaricom lines) or 1xxxxxxxx (newer Safaricom lines, e.g. 011x).
    if (!RegExp(r'^254[17]\d{8}$').hasMatch(normalized)) return null;
    return normalized;
  }

  void _startPolling(String checkoutId) {
    var attempts = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      attempts++;
      try {
        final status = await _supabase.getPaymentStatus(checkoutId);
        if (status == 'success') {
          timer.cancel();
          setState(() => _state = _PaymentState.success);
        } else if (status == 'failed') {
          timer.cancel();
          setState(() => _state = _PaymentState.failed);
        } else if (attempts > 40) {
          timer.cancel();
          setState(() {
            _state = _PaymentState.form;
            _error = 'No response yet — check your phone for the M-Pesa prompt, or try again.';
          });
        }
      } catch (_) {
        // transient read error — just let the next tick retry
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay with M-Pesa')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _PaymentState.waiting:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Check your phone for the M-Pesa prompt and enter your PIN.',
                  textAlign: TextAlign.center),
            ],
          ),
        );
      case _PaymentState.success:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: Colors.cyanAccent, size: 64),
              SizedBox(height: 16),
              Text('Payment confirmed!', style: TextStyle(fontSize: 18)),
            ],
          ),
        );
      case _PaymentState.failed:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cancel, color: Colors.redAccent, size: 64),
              const SizedBox(height: 16),
              const Text('Payment failed or was cancelled.'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => setState(() => _state = _PaymentState.form),
                child: const Text('Try again'),
              ),
            ],
          ),
        );
      case _PaymentState.form:
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('What are you paying for?'),
              const SizedBox(height: 8),
              ..._prices.entries.map(
                (e) => RadioListTile<String>(
                  value: e.key,
                  groupValue: _purpose,
                  title: Text(e.value),
                  onChanged: (v) => setState(() => _purpose = v!),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'M-Pesa phone number',
                  hintText: 'e.g. 0701234500',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              ElevatedButton(
                onPressed: _pay,
                child: const Text('Pay now'),
              ),
            ],
          ),
        );
    }
  }
}