import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../ui/ui.dart';
import '../goals/goal_selection_screen.dart';

/// Shown after first login (and from Profile → Edit) to capture name, email, city and gender.
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key, this.editing = false});

  final bool editing;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _city;
  String? _gender;
  bool _saving = false;
  List<String> _cities = const [];

  @override
  void initState() {
    super.initState();
    final session = context.read<Session>();
    final user = session.user;
    _name = TextEditingController(text: user?.name);
    _email = TextEditingController(text: user?.email);
    _city = TextEditingController(text: user?.city);
    _gender = user?.gender;
    _name.addListener(() => setState(() {}));
    session.api.cities().then((c) {
      if (mounted) setState(() => _cities = c);
    }).catchError((_) {});
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    // Saving a first profile flips the session to signed-in, which replaces this screen;
    // grab the navigator first so the goal step can still be pushed on top of Home.
    final nav = Navigator.of(context);
    try {
      await context.read<Session>().updateProfile({
        'name': _name.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
        'city': _city.text.trim(),
        'gender': ?_gender,
      });
      if (widget.editing) {
        nav.pop();
        if (mounted) toast(context, 'Profile updated');
      } else {
        nav.push(MaterialPageRoute(builder: (_) => const GoalSelectionScreen()));
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _city.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(widget.editing ? 'Edit profile' : ''),
        actions: [
          if (!widget.editing)
            TextButton(onPressed: () => context.read<Session>().signOut(), child: const Text('Log out')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          if (!widget.editing) ...[
            const Text('Let\'s get to know you',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.7)),
            const SizedBox(height: 6),
            const Text('We use this to show venues in your city and match you with gym buddies.',
                style: TextStyle(color: AppColors.text2, height: 1.4)),
            const SizedBox(height: 24),
          ],
          Center(child: PersonAvatar(name: _name.text.trim().isEmpty ? '?' : _name.text, size: 84)),
          const SizedBox(height: 24),
          _label('Full name'),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: 'e.g. Asha Kumar', prefixIcon: Icon(Icons.person_outline_rounded)),
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
          ),
          _label('Email (optional)'),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: 'you@example.com', prefixIcon: Icon(Icons.mail_outline_rounded)),
            validator: (v) {
              final value = (v ?? '').trim();
              if (value.isEmpty) return null;
              return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value) ? null : 'Enter a valid email';
            },
          ),
          _label('City'),
          TextFormField(
            controller: _city,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. Bengaluru', prefixIcon: Icon(Icons.location_city_rounded)),
            onChanged: (_) => setState(() {}),
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your city' : null,
          ),
          if (_cities.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _cities)
                Tap(
                  onTap: () => setState(() => _city.text = c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _city.text.toLowerCase() == c.toLowerCase() ? AppColors.primarySoft : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: _city.text.toLowerCase() == c.toLowerCase() ? AppColors.primary : Colors.transparent),
                    ),
                    child: Text(c, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                ),
            ]),
          ],
          _label('Gender'),
          Row(children: [
            for (final (id, label, icon) in const [
              ('male', 'Male', Icons.male_rounded),
              ('female', 'Female', Icons.female_rounded),
              ('other', 'Other', Icons.transgender_rounded),
            ]) ...[
              Expanded(
                child: Tap(
                  onTap: () => setState(() => _gender = _gender == id ? null : id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 56,
                    decoration: BoxDecoration(
                      color: _gender == id ? AppColors.primarySoft : AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _gender == id ? AppColors.primary : AppColors.line, width: 1.4),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, size: 20, color: _gender == id ? AppColors.primary : AppColors.text2),
                      const SizedBox(width: 6),
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
              if (id != 'other') const SizedBox(width: 10),
            ],
          ]),
          const SizedBox(height: 32),
          AppButton(
            label: widget.editing ? 'Save changes' : 'Continue',
            icon: widget.editing ? null : Icons.arrow_forward_rounded,
            busy: _saving,
            onPressed: _save,
          ),
        ]),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2, fontSize: 13.5)),
      );
}
