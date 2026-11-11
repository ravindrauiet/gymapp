// Listing wizard for trainers, clinics, chemists and store sellers (Partner BRD §7, contract §H):
// Profile → Pricing → Availability → Documents & bank → Review & submit, with Save draft, checklist and step jump.
// After submit the status timeline takes over (fix → jump to the step).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../data/types_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/agreement_sheet.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/listing/documents_bank_step.dart';
import '../../widgets/status.dart';
import '../../widgets/status_timeline.dart';
import 'listing_fields.dart';
import 'type_forms.dart';

class TypeListingScreen extends StatefulWidget {
  const TypeListingScreen({super.key, required this.type});
  final PartnerType type;

  @override
  State<TypeListingScreen> createState() => _TypeListingScreenState();
}

class _TypeListingScreenState extends State<TypeListingScreen> {
  late final TypeForm _form = TypeForm.create(widget.type, context.read<PartnerSession>().user);
  final _scroll = ScrollController();

  TypeListingBundle? _bundle;
  Object? _loadError;
  bool _loading = true;
  bool _saving = false;
  bool _submitting = false;
  bool _dirty = false;
  bool _docsReady = false;

  /// false = status view (after submit); true = editing the wizard.
  bool _editing = true;
  int _step = 0;

  static const _stepCount = 5;

  List<String> get _titles => [
        _form.profileTitle,
        _form.pricingTitle,
        _form.availabilityTitle,
        'Documents & bank',
        'Review & submit',
      ];

  String? get _id => _bundle?.id;
  VenueStatus get _status => _bundle?.status ?? VenueStatus.draft;
  bool get _accepted => _bundle?.listing?['partnerAcceptedAt'] != null;

  @override
  void initState() {
    super.initState();
    _form.addListener(_onFormChanged);
    _load(initial: true);
  }

