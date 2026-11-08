import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import 'auth_shell.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

// Brand green used across the app (matching GradientButton / deep-green CTA).
const Color _brandGreen = Color(0xFF1B6B3A);
const Color _brandGreenLight = Color(0xFF2E8B50);

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _loading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await AuthService.instance.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on AuthException catch (e) {
      setState(() {
        _errorMessage = AuthService.friendlyError(e);
      });
    } catch (e) {
      debugPrint('Auth sign-in error: $e');
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

  List<Widget> _buildFormWidgets() {
    return <Widget>[
      if (_errorMessage != null)
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 8,
          ),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            border: Border.all(
              color: const Color(0xFFFECACA),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
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
        decoration: InputDecoration(
          labelText: 'Email address',
          labelStyle: const TextStyle(
            fontSize: 14,
            color: Color(0xFF64748B),
          ),
          prefixIcon: const Icon(
            Icons.email_outlined,
            size: 20,
            color: Color(0xFF64748B),
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
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
        autofillHints: const <String>[AutofillHints.password],
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF142032),
        ),
        decoration: InputDecoration(
          labelText: 'Password',
          labelStyle: const TextStyle(
            fontSize: 14,
            color: Color(0xFF64748B),
          ),
          prefixIcon: const Icon(
            Icons.lock_outlined,
            size: 20,
            color: Color(0xFF64748B),
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
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
        validator: (String? value) =>
            value == null || value.isEmpty
                ? 'Enter your password'
                : null,
      ),
      const SizedBox(height: 2),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const ForgotPasswordScreen(),
              ),
            );
          },
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 4,
            ),
            minimumSize: Size.zero,
            tapTargetSize:
                MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            'Forgot password?',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _brandGreen,
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
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
              onPressed: _loading ? null : _signIn,
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
                      'Sign in',
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
      const SizedBox(height: 12),
      SizedBox(
        height: 50,
        child: OutlinedButton(
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop(false);
            }
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF334155),
            backgroundColor: Colors.white,
            elevation: 0,
            side: const BorderSide(
              color: Color(0xFFCBD5E1),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text(
            'Continue as guest',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
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
            "Don't have an account? ",
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
                  builder: (_) => const SignupScreen(),
                ),
              );
            },
            child: Text(
              'Sign up',
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
          headlineText: 'Welcome back',
          sublineText: 'Sign in to access your routes and safety reports',
          formKey: _formKey,
          formWidgets: _buildFormWidgets(),
        ),
      ),
    );
  }
}
