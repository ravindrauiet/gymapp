import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/partner_session.dart';

/// Owner account details. Shown after first login (BRD P1 needs phone + email) and from the account menu.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.editing = false});

  final bool editing;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: context.read<PartnerSession>().user?.name);
  late final _email = TextEditingController(text: context.read<PartnerSession>().user?.email);
  late final _city = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<PartnerSession>().updateProfile({
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        if (_city.text.trim().length >= 2) 'city': _city.text.trim(),
      });
      if (mounted && widget.editing) Navigator.pop(context);
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
    final session = context.watch<PartnerSession>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editing ? 'Account' : ''),
        actions: [
          if (!widget.editing) TextButton(onPressed: session.signOut, child: const Text('Log out')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            if (!widget.editing) ...[
              Text('Tell us about you', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('We\'ll use this to contact you about your listing and payouts.',
                  style: TextStyle(color: FkColors.textSecondary)),
              const SizedBox(height: 24),
            ],
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user, color: FkColors.lime),
                title: Text(session.user?.phone ?? ''),
                subtitle: const Text('Verified mobile number'),
              ),
            ),
            const SizedBox(height: 18),
            const Text('Owner / manager name', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'e.g. Rohan Mehta'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: 18),
            const Text('Business email', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(hintText: 'owner@yourgym.com'),
              validator: (v) =>
                  RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
            ),
            if (!widget.editing) ...[
              const SizedBox(height: 18),
              const Text('City', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _city,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'e.g. Bengaluru'),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : (widget.editing ? 'Save' : 'Continue')),
            ),
            if (widget.editing) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout, color: FkColors.danger),
                label: const Text('Log out'),
                onPressed: () async {
                  Navigator.pop(context);
                  await session.signOut();
                },
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
