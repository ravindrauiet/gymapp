import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import 'email_rules.dart';
import 'partner_type_screen.dart' show partnerTypeVisual;

/// "About you" (Partner BRD §2, after "What are you joining as?"): name, business email, city.
/// Also opened from the Account tab with [editing] = true.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.editing = false});

  final bool editing;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final _user = context.read<PartnerSession>().user;
  late final _name = TextEditingController(text: _user?.name);
  late final _email = TextEditingController(text: _user?.email);
  late final _city = TextEditingController(text: _user?.city);
  bool _saving = false;

  Future<void> _save() async {
    // Normalise first so what the partner sees is exactly what is validated and sent.
    final email = normalizeEmail(_email.text);
    if (email != _email.text) _email.text = email;
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await context.read<PartnerSession>().updateProfile({
        'name': _name.text.trim().replaceAll(RegExp(r'\s+'), ' '),
        'email': email,
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
    final type = PartnerType.parse(session.user?.partnerType);
    return Scaffold(
      backgroundColor: widget.editing ? AppColors.bg : AppColors.surface,
      appBar: AppBar(
        leading: !widget.editing && type != null
            ? IconButton(
                tooltip: 'Change what you are joining as',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: session.changePartnerType,
              )
            : null,
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
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              if (!widget.editing) ...[
                const _StepDots(step: 2),
                const SizedBox(height: 18),
                const Text('About you', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                const SizedBox(height: 6),
                const Text('We\'ll use this to contact you about your listings, bookings and payouts.',
                    style: TextStyle(color: AppColors.text2, fontSize: 15, height: 1.4)),
                const SizedBox(height: 20),
              ] else ...[
                Center(child: PersonAvatar(name: session.user?.name, size: 76)),
                const SizedBox(height: 20),
              ],
              AppCard(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Row(children: [
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
                  if (type != null) ...[
                    const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
                    Row(children: [
                      IconBubble(partnerTypeVisual(type).icon, color: partnerTypeVisual(type).color, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(type.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          const Text('Joining FitKey as', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
                        ]),
                      ),
                      if (!widget.editing)
                        TextButton(onPressed: session.changePartnerType, child: const Text('Change')),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(height: 22),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                decoration: const InputDecoration(
                  labelText: 'Your name',
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
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                autofillHints: const [AutofillHints.email],
                inputFormatters: const [NoWhitespaceFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Business email',
                  hintText: 'name@gmail.com',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
                validator: emailValidator,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _city,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.addressCity],
                decoration: const InputDecoration(
                  labelText: 'City',
                  hintText: 'e.g. Bengaluru',
                  prefixIcon: Icon(Icons.location_city_rounded),
                ),
                validator: (v) {
                  final c = (v ?? '').trim();
                  if (c.isEmpty) return widget.editing ? null : 'Enter your city';
                  return c.length < 2 ? 'Enter your city' : null;
                },
                onFieldSubmitted: (_) => _save(),
              ),
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
      ),
    );
  }
}

/// "Step 2 of 2" progress for onboarding (1 = partner type, 2 = About you).
class _StepDots extends StatelessWidget {
  const _StepDots({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var i = 1; i <= 2; i++) ...[
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: i == step ? 28 : 10,
          height: 6,
          decoration: BoxDecoration(
            color: i <= step ? AppColors.primary : AppColors.line,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
      ],
      const SizedBox(width: 4),
      Text('Step $step of 2', style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w700)),
    ]);
  }
}
