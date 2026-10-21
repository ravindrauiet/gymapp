import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';
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
    session.api.cities().then((c) {
      if (mounted) setState(() => _cities = c);
    }).catchError((_) {});
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<Session>().updateProfile({
        'name': _name.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
        'city': _city.text.trim(),
        'gender': ?_gender,
      });
      if (mounted) {
        if (widget.editing) {
          Navigator.pop(context);
        } else {
          // Flow: User Registration / Profile Setup -> Goal Selection Screen
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const GoalSelectionScreen()),
          );
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
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
      appBar: AppBar(
        title: Text(widget.editing ? 'Edit profile' : ''),
        actions: [
          if (!widget.editing)
            TextButton(onPressed: () => context.read<Session>().signOut(), child: const Text('Log out')),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              if (!widget.editing) ...[
                Text('Let\'s set up\nyour profile', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text('This helps us show venues near you and match you with gym buddies.',
                    style: TextStyle(color: FkColors.textSecondary)),
                const SizedBox(height: 28),
              ],
              _label('Full name'),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'e.g. Asha Kumar'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
              ),
              _label('Email'),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(hintText: 'you@example.com'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return null;
                  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value) ? null : 'Enter a valid email';
                },
              ),
              _label('City'),
              Autocomplete<String>(
                initialValue: TextEditingValue(text: _city.text),
                optionsBuilder: (v) =>
                    _cities.where((c) => c.toLowerCase().contains(v.text.toLowerCase())),
                onSelected: (c) => _city.text = c,
                fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(hintText: 'e.g. Bengaluru', prefixIcon: Icon(Icons.location_city)),
                  onChanged: (v) => _city.text = v,
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your city' : null,
                ),
              ),
              _label('Gender'),
              SegmentedButton<String>(
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'male', label: Text('Male')),
                  ButtonSegment(value: 'female', label: Text('Female')),
                  ButtonSegment(value: 'other', label: Text('Other')),
                ],
                selected: {?_gender},
                onSelectionChanged: (s) => setState(() => _gender = s.isEmpty ? null : s.first),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(widget.editing ? 'Save' : 'Start my journey'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}
