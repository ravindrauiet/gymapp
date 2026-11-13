import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show amenityLabels, formatPaise;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/listing_api.dart';
import '../../data/memberships_api.dart';
import '../../data/models.dart';
import '../../data/partner_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/agreement_sheet.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/listing/documents_bank_step.dart';
import '../../widgets/listing/listing_rules.dart';
import '../../widgets/listing/place_search.dart';
import '../../widgets/listing/photo_quality.dart';
import '../../widgets/status.dart';
import '../../widgets/status_timeline.dart';
import '../auth/email_rules.dart';
import 'location_picker_screen.dart';

part 'editor/editor_widgets.dart';
part 'editor/step_category_details.dart';
part 'editor/step_location.dart';
part 'editor/step_timings.dart';
part 'editor/step_photos.dart';
part 'editor/step_facilities_slots.dart';
part 'editor/step_pricing.dart';
part 'editor/step_review.dart';

/// Same rule as the backend's phoneSchema: 10 digits, or + and 10–15 digits (spaces / dashes ignored).
bool _validPhone(String s) => RegExp(r'^(\+\d{10,15}|\d{10})$').hasMatch(s.replaceAll(RegExp(r'[\s-]'), ''));

/// Venue listing wizard (Partner BRD §3) — 10 steps, "Save draft" at every step:
/// 1 Category · 2 Details · 3 Location · 4 Timings & FitKey access · 5 Photos · 6 Facilities ·
/// 7 Pricing & FitKey pass · 8 Slots & capacity · 9 Documents & bank · 10 Review & submit.
///
/// [initialStep] is 1-based (e.g. a "changes needed" fix for step 5 opens on Photos).
class VenueEditorScreen extends StatefulWidget {
  const VenueEditorScreen({super.key, this.existing, this.initialStep});

  final PartnerVenue? existing;
  final int? initialStep;

  @override
  State<VenueEditorScreen> createState() => _VenueEditorScreenState();
}

class _VenueEditorScreenState extends State<VenueEditorScreen> {
  static const titles = [
    'Category',
    'Details',
    'Location',
    'Timings & access',
    'Photos',
    'Facilities',
    'Pricing & pass',
    'Slots & capacity',
    'Documents & bank',
    'Review & submit',
  ];

  late final PartnerVenue _v = widget.existing?.copy() ?? PartnerVenue();
  late final WeekSchedule _schedule = WeekSchedule.fromVenue(_v);
  late final PageController _page;
  final _forms = {1: GlobalKey<FormState>(), 2: GlobalKey<FormState>()};
  late final _pricing = _PricingState(onLoaded: () {
    if (mounted) setState(() {});
  });

  late int _step;
  bool _saving = false;
  bool _submitting = false;
  bool _dirty = false;
  int _uploads = 0;
  bool _docsReady = false;
  VenueChecklist? _checklist;
  bool _submitted = false;

  /// Nullable fields the partner cleared (sent as explicit nulls).
  final _cleared = <String>{};

  bool get _isNew => _v.id == null;
  int get _last => titles.length - 1;

  @override
  void initState() {
    super.initState();
    _step = ((widget.initialStep ?? 1) - 1).clamp(0, _last);
    _page = PageController(initialPage: _step);
    if (!_isNew) {
      _loadChecklist();
      _pricing.load(context, _v.id!);
    } else {
      _pricing.loaded = true;
    }
  }

  @override
  void dispose() {
    _page.dispose();
    _pricing.dispose();
    super.dispose();
  }

  Future<void> _loadChecklist() async {
    try {
      final l = await context.read<PartnerSession>().api.venueListing(_v.id!);
      if (!mounted) return;
      setState(() {
        _checklist = l.checklist;
        // Server-side only fields (agreement / lifecycle) follow the latest copy.
        if (_v.partnerAcceptedAt == null && l.venue.partnerAcceptedAt != null) _acceptedAt = l.venue.partnerAcceptedAt;
      });
    } catch (_) {}
  }

  DateTime? _acceptedAt;
  bool get _agreementAccepted => (_acceptedAt ?? _v.partnerAcceptedAt) != null;

  void _changed() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  void _clearField(String field) => _cleared.add(field);
  void _setField(String field) => _cleared.remove(field);