  @override
  void dispose() {
    _form.removeListener(_onFormChanged);
    _form.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFormChanged() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  Future<void> _load({bool initial = false}) async {
    setState(() {
      _loading = initial;
      _loadError = null;
    });
    try {
      final b = await context.read<PartnerSession>().api.typeListing(widget.type);
      if (!mounted) return;
      setState(() {
        _bundle = b;
        _loading = false;
        if (initial) {
          _form.load(b.listing);
          _dirty = false;
          final st = b.status;
          _editing = st == VenueStatus.draft;
          if (b.listingStep > 1 && st == VenueStatus.draft) _step = (b.listingStep - 1).clamp(0, _stepCount - 1);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          if (initial) _loadError = e;
        });
      }
    }
  }

  /// PUT the form. Returns false on failure (toast shown).
  Future<bool> _save({bool quiet = false}) async {
    final problem = _form.blockingProblem(0);
    if (problem != null) {
      toast(context, problem, error: true);
      if (_step != 0) _goTo(0);
      return false;
    }
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      final body = {..._form.toJson(), 'listingStep': _step + 1};
      final r = await api.saveTypeListing(widget.type, body);
      // PUT returns the full bundle; fall back to a GET if it didn't.
      final fresh = r.listing != null ? r : await api.typeListing(widget.type);
      if (!mounted) return false;
      setState(() {
        _bundle = fresh;
        _dirty = false;
      });
      if (!quiet) toast(context, 'Draft saved', icon: Icons.save_rounded);
      return true;
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _goTo(int step) {
    setState(() => _step = step.clamp(0, _stepCount - 1));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _next() async {
    final p = _form.blockingProblem(_step);
    if (p != null) return toast(context, p, error: true);
    // Save when there are edits, or when the documents step needs an id.
    if (_dirty || _id == null) {
      if (!await _save(quiet: true)) return;
    }
    _goTo(_step + 1);
  }

  Future<void> _jump(int step) async {
    if (step == _step) return;
    if (_dirty || (_id == null && step >= 3)) {
      if (!await _save(quiet: true)) return;
    }
    _goTo(step);
  }

  Future<void> _submit() async {
    if (_dirty && !await _save(quiet: true)) return;
    final id = _id;
    if (id == null || !mounted) return;
    final session = context.read<PartnerSession>();
    // Owners accept the agreement by OTP before submitting; a FitKey employee can't (the OTP goes to the owner),
    // so for assisted listings the owner accepts at handover.
    if (!_accepted && !session.isActingAsPartner) {
      final ok = await showAgreementSheet(context, entityType: widget.type.entityType, entityId: id);
      if (!mounted) return;
      if (!ok) return toast(context, 'Accept the partner agreement to submit', error: true);
    }
    setState(() => _submitting = true);
    try {
      await session.api.submitTypeListing(widget.type);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await _load();
      if (!mounted) return;
      setState(() => _editing = false);
      toast(context, 'Submitted for review', icon: Icons.schedule_send_rounded);
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      await _load(); // refresh the checklist so the missing items show
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _acceptAfterApproval() async {
    final id = _id;
    if (id == null) return;
    final ok = await showAgreementSheet(context, entityType: widget.type.entityType, entityId: id);
    if (ok && mounted) {
      toast(context, 'Agreement accepted', icon: Icons.verified_user_rounded);
      await _load();
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty || !_editing) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save your changes?'),
        content: const Text('Your listing has unsaved changes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save draft')),
        ],
      ),
    );
    if (r == 'save') return _save();
    return r == 'discard';
  }

  // ------------------------------------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty || !_editing,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(_editing ? 'List as ${widget.type.label.toLowerCase()}' : 'Your listing'),
          actions: [
            if (_editing && !_loading && _loadError == null)
              TextButton(
                onPressed: _saving ? null : () => _save(),
                child: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save draft'),
              ),
          ],
        ),
        body: _loading
            ? const SkeletonList(count: 4, itemHeight: 120)
            : _loadError != null
                ? ErrorView(error: _loadError!, onRetry: () => _load(initial: true))
                : _editing
                    ? _wizard()
                    : _statusView(),
        bottomNavigationBar: _loading || _loadError != null || !_editing ? null : _bottomBar(),
      ),
    );
  }

  Widget _wizard() {
    final banner = _assistedBanner();
    return Column(children: [
      _StepStrip(
        titles: _titles,
        step: _step,
        done: (i) {
          final b = _bundle;
          if (b == null || _id == null) return false;
          final serverDone = b.checklist.percent > 0 && !b.checklist.stepMissing(i + 1);
          return i == 3 ? (_docsReady || serverDone) : serverDone;
        },
        missing: (i) => _bundle?.checklist.stepMissing(i + 1) ?? false,
        onTap: _jump,
      ),
      _ProgressBar(percent: _bundle?.checklist.percent ?? 0),
      Expanded(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
          children: [
            ?banner,
            if (_status == VenueStatus.changesNeeded || _status == VenueStatus.rejected) ...[
              _timeline(),
              const SizedBox(height: 14),
            ],
            Text('Step ${_step + 1} of $_stepCount',
                style: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w700, fontSize: 12.5)),
            const SizedBox(height: 2),
            Text(_titles[_step], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            const SizedBox(height: 14),
            _stepBody(),
          ],
        ),
      ),
    ]);
  }

  Widget? _assistedBanner() {
    final s = context.watch<PartnerSession>();
    if (!s.isActingAsPartner) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InfoNote(
        'Listing on behalf of ${s.user?.name ?? s.user?.phone ?? 'the partner'}. They accept the agreement with their own OTP after approval.',
        icon: Icons.support_agent_rounded,
        color: AppColors.purple,
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _form.profileStep(context);
      case 1:
        return _form.pricingStep(context);
      case 2:
        return _form.availabilityStep(context);
      case 3:
        final id = _id;
        if (id == null) {
          return EmptyView(
            icon: Icons.save_rounded,
            title: 'Save your profile first',
            message: 'Documents are attached to your listing, so save it once before uploading.',
            action: SizedBox(width: 200, child: AppButton(label: 'Save draft', busy: _saving, onPressed: () => _save())),
          );
        }
        final note = _form.docsNote;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (note != null) ...[
            InfoNote(
              note,
              icon: note.contains('cannot') ? Icons.warning_amber_rounded : Icons.verified_rounded,
              color: note.contains('cannot') ? AppColors.amber : AppColors.green,
            ),
            const SizedBox(height: 14),
          ],
          DocumentsBankStep(
            key: ValueKey('docs-$id-${_form.requiredDocs.join(',')}'),
            entityType: widget.type.entityType,
            entityId: id,
            requiredDocTypes: _form.requiredDocs,
            optionalDocTypes: _form.optionalDocs,
            onReadyChanged: (r) {
              if (mounted && r != _docsReady) setState(() => _docsReady = r);
            },
          ),
        ]);
      default:
        return _review();
    }
  }

  Widget _review() {
    final missing = _bundle?.checklist.missing ?? const <ChecklistItem>[];
    final acting = context.watch<PartnerSession>().isActingAsPartner;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _PreviewCard(form: _form),
      const SizedBox(height: 14),
      _ChecklistCard(
        percent: _bundle?.checklist.percent ?? 0,
        missing: missing,
        titles: _titles,
        onJump: (step) => _jump(step - 1),
      ),
      const SizedBox(height: 14),
      const CommissionPlanCard(showPayoutRule: true),
      const SizedBox(height: 14),
      AppCard(
        child: Row(children: [
          IconBubble(
            _accepted ? Icons.verified_user_rounded : Icons.gavel_rounded,
            color: _accepted ? AppColors.green : AppColors.purple,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Partner agreement', style: TextStyle(fontWeight: FontWeight.w800)),
              Text(
                _accepted
                    ? 'Accepted by OTP'
                    : acting
                        ? 'The partner accepts it with their own OTP after approval.'
                        : 'You\'ll confirm it with an OTP when you submit.',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
              ),
            ]),
          ),
          if (!_accepted && !acting && _id != null)
            TextButton(
              onPressed: () async {
                final ok = await showAgreementSheet(context, entityType: widget.type.entityType, entityId: _id!);
                if (ok) await _load();
              },
              child: const Text('Read'),
            ),
        ]),
      ),
      const SizedBox(height: 14),
      const InfoNote(
        'We review new listings within 48 hours. You\'ll get a notification for every status change.',
        icon: Icons.schedule_rounded,
      ),
    ]);
  }

  Widget _timeline() => ListingStatusTimeline(
        entityType: widget.type.entityType,
        entityId: _id!,
        status: _status,
        onFix: (step) {
          setState(() => _editing = true);
          _goTo(step - 1);
        },
        onAccept: _acceptAfterApproval,
      );

  Widget _statusView() {
    final st = _status;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ?_assistedBanner(),
          if (_id != null) _timeline(),
          for (final b in _bundle?.goLiveBlockers ?? const <ChecklistItem>[]) ...[
            const SizedBox(height: 10),
            InfoNote(
              (b.hint ?? '').isEmpty ? b.label : '${b.label} — ${b.hint}',
              icon: Icons.warning_amber_rounded,
              color: AppColors.amber,
            ),
          ],
          const SizedBox(height: 14),
          _PreviewCard(form: _form, status: st),
          const SizedBox(height: 14),
          if (st == VenueStatus.changesNeeded || st == VenueStatus.rejected || st == VenueStatus.live)
            AppButton(
              label: st == VenueStatus.live ? 'Edit listing' : 'Fix & resubmit',
              icon: Icons.edit_rounded,
              onPressed: () => setState(() {
                _editing = true;
                _step = 0;
              }),
            )
          else
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _editing = true;
                _step = _stepCount - 1;
              }),
              icon: const Icon(Icons.visibility_rounded),
              label: const Text('View submitted details'),
            ),
          const SizedBox(height: 14),
          const CommissionPlanCard(compact: true),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final last = _step == _stepCount - 1;
    final canSubmit = _status.canSubmit;
    return BottomActionBar(
      leading: _step == 0
          ? null
          : SizedBox(
              height: 54,
              child: OutlinedButton(
                onPressed: _saving || _submitting ? null : () => _goTo(_step - 1),
                child: const Icon(Icons.arrow_back_rounded),
              ),
            ),
      child: last
          ? AppButton(
              label: canSubmit
                  ? (_status == VenueStatus.draft ? 'Submit for review' : 'Resubmit for review')
                  : 'Save changes',
              icon: canSubmit ? Icons.send_rounded : Icons.save_rounded,
              busy: _submitting || _saving,
              onPressed: canSubmit ? _submit : () => _save(),
            )
          : AppButton(
              label: 'Save & continue',
              trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
              busy: _saving,
              onPressed: _next,
            ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------

class _StepStrip extends StatelessWidget {
  const _StepStrip({required this.titles, required this.step, required this.done, required this.missing, required this.onTap});
  final List<String> titles;
  final int step;
  final bool Function(int) done;
  final bool Function(int) missing;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      height: 58,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: titles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final on = i == step;
          final ok = done(i) && i < titles.length - 1;
          final warn = missing(i) && !on;
          return Tap(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: on ? AppColors.ink : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ok ? AppColors.green : (on ? Colors.white24 : AppColors.line),
                  ),
                  child: ok
                      ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                      : Text('${i + 1}',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: on ? Colors.white : AppColors.text2)),
                ),
                const SizedBox(width: 7),
                Text(titles[i],
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: on ? Colors.white : AppColors.text)),
                if (warn) ...[
                  const SizedBox(width: 5),
                  Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.amber, shape: BoxShape.circle)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.percent});
  final int percent;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: percent.clamp(0, 100) / 100),
        duration: const Duration(milliseconds: 400),
        builder: (_, v, _) => LinearProgressIndicator(
          value: v,
          minHeight: 3,
          backgroundColor: AppColors.line,
          color: v >= 1 ? AppColors.green : AppColors.primary,
        ),
      );
}

