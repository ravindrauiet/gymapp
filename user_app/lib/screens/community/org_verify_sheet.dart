import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/events_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

/// Org verification (BRD §3.1): work / college email OTP, an org invite code, or a college ID photo
/// (reviewed by the FitKey team). Resolves to the resulting membership, or null when dismissed.
Future<OrgMembership?> showOrgVerifySheet(BuildContext context, {required List<OrgRef> orgs}) =>
    showAppSheet<OrgMembership>(context, builder: (_) => _OrgVerifySheet(orgs: orgs));

enum _Method { email, invite, id }

class _OrgVerifySheet extends StatefulWidget {
  const _OrgVerifySheet({required this.orgs});
  final List<OrgRef> orgs;

  @override
  State<_OrgVerifySheet> createState() => _OrgVerifySheetState();
}

class _OrgVerifySheetState extends State<_OrgVerifySheet> {
  _Method _method = _Method.email;
  final _email = TextEditingController();
  final _otp = TextEditingController();
  final _code = TextEditingController();
  final _dept = TextEditingController();
  bool _busy = false;
  bool _codeSent = false;
  String? _matchedOrg;
  String? _devOtp;
  late String? _idOrgId = widget.orgs.where((o) => o.isCollege).firstOrNull?.id;
  XFile? _idPhoto;

  bool get _hasCollege => widget.orgs.any((o) => o.isCollege);
  String get _orgNames => widget.orgs.isEmpty ? 'your company or college' : widget.orgs.map((o) => o.name).join(' / ');

  @override
  void dispose() {
    _email.dispose();
    _otp.dispose();
    _code.dispose();
    _dept.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _done(OrgMembership m) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(m);
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      toast(context, 'Enter your official email address', error: true);
      return;
    }
    await _run(() async {
        final api = context.read<Session>().api;
        final r = await api.requestOrgEmailOtp(email, orgId: widget.orgs.length == 1 ? widget.orgs.first.id : null);
        if (!mounted) return;
        if (r.alreadyVerified) {
          final mine = await api.myOrgs();
          if (!mounted) return;
          final m = mine.where((m) => m.verified && m.orgName == r.orgName).firstOrNull;
          if (m != null) return _done(m);
          toast(context, "You're already verified at ${r.orgName}");
          Navigator.of(context).pop();
          return;
        }
        setState(() {
          _codeSent = true;
          _matchedOrg = r.orgName;
          _devOtp = r.devOtp;
          if (r.devOtp != null) _otp.text = r.devOtp!;
        });
      });
  }

  Future<void> _verifyCode() => _run(() async {
        final m = await context.read<Session>().api.verifyOrgEmail(_email.text.trim(), _otp.text.trim());
        if (mounted) _done(m);
      });

  Future<void> _useInvite() => _run(() async {
        final m = await context.read<Session>().api.joinOrgWithInvite(_code.text.trim());
        if (mounted) _done(m);
      });

  Future<void> _pickId(ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      if (f != null && mounted) setState(() => _idPhoto = f);
    } catch (_) {
      if (mounted) toast(context, 'Could not open the camera / gallery', error: true);
    }
  }

  Future<void> _submitId() => _run(() async {
        final api = context.read<Session>().api;
        final url = await api.upload(_idPhoto!);
        final dept = _dept.text.trim();
        final m = await api.submitOrgId(_idOrgId!, url, department: dept.isEmpty ? null : dept);
        if (!mounted) return;
        toast(context, "ID sent for review — we'll notify you once approved");
        _done(m);
      });

  @override
  Widget build(BuildContext context) {
    final methods = [_Method.email, _Method.invite, if (_hasCollege) _Method.id];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBubble(Icons.verified_user_rounded, color: AppColors.purple, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Verify your organisation', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              const SizedBox(height: 2),
              Text('For $_orgNames events. Verify once — your badge works for all their future events.',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, height: 1.35)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        ChoiceChips<_Method>(
          padding: EdgeInsets.zero,
          options: methods,
          selected: _method,
          label: (m) => switch (m) { _Method.email => 'Work / college email', _Method.invite => 'Invite code', _Method.id => 'College ID' },
          icon: (m) => switch (m) {
            _Method.email => Icons.alternate_email_rounded,
            _Method.invite => Icons.key_rounded,
            _Method.id => Icons.badge_rounded,
          },
          onSelected: (m) => setState(() => _method = m),
        ),
        const SizedBox(height: 18),
        ...switch (_method) {
          _Method.email => _emailStep(),
          _Method.invite => _inviteStep(),
          _Method.id => _idStep(),
        },
      ]),
    );
  }

  List<Widget> _emailStep() => [
        TextField(
          controller: _email,
          enabled: !_codeSent,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Official email',
            hintText: 'you@company.com',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        if (!_codeSent) ...[
          const SizedBox(height: 8),
          const Text("We'll send a 6-digit code to this address. Personal emails (Gmail etc.) won't work.",
              style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          AppButton(label: 'Send code', icon: Icons.send_rounded, busy: _busy, onPressed: _sendCode),
        ] else ...[
          const SizedBox(height: 12),
          AppCard(
            color: AppColors.greenSoft,
            shadow: false,
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.mark_email_read_rounded, color: AppColors.green, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Code sent for ${_matchedOrg ?? 'your organisation'}. Check your inbox.',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _otp,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Enter code',
              counterText: '',
              prefixIcon: const Icon(Icons.password_rounded),
              helperText: _devOtp != null ? 'Dev mode: code auto-filled' : null,
            ),
          ),
          const SizedBox(height: 16),
          AppButton(label: 'Verify', icon: Icons.verified_rounded, busy: _busy, onPressed: _verifyCode),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _codeSent = false),
            child: const Text('Use a different email'),
          ),
        ],
      ];

  List<Widget> _inviteStep() => [
        TextField(
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            hintText: 'From your HR / college fitness club',
            prefixIcon: Icon(Icons.key_rounded),
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          label: 'Verify with code',
          icon: Icons.verified_rounded,
          busy: _busy,
          onPressed: _useInvite,
        ),
      ];

  List<Widget> _idStep() {
    final colleges = widget.orgs.where((o) => o.isCollege).toList();
    return [
      if (colleges.length > 1) ...[
        ChoiceChips<String>(
          padding: EdgeInsets.zero,
          options: [for (final c in colleges) c.id],
          selected: _idOrgId ?? colleges.first.id,
          label: (id) => colleges.firstWhere((c) => c.id == id).name,
          onSelected: (id) => setState(() => _idOrgId = id),
        ),
        const SizedBox(height: 14),
      ],
      AppCard(
        border: true,
        shadow: false,
        onTap: () => _pickId(ImageSource.gallery),
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          IconBubble(_idPhoto == null ? Icons.add_a_photo_rounded : Icons.check_circle_rounded,
              color: _idPhoto == null ? AppColors.blue : AppColors.green, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_idPhoto == null ? 'Add a photo of your college ID' : _idPhoto!.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('Name and college must be readable. Only the FitKey team sees it.',
                  style: TextStyle(fontSize: 12, color: AppColors.text2)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _pickId(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_rounded),
            label: const Text('Camera'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _pickId(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_rounded),
            label: const Text('Gallery'),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      TextField(
        controller: _dept,
        decoration: const InputDecoration(labelText: 'Department / course (optional)', prefixIcon: Icon(Icons.school_rounded)),
      ),
      const SizedBox(height: 16),
      AppButton(
        label: 'Submit for review',
        icon: Icons.upload_rounded,
        busy: _busy,
        onPressed: _idPhoto == null || _idOrgId == null ? null : _submitId,
      ),
    ];
  }
}
