import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/partner_session.dart';
import '../../ui/ui.dart';

/// Owner account details. Shown after first login (BRD P1 needs phone + email) and from the Account tab.
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
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await context.read<PartnerSession>().updateProfile({
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        if (_city.text.trim().length >= 2) 'city': _city.text.trim(),
      });
      if (!mounted) return;
      if (widget.editing) {
        toast(context, 'Profile updated');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _logout() async {
    final session = context.read<PartnerSession>();
    if (widget.editing) Navigator.of(context).popUntil((r) => r.isFirst);
    await session.signOut();
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
      backgroundColor: widget.editing ? AppColors.bg : AppColors.surface,
      appBar: AppBar(
        title: Text(widget.editing ? 'Edit profile' : ''),
        actions: [
          if (!widget.editing) TextButton(onPressed: _logout, child: const Text('Log out')),
        ],
      ),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: widget.editing ? 'Save changes' : 'Continue',
          icon: widget.editing ? Icons.check_rounded : null,
          trailing: widget.editing ? null : const Icon(Icons.arrow_forward_rounded, size: 20),
          busy: _saving,
          onPressed: _save,
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (!widget.editing) ...[
              const IconBubble(Icons.badge_rounded, size: 56),
              const SizedBox(height: 18),
              const Text('Tell us about you',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
              const SizedBox(height: 6),
              const Text('We\'ll use this to contact you about your listings, orders and payouts.',
                  style: TextStyle(color: AppColors.text2, fontSize: 15, height: 1.4)),
              const SizedBox(height: 24),
            ] else ...[
              Center(child: PersonAvatar(name: session.user?.name, size: 76)),
              const SizedBox(height: 20),
            ],
            AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const IconBubble(Icons.verified_user_rounded, color: AppColors.green, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(session.user?.phone ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const Text('Verified mobile number', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
                  ]),
                ),
                const Tag('VERIFIED', color: AppColors.green, dense: true),
              ]),
            ),
            const SizedBox(height: 22),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Owner / manager name',
                hintText: 'e.g. Rohan Mehta',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: widget.editing ? TextInputAction.done : TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Business email',
                hintText: 'owner@yourgym.com',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              validator: (v) =>
                  RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
            ),
            if (!widget.editing) ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: _city,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'City (optional)',
                  hintText: 'e.g. Bengaluru',
                  prefixIcon: Icon(Icons.location_city_rounded),
                ),
                onFieldSubmitted: (_) => _save(),
              ),
            ],
            if (widget.editing) ...[
              const SizedBox(height: 28),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, color: AppColors.red),
                label: const Text('Log out', style: TextStyle(color: AppColors.red)),
                onPressed: _logout,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
