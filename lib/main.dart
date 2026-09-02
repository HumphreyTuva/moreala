import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/reset_password_screen.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'YOUR_SUPABASE_URL');
const supabaseAnonKey =
    String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'YOUR_SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const MorealaApp());
}

class MorealaApp extends StatelessWidget {
  const MorealaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moreala',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyanAccent,
        useMaterial3: true,
      ),
      // Listens for auth state changes instead of checking once at
      // startup — this is what makes login/logout redirect correctly,
      // AND lets us catch the special "passwordRecovery" event that
      // fires when the app is opened via the reset-password email
      // link, routing to ResetPasswordScreen instead of straight to
      // HomeScreen (Supabase creates a temporary valid session for
      // that moment, so a plain null-check alone can't tell the two
      // cases apart).
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          if (snapshot.data?.event == AuthChangeEvent.passwordRecovery) {
            return const ResetPasswordScreen();
          }
          final session = Supabase.instance.client.auth.currentSession;
          return session == null ? const AuthScreen() : const HomeScreen();
        },
      ),
    );
  }
}