  // ---- Validation --------------------------------------------------------------------------------------------

  /// Problems with step [step] (0-based) that BLOCK moving on / submitting. Only the basics are required (category,
  /// name, city + address or map pin, opening hours, one photo) and wrongly formatted input; everything else
  /// (description length, more photos, facilities, pricing, documents / KYC / bank) is a recommendation — see
  /// shown as tips from the server checklist — matching the server's checklist (backend utils/partner_rules.js).
  String? _validateStep(int step, {bool forSubmit = false}) {
    final v = _v;
    switch (step) {
      case 0:
        if (v.categories.isEmpty) return 'Pick at least one category';
        return null;
      case 1:
        if (v.name.trim().length < 2) return 'Enter the venue name';
        if (v.contactPhone.trim().isNotEmpty && !_validPhone(v.contactPhone)) return 'Enter a valid front-desk phone';
        if (v.contactEmail.trim().isNotEmpty && !isValidEmail(v.contactEmail)) return 'Enter a valid venue email';
        return null;
      case 2:
        if (v.city.trim().length < 2) return 'Enter the city';
        if (v.address.trim().length < 3 && (v.latitude == null || v.longitude == null)) {
          return 'Enter your address or use your current location';
        }
        return null;
      case 3:
        return validateSchedule(_schedule) ?? validatePassBlocks(v.fitkeyPassMode, v.passBlocks);
      case 4:
        if (_uploads > 0) return 'Wait for uploads to finish';
        if (forSubmit && v.photos.isEmpty) return 'Add at least one photo';
        return null;
      case 5:
        return null;
      case 6:
        return _pricing.formatError();
      case 7:
        if (v.slotCapacity < 1) return 'Enter how many members fit in one slot';
        if (v.passSlotCap != null && v.passSlotCap! > v.slotCapacity) {
          return 'The FitKey pass cap can\'t be more than the slot capacity';
        }
        if (v.categories.contains('sports_club') && v.courts < 1) return 'Enter how many courts / lanes you have';
        return null;
      case 8:
        return null; // documents, KYC and bank are optional (needed before the first payout)
      default:
        return null;
    }
  }

  List<({int step, String message})> get _problems => [
        for (var s = 0; s < _last; s++)
          if (_validateStep(s, forSubmit: true) case final e?) (step: s, message: e),
      ];

  // ---- Navigation --------------------------------------------------------------------------------------------