class _ChecklistCard extends StatelessWidget {
  const _ChecklistCard({required this.percent, required this.missing, required this.titles, required this.onJump});
  final int percent;
  final List<ChecklistItem> missing;
  final List<String> titles;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final complete = missing.isEmpty;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: percent / 100,
                strokeWidth: 4,
                backgroundColor: AppColors.line,
                color: complete ? AppColors.green : AppColors.primary,
              ),
              Text('$percent%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(complete ? 'Ready to submit' : 'Before you submit',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text(complete ? 'Every required step is complete.' : '${missing.length} item${missing.length == 1 ? '' : 's'} left',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
        ]),
        for (final m in missing) ...[
          const SizedBox(height: 8),
          AppCard(
            shadow: false,
            color: AppColors.amberSoft,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            onTap: m.step >= 1 && m.step <= titles.length ? () => onJump(m.step) : null,
            child: Row(children: [
              const Icon(Icons.radio_button_unchecked_rounded, size: 18, color: AppColors.amber),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    m.step >= 1 && m.step <= titles.length ? '${titles[m.step - 1]}: ${m.label}' : m.label,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  if ((m.hint ?? '').isNotEmpty)
                    Text(m.hint!, style: const TextStyle(color: AppColors.text2, fontSize: 12, height: 1.3)),
                ]),
              ),
              if (m.step >= 1 && m.step <= titles.length)
                const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.form, this.status});
  final TypeForm form;
  final VenueStatus? status;

  @override
  Widget build(BuildContext context) {
    final rows = form.reviewRows().where((r) => r.$2.trim().isNotEmpty).toList();
    final photo = form.coverPhoto;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (photo != null)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: NetImage(photo, fallback: AppImages.gym, height: 150),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('HOW MEMBERS SEE YOU',
                      style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: AppColors.text3)),
                  const SizedBox(height: 2),
                  Text(form.displayName.trim().isEmpty ? 'Untitled' : form.displayName.trim(),
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                ]),
              ),
              if (status != null) StatusPill(status!) else Tag(form.type.label, color: AppColors.purple, dense: true),
            ]),
            if (rows.isNotEmpty) const SizedBox(height: 10),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 104,
                    child: Text(label, style: const TextStyle(color: AppColors.text3, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}
