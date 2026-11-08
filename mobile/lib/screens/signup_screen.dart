import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import 'auth_shell.dart';
import 'login_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

// Brand green used across the app (matching GradientButton / deep-green CTA).
const Color _brandGreen = Color(0xFF1B6B3A);
const Color _brandGreenLight = Color(0xFF2E8B50);

class _SignupScreenState extends State<SignupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final AuthResponse res = await AuthService.instance.signUp(
        email: _emailController.text,
        password: _passwordController.text,
        displayName: _nameController.text,
      );
      if (mounted) {
        if (res.session == null && res.user != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Account created! Please check your email to confirm your account.',
              ),
            ),
          );
        }
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop(true);
        }
      }
    } on AuthException catch (e) {
      setState(() {
        _errorMessage = AuthService.friendlyError(e);
      });
    } catch (e) {
      debugPrint('Auth sign-up error: $e');
      setState(() {
        _errorMessage =
            'Could not connect. Check your internet connection.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData prefixIconData,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        fontSize: 14,
        color: Color(0xFF64748B),
      ),
      prefixIcon: Icon(
        prefixIconData,
        size: 20,
        color: const Color(0xFF64748B),
      ),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Color(0xFFD0D8E4),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Color(0xFFD0D8E4),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: _brandGreen,
          width: 1.8,
        ),
      ),
    );
  }

  List<Widget> _buildFormWidgets() {
    return <Widget>[
      if (_errorMessage != null)
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 8,
          ),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            border: Border.all(
              color: const Color(0xFFFECACA),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                size: 18,
                color: Color(0xFFDC2626),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      TextFormField(
        controller: _nameController,
        textCapitalization: TextCapitalization.words,
        autofillHints: const <String>[AutofillHints.name],
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF142032),
        ),
        decoration: _fieldDecoration(
          label: 'Display name',
          
          prefixIconData: Icons.person_outline,
        ),
        validator: (String? value) =>
            value == null || value.trim().isEmpty
                ? 'Enter your name'
                : null,
      ),
      const SizedBox(height: 10),
      TextFormField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const <String>[
          AutofillHints.email,
          AutofillHints.username,
        ],
        autocorrect: false,
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF142032),
        ),
        decoration: _fieldDecoration(
          label: 'Email address',
          
          prefixIconData: Icons.email_outlined,
        ),
        validator: (String? value) {
          if (value == null || value.trim().isEmpty) {
            return 'Enter your email';
          }
          if (!value.contains('@')) {
            return 'Enter a valid email address';
          }
          return null;
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        controller: _passwordController,
        obscureText: _obscurePassword,
        autofillHints: const <String>[AutofillHints.newPassword],
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF142032),
        ),
        decoration: _fieldDecoration(
          label: 'Password',
          
          prefixIconData: Icons.lock_outlined,
        ).copyWith(
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: const Color(0xFF64748B),
            ),
            onPressed: () {
              setState(() {
                _obscurePassword = !_obscurePassword;
              });
            },
          ),
        ),
        validator: (String? value) {
          if (value == null || value.isEmpty) {
            return 'Enter a password';
          }
          if (value.length < 6) {
            return 'Password must be at least 6 characters';
          }
          return null;
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        controller: _confirmController,
        obscureText: _obscureConfirm,
        autofillHints: const <String>[AutofillHints.newPassword],
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF142032),
        ),
        decoration: _fieldDecoration(
          label: 'Confirm password',
          
          prefixIconData: Icons.lock_outline,
        ).copyWith(
          suffixIcon: IconButton(
            icon: Icon(
              _obscureConfirm
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: const Color(0xFF64748B),
            ),
            onPressed: () {
              setState(() {
                _obscureConfirm = !_obscureConfirm;
              });
            },
          ),
        ),
        validator: (String? value) {
          if (value == null || value.isEmpty) {
            return 'Confirm your password';
          }
          if (value != _passwordController.text) {
            return 'Passwords do not match';
          }
          return null;
        },
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 54,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: <Color>[_brandGreen, _brandGreenLight],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: _brandGreen.withValues(alpha: 0.30),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ElevatedButton(
              onPressed: _loading ? null : _signUp,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    _brandGreenLight.withValues(alpha: 0.5),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Create account',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          const Text(
            'Already have an account? ',
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFF64748B),
            ),
          ),
          GestureDetector(
            onTap: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const LoginScreen(),
                ),
              );
            },
            child: Text(
              'Sign in',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _brandGreen,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      body: SafeArea(
        child: AuthScreenShell(
          headlineText: 'Create your account',
          sublineText: 'Save places and unlock SOS + reporting',
          formKey: _formKey,
          formWidgets: _buildFormWidgets(),
        ),
      ),
    );
  }
}