  void _jump(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _page.animateToPage(step, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    if (step + 1 > _v.listingStep) _v.listingStep = step + 1;
    // Steps 7 (plans) and 9 (documents) need a saved venue.
    if ((step == 6 || step == 8) && _isNew && _canCreate == null) _saveDraft(silent: true);
    if (step == _last && !_isNew) _loadChecklist();
  }

  /// Next: validates the current step, saves the draft when there are changes, then moves on.
  Future<void> _next() async {
    final error = _validateStep(_step);
    if (error != null) {
      toast(context, error, error: true);
      _forms[_step]?.currentState?.validate();
      return;
    }
    if (_dirty && _canCreate == null) {
      final ok = await _saveDraft(silent: true);
      if (!ok || !mounted) return;
    }
    _jump(_step + 1);
  }

  /// Why a brand-new venue can't be created on the server yet (POST needs name + categories), or null.
  String? get _canCreate {
    if (!_isNew) return null;
    if (_v.categories.isEmpty) return 'Pick a category first';
    if (_v.name.trim().length < 2) return 'Add the venue name (step 2) to save a draft';
    return null;
  }

  // ---- Save / submit -------------------------------------------------------------------------------------------

  /// Saves the venue (and step-7 plans) as a draft. Returns true when saved.
  Future<bool> _saveDraft({bool silent = false}) async {
    if (_saving) return false;
    final blocker = _canCreate;
    if (blocker != null) {
      if (!silent) toast(context, blocker, error: true);
      return false;
    }
    if (_uploads > 0) {
      if (!silent) toast(context, 'Wait for uploads to finish', error: true);
      return false;
    }
    // Format errors the server would reject anyway.
    if (_v.contactEmail.trim().isNotEmpty && !isValidEmail(_v.contactEmail)) {
      toast(context, 'Fix the venue email (step 2) to save', error: true);
      return false;
    }
    if (_v.contactPhone.trim().isNotEmpty && !_validPhone(_v.contactPhone)) {
      toast(context, 'Fix the front-desk phone (step 2) to save', error: true);
      return false;
    }
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      if (validateSchedule(_schedule) == null) _schedule.writeTo(_v);
      _v.contactEmail = normalizeEmail(_v.contactEmail);
      final saved = await api.saveVenueDraft(_v, clear: _cleared);
      _v.id = saved.id;
      _v.status = saved.status;
      _cleared.clear();
      if (_pricing.loaded) await _pricing.save(api, _v.id!);
      if (!mounted) return true;
      setState(() => _dirty = false);
      if (!silent) toast(context, 'Draft saved', icon: Icons.cloud_done_rounded);
      if (!_pricing.loaded) _pricing.load(context, _v.id!);
      return true;
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submit() async {
    final problems = _problems;
    if (problems.isNotEmpty) {
      toast(context, problems.first.message, error: true);
      _jump(problems.first.step);
      return;
    }
    setState(() => _submitting = true);
    try {
      if (!await _saveDraft(silent: true) || !mounted) return;
      final session = context.read<PartnerSession>();
      // The owner accepts the agreement by OTP. When a FitKey employee lists on the owner's behalf, the owner
      // accepts later (after approval) on their own phone.
      if (!_agreementAccepted && !session.isActingAsPartner) {
        final ok = await showAgreementSheet(context, entityType: 'venue', entityId: _v.id!);
        if (!ok || !mounted) return;
        _acceptedAt = DateTime.now();
      }
      final saved = await session.api.submitVenueListing(_v.id!);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _v.status = saved.status == VenueStatus.draft ? VenueStatus.submitted : saved.status;
        _submitted = true;
        _dirty = false;
      });
    } on SubmitIncomplete catch (e) {
      if (!mounted) return;
      toast(context, e.message, error: true);
      if (e.missing.isNotEmpty) {
        setState(() => _checklist = VenueChecklist(percent: _checklist?.percent ?? 0, done: const [], missing: e.missing));
        _jump((e.missing.first.step - 1).clamp(0, _last));
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _close() async {
    if (!_dirty || _saving) return Navigator.pop(context, !_isNew);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save your progress?'),
        content: const Text('You have changes that aren\'t saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard', style: TextStyle(color: AppColors.red)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save draft')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'save' && !await _saveDraft()) return;
    if (!mounted) return;
    setState(() => _dirty = false);
    Navigator.pop(context, !_isNew);
  }

  // ---- Build ---------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_submitted) return _SubmittedView(venue: _v, onDone: () => Navigator.pop(context, true), onFix: _fixFromTimeline);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step > 0) {
          _jump(_step - 1);
        } else {
          _close();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: _saving ? null : _close),
          title: Text(_isNew ? 'List your venue' : 'Edit listing'),
          actions: [
            if (_step < _last)
              TextButton.icon(
                onPressed: _saving ? null : () => _saveDraft(),
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_dirty ? Icons.save_outlined : Icons.cloud_done_outlined, size: 18),
                label: Text(_dirty || _isNew ? 'Save draft' : 'Saved'),
              ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(50),
            child: _StepHeader(
              titles: titles,
              step: _step,
              done: {for (var s = 0; s < _last; s++) if (_validateStep(s, forSubmit: true) == null) s},
              onTap: _jump,
            ),
          ),
        ),
        body: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _CategoryStep(venue: _v, onChanged: _changed),
            _DetailsStep(venue: _v, formKey: _forms[1]!, onChanged: _changed),
            _LocationStep(venue: _v, formKey: _forms[2]!, onChanged: _changed),
            _TimingsStep(venue: _v, schedule: _schedule, onChanged: _changed),
            _PhotosStep(
              venue: _v,
              onChanged: _changed,
              onUploading: (n) => setState(() => _uploads = n),
              onVideoCleared: () => _clearField('videoUrl'),
              onVideoSet: () => _setField('videoUrl'),
            ),
            _FacilitiesStep(venue: _v, onChanged: _changed),
            _PricingStep(venue: _v, pricing: _pricing, onChanged: _changed, needsSave: _isNew ? _canCreate : null),
            _SlotsStep(
              venue: _v,
              onChanged: _changed,
              onPassCapCleared: () => _clearField('passSlotCap'),
              onPassCapSet: () => _setField('passSlotCap'),
            ),
            _isNew
                ? _NeedsDraft(message: _canCreate ?? 'Saving your draft…', onSave: () => _saveDraft())
                : DocumentsBankStep(
                    entityType: 'venue',
                    entityId: _v.id!,
                    requiredDocTypes: const ['licence'], // shown as 'Recommended' — nothing here blocks submitting
                    optionalDocTypes: const ['gst'],
                    onReadyChanged: (ready) {
                      if (mounted && ready != _docsReady) setState(() => _docsReady = ready);
                    },
                  ),
            _ReviewStep(
              venue: _v,
              schedule: _schedule,
              pricing: _pricing,
              problems: _problems,
              checklist: _checklist,
              agreementAccepted: _agreementAccepted,
              onEdit: _jump,
            ),
          ],
        ),
        bottomNavigationBar: BottomActionBar(
          child: _step == _last
              ? (_v.status.canSubmit
                  ? Row(children: [
                      Expanded(
                        child: SizedBox(
                          height: 54,
                          child: OutlinedButton(
                            onPressed: _saving || _submitting ? null : () => _saveDraft(),
                            child: const Text('Save draft'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: AppButton(
                          label: _agreementAccepted || context.read<PartnerSession>().isActingAsPartner
                              ? 'Submit for review'
                              : 'Accept & submit',
                          icon: Icons.send_rounded,
                          busy: _submitting,
                          onPressed: _saving ? null : _submit,
                        ),
                      ),
                    ])
                  : AppButton(
                      label: 'Save changes',
                      icon: Icons.check_rounded,
                      busy: _saving,
                      onPressed: () async {
                        if (await _saveDraft(silent: true) && context.mounted) {
                          toast(context, 'Changes saved');
                          Navigator.pop(context, true);
                        }
                      },
                    ))
              : Row(children: [
                  if (_step > 0) ...[
                    SizedBox(
                      width: 54,
                      height: 54,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(54, 54)),
                        onPressed: () => _jump(_step - 1),
                        child: const Icon(Icons.arrow_back_rounded),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: AppButton(
                      label: _step == _last - 1 ? 'Review listing' : 'Next · ${titles[_step + 1]}',
                      trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
                      busy: _saving,
                      onPressed: _next,
                    ),
                  ),
                ]),
        ),
      ),
    );
  }

