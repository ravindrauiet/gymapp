part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 7 — venue's own plans (hourly … yearly, saved as centre plans) + FitKey pass monthly fee & consent
// ---------------------------------------------------------------------------

const _passConsentText = 'I allow FitKey pass users at my venue. For each FitKey pass check-in I will be paid my monthly '
    'fee ÷ 30, minus that year\'s commission. FitKey bears the GST on FitKey pass visits.';

const _gstNote = 'Prices you enter include GST (5%). When a user buys this plan, the GST part (price × 5/105) is '
    'deducted from your payout; FitKey files and pays it for you.';

/// Editable state of one plan duration in step 7.
class _PlanDraft {
  _PlanDraft(this.duration);

  final String duration;
  CentrePlan? existing;
  bool offered = false;
  final price = TextEditingController();
  final included = TextEditingController();
  int? perDay;
  int? perWeek;
  bool dirty = false;

  String get label => venuePlanDurations[duration] ?? duration;
  int? get pricePaise => rupeesToPaise(price.text);

  List<String> get inclusions => included.text
      .split(RegExp(r'[,\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .take(20)
      .toList();

  void fill(CentrePlan p) {
    existing = p;
    offered = p.isActive && p.approvalStatus != 'rejected';
    price.text = paiseToRupeesText(p.pricePaise);
    included.text = p.inclusions.join(', ');
    perDay = p.maxVisitsPerDay;
    perWeek = p.maxVisitsPerWeek;
    dirty = false;
  }

  Json body() => {
        'name': existing?.name ??
            switch (duration) {
              'hourly' => 'Hourly pass',
              'day' => 'Day pass',
              _ => '$label membership',
            },
        'description': existing?.description,
        // Keep a legacy `annual` plan's duration as is.
        'duration': existing?.duration ?? duration,
        'pricePaise': pricePaise,
        'inclusions': inclusions,
        'maxVisitsPerDay': perDay,
        'maxVisitsPerWeek': perWeek,
        'offerPct': existing?.offerPct ?? 0,
        'isActive': true,
      };

  void dispose() {
    price.dispose();
    included.dispose();
  }
}

/// Plans for the wizard: loaded from /memberships/partner/venues/:id/plans, saved with the draft.
class _PricingState {
  _PricingState({required this.onLoaded});

  /// Rebuilds the wizard after plans load (not an edit, so it doesn't mark the draft dirty).
  final VoidCallback onLoaded;
  final drafts = {for (final d in venuePlanDurations.keys) d: _PlanDraft(d)};
  bool loaded = false;
  bool loading = false;
  Object? error;

  /// Other active plans of the same durations (managed under Membership plans).
  int extraPlans = 0;

  Iterable<_PlanDraft> get offered => drafts.values.where((d) => d.offered);

  Future<void> load(BuildContext context, String venueId) async {
    if (loading) return;
    loading = true;
    error = null;
    try {
      final list = await context.read<PartnerSession>().api.centrePlans(venueId);
      extraPlans = 0;
      for (final p in list.plans.where((p) => p.approvalStatus != 'rejected')) {
        final d = drafts[canonicalDuration(p.duration)];
        if (d == null) continue;
        if (d.existing == null || (!d.existing!.isActive && p.isActive)) {
          d.fill(p);
        } else if (p.isActive) {
          extraPlans++;
        }
      }
      loaded = true;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      onLoaded();
    }
  }

  /// Only wrongly entered prices block (a plan switched on without a price). Plans, the monthly fee and the FitKey
  /// pass consent are optional — shown as recommendations by [validate].
  String? formatError() {
    for (final d in offered) {
      final p = d.pricePaise;
      if (p == null || p < 100) return 'Enter a price for the ${d.label} plan, or switch it off';
    }
    return null;
  }

  /// Recommendations for the pricing step (not blocking).
  String? validate(PartnerVenue v, {bool forSubmit = false}) {
    if (offered.isEmpty) return 'Offer at least one plan of your own (e.g. Monthly)';
    for (final d in offered) {
      final p = d.pricePaise;
      if (p == null || p < 100) return 'Enter a price for the ${d.label} plan';
    }
    if (v.monthlyFeePaise == null || v.monthlyFeePaise! < 100) return 'Enter your monthly fee for FitKey pass payouts';
    if (!v.passAccepted) return 'Tick the FitKey pass consent to continue';
    return null;
  }

  /// Creates / updates / deactivates the plans that changed.
  Future<void> save(PartnerApi api, String venueId) async {
    for (final d in drafts.values.where((d) => d.dirty)) {
      if (d.offered) {
        final price = d.pricePaise;
        if (price == null || price < 100) continue; // incomplete — kept in the wizard until it has a price
        final plan = d.existing == null
            ? await api.createCentrePlan(venueId, d.body())
            : await api.updateCentrePlan(d.existing!.id, d.body());
        d.existing = plan;
        if (!plan.isActive) d.existing = await api.setCentrePlanActive(plan.id, true);
      } else if (d.existing != null && d.existing!.isActive) {
        d.existing = await api.setCentrePlanActive(d.existing!.id, false);
      }
      d.dirty = false;
    }
  }

  void dispose() {
    for (final d in drafts.values) {
      d.dispose();
    }
  }
}

class _PricingStep extends StatefulWidget {
  const _PricingStep({required this.venue, required this.pricing, required this.onChanged, this.needsSave});

  final PartnerVenue venue;
  final _PricingState pricing;
  final VoidCallback onChanged;

  /// Non-null while a new venue can't be saved yet (plans are created once it is).
  final String? needsSave;

  @override
  State<_PricingStep> createState() => _PricingStepState();
}

class _PricingStepState extends State<_PricingStep> {
  late final _fee = TextEditingController(text: paiseToRupeesText(widget.venue.monthlyFeePaise));

  static const _quickInclusions = ['Gym floor', 'Cardio zone', 'Group classes', 'Trainer guidance', 'Locker', 'Shower', 'Parking'];

  @override
  void dispose() {
    _fee.dispose();
    super.dispose();
  }

  void _planChanged(_PlanDraft d) {
    d.dirty = true;
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final p = widget.pricing;
    final fee = v.monthlyFeePaise;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Pricing & FitKey pass',
            'Sell your own plans on FitKey, and set the monthly fee FitKey pays you per pass check-in.'),
        AppCard(
          color: AppColors.amberSoft,
          shadow: false,
          padding: const EdgeInsets.all(12),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.receipt_long_rounded, color: AppColors.amber, size: 20),
            SizedBox(width: 10),
            Expanded(child: Text(_gstNote, style: TextStyle(color: Color(0xFF7A4A00), fontSize: 12.5, height: 1.4))),
          ]),
        ),
        const SectionTitle('Your plans', subtitle: 'Pick which ones you offer'),
        if (p.loading && !p.loaded)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (p.error != null && !p.loaded)
          ErrorView(error: p.error!, onRetry: () => p.load(context, v.id!))
        else ...[
          for (final d in p.drafts.values)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: _planCard(d)),
          if (p.extraPlans > 0)
            Text('+ ${p.extraPlans} more plan${p.extraPlans == 1 ? '' : 's'} — manage them under Membership plans.',
                style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
          if (widget.needsSave != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Plans are saved with your draft. ${widget.needsSave}',
                  style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
            ),
        ],
        const SectionTitle('FitKey pass', subtitle: 'Members with a FitKey pass visit you; FitKey pays you per visit'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(9)],
              decoration: const InputDecoration(
                labelText: 'Your monthly fee *',
                hintText: 'e.g. 1500',
                prefixText: '₹ ',
                helperText: 'What a regular member pays you for one month',
              ),
              onChanged: (s) {
                final paise = rupeesToPaise(s);
                setState(() => v.monthlyFeePaise = paise == null || paise <= 0 ? null : paise);
                widget.onChanged();
              },
            ),
            if (fee != null && fee > 0) ...[
              const SizedBox(height: 14),
              const Text('YOU GET PER FITKEY PASS CHECK-IN', style: _caps),
              const SizedBox(height: 8),
              for (final y in const [1, 2, 3])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Icon(y == 1 ? Icons.star_rounded : Icons.circle, size: y == 1 ? 18 : 8,
                        color: y == 1 ? AppColors.green : AppColors.text3),
                    SizedBox(width: y == 1 ? 8 : 13),
                    Expanded(
                      child: Text(passPreviewLine(fee, y),
                          style: TextStyle(
                            fontWeight: y == 1 ? FontWeight.w800 : FontWeight.w600,
                            color: y == 1 ? AppColors.green : AppColors.text2,
                            fontSize: y == 1 ? 15 : 13.5,
                          )),
                    ),
                    Text(
                        '${CommissionPlan.pctForYear(y) == CommissionPlan.pctForYear(y).roundToDouble() ? CommissionPlan.pctForYear(y).toInt() : CommissionPlan.pctForYear(y)}% commission',
                        style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              Text('${formatPaise(fee)} ÷ 30 = ${formatPaise(fee ~/ 30)} per visit, before commission. FitKey bears the GST.',
                  style: const TextStyle(color: AppColors.text3, fontSize: 12, height: 1.4)),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            CheckboxListTile(
              value: v.passAccepted,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (on) {
                setState(() => v.passAccepted = on == true);
                widget.onChanged();
              },
              title: const Text(_passConsentText, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4)),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        const CommissionPlanCard(showPayoutRule: true),
      ],
    );
  }

  Widget _planCard(_PlanDraft d) {
    final price = d.pricePaise;
    final status = d.existing?.approvalStatus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: d.offered ? AppColors.primary : AppColors.line, width: d.offered ? 1.5 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Text(d.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              if (status != null && d.offered) ...[
                const SizedBox(width: 8),
                Tag(
                  status == 'approved' ? 'LIVE' : (status == 'pending' ? 'IN REVIEW' : status.toUpperCase()),
                  color: status == 'approved' ? AppColors.green : AppColors.blue,
                  dense: true,
                ),
              ],
            ]),
          ),
          Switch(
            value: d.offered,
            onChanged: (on) {
              d.offered = on;
              _planChanged(d);
            },
          ),
        ]),
        if (d.offered)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 8, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: d.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(9)],
                decoration: const InputDecoration(labelText: 'Price (incl. GST) *', prefixText: '₹ '),
                onChanged: (_) => _planChanged(d),
              ),
              const SizedBox(height: 6),
              if (price != null && price >= 100) ...[
                Text(directSaleLine(price, year: 1),
                    style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12.5)),
                Text(
                  'Year 2: ${formatPaise(CommissionPlan.directSaleNetPaise(price, year: 2))} · '
                  'Year 3+: ${formatPaise(CommissionPlan.directSaleNetPaise(price, year: 3))}',
                  style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: d.included,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'What\'s included', hintText: 'Gym floor, Locker, Shower'),
                onChanged: (_) => _planChanged(d),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 2, children: [
                for (final q in _quickInclusions.where((q) => !d.inclusions.contains(q)).take(5))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('+ $q', style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      d.included.text = [...d.inclusions, q].join(', ');
                      _planChanged(d);
                    },
                  ),
              ]),
              if (d.duration != 'hourly' && d.duration != 'day') ...[
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: _IntField(
                      label: 'Visits / day',
                      hint: 'No limit',
                      max: 10,
                      value: d.perDay,
                      onChanged: (n) {
                        d.perDay = n == 0 ? null : n;
                        _planChanged(d);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _IntField(
                      label: 'Visits / week',
                      hint: 'No limit',
                      max: 50,
                      value: d.perWeek,
                      onChanged: (n) {
                        d.perWeek = n == 0 ? null : n;
                        _planChanged(d);
                      },
                    ),
                  ),
                ]),
              ],
            ]),
          ),
      ]),
    );
  }
}
