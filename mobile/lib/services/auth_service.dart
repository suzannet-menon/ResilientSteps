import 'package:supabase_flutter/supabase_flutter.dart';

/// All Supabase Auth operations go through this class.
/// No other file calls Supabase.instance.client.auth directly.
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  SupabaseClient get _client => Supabase.instance.client;

  User? get currentUser {
    try {
      return _client.auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// True if a real (non-anonymous) user is signed in.
  bool get isLoggedIn {
    final User? user = currentUser;
    if (user == null) {
      return false;
    }
    return user.isAnonymous == false;
  }

  String? get accessToken {
    try {
      return _client.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }

  Stream<AuthState> get authStateChanges {
    try {
      return _client.auth.onAuthStateChange;
    } catch (_) {
      return const Stream<AuthState>.empty();
    }
  }

  String get displayName {
    final User? user = currentUser;
    if (user == null) {
      return 'Guest';
    }

    final String? name = user.userMetadata?['display_name'] as String?;
    if (name != null && name.isNotEmpty) {
      return name;
    }

    final String email = user.email ?? '';
    return email.contains('@') ? email.split('@').first : 'User';
  }

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    return _client.auth.signUp(
      email: email.trim(),
      password: password,
      data: <String, dynamic>{'display_name': displayName.trim()},
    );
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// Sends a password reset email. Does not throw if email is not registered
  /// to prevent email enumeration.
  Future<void> sendPasswordReset(String email) async {
    await _client.auth.resetPasswordForEmail(email.trim());
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Human-readable error messages for Supabase AuthExceptions.
  static String friendlyError(AuthException e) {
    final String msg = e.message.toLowerCase();
    if (msg.contains('invalid login credentials') ||
        msg.contains('invalid email or password')) {
      return 'Incorrect email or password. Please try again.';
    }
    if (msg.contains('already registered') ||
        msg.contains('user already exists')) {
      return 'An account with this email already exists. Try signing in instead.';
    }
    if (msg.contains('password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (msg.contains('unable to validate email') ||
        msg.contains('invalid email')) {
      return 'Please enter a valid email address.';
    }
    if (msg.contains('email not confirmed')) {
      return 'Please check your email to confirm your account before signing in.';
    }
    if (msg.contains('rate limit')) {
      return 'Too many attempts. Please wait a few minutes and try again.';
    }
    if (msg.contains('failed host lookup') ||
        msg.contains('err_name_not_resolved') ||
        msg.contains('connection refused') ||
        msg.contains('network') ||
        msg.contains('clientexception')) {
      return 'Authentication server unreachable. Check your connection or server configuration.';
    }
    if (e.message.trim().isNotEmpty &&
        !msg.contains('xmlhttprequest') &&
        !msg.contains('socketexception')) {
      return e.message.trim();
    }
    return 'Something went wrong. Please check your connection and try again.';
  }
}