  void _fixFromTimeline(int step) {
    setState(() => _submitted = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jump((step - 1).clamp(0, _last));
    });
  }
}

/// Shown right after submitting (BRD §6.4): status timeline + "within 48 hours".
class _SubmittedView extends StatelessWidget {
  const _SubmittedView({required this.venue, required this.onDone, required this.onFix});

  final PartnerVenue venue;
  final VoidCallback onDone;
  final ValueChanged<int> onFix;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onDone();
      },
      child: Scaffold(
        backgroundColor: AppColors.surface,
        appBar: AppBar(automaticallyImplyLeading: false),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(color: AppColors.greenSoft, shape: BoxShape.circle),
              child: const Icon(Icons.task_alt_rounded, color: AppColors.green, size: 46),
            ),
          ),
          const SizedBox(height: 18),
          const Text('Submitted for review!',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const SizedBox(height: 8),
          Text(
            'The FITKEY team will check ${venue.name.trim().isEmpty ? 'your listing' : venue.name.trim()} within 48 hours. '
            'We\'ll notify you, and if anything needs fixing you\'ll see exactly what here.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.text2, height: 1.45),
          ),
          const SizedBox(height: 22),
          ListingStatusTimeline(entityType: 'venue', entityId: venue.id!, status: venue.status, onFix: onFix),
          const SizedBox(height: 14),
          const CommissionPlanCard(compact: true),
        ]),
        bottomNavigationBar: BottomActionBar(child: AppButton(label: 'Done', onPressed: onDone)),
      ),
    );
  }
}
