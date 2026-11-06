import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart';

/// Create or edit a centre membership plan. Pops `true` when saved.
class PlanFormScreen extends StatefulWidget {
  const PlanFormScreen({
    super.key,
    required this.venueId,
    required this.venueName,
    required this.commissionPct,
    this.existing,
  });

  final String venueId;
  final String venueName;
  final double commissionPct;
  final CentrePlan? existing;

  @override
  State<PlanFormScreen> createState() => _PlanFormScreenState();
}

const _suggestedInclusions = [
  'Gym floor',
  'Cardio zone',
  'Group classes',
  'Trainer guidance',
  'Locker',
  'Shower',
  'Steam / sauna',
  'Towel',
  'Parking',
  'Diet consultation',
  'Body composition scan',
  'Pool access',
];

class _PlanFormScreenState extends State<PlanFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late final _price = TextEditingController(
      text: widget.existing == null ? '' : (widget.existing!.pricePaise / 100).toStringAsFixed(widget.existing!.pricePaise % 100 == 0 ? 0 : 2));
  final _custom = TextEditingController();
  late String _duration = widget.existing?.duration ?? 'monthly';
  late final List<String> _inclusions = [...?widget.existing?.inclusions];
  late int? _perDay = widget.existing?.maxVisitsPerDay;
  late int? _perWeek = widget.existing?.maxVisitsPerWeek;
  late int _offer = widget.existing?.offerPct ?? 0;
  late bool _active = widget.existing?.isActive ?? true;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _price.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _price.removeListener(_refresh);
    _name.dispose();
    _desc.dispose();
    _price.dispose();
    _custom.dispose();
    super.dispose();
  }

  int? get _pricePaise {
    final v = double.tryParse(_price.text.replaceAll(',', '').trim());
    return v == null ? null : (v * 100).round();
  }

  void _addCustom() {
    final t = _custom.text.trim();
    if (t.isEmpty) return;
    if (_inclusions.length >= 20) {
      toast(context, 'Up to 20 inclusions per plan', error: true);
      return;
    }
    setState(() {
      if (!_inclusions.contains(t)) _inclusions.add(t);
      _custom.clear();
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_perDay != null && _perWeek != null && _perWeek! < _perDay!) {
      toast(context, 'Weekly limit can\'t be lower than the daily limit', error: true);
      return;
    }
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      'duration': _duration,
      'pricePaise': _pricePaise,
      'inclusions': _inclusions,
      'maxVisitsPerDay': _perDay,
      'maxVisitsPerWeek': _perWeek,
      'offerPct': _offer,
      'isActive': _active,
    };
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      if (_editing) {
        await api.updateCentrePlan(widget.existing!.id, body);
      } else {
        await api.createCentrePlan(widget.venueId, body);
      }
      if (!mounted) return;
      toast(context, _editing ? 'Changes sent to FitKey for review' : 'Plan submitted — FitKey will review it shortly');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = _pricePaise ?? 0;
    final memberPays = priceAfterOffer(price, _offer);
    final fee = (memberPays * widget.commissionPct / 100).round();
    final pct = '${widget.commissionPct % 1 == 0 ? widget.commissionPct.toInt() : widget.commissionPct.toStringAsFixed(1)}%';

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit plan' : 'New membership plan')),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: _editing ? 'Save & send for review' : 'Submit for review',
          icon: Icons.send_rounded,
          busy: _saving,
          onPressed: _save,
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 28), children: [
          NoteStrip(
            icon: Icons.verified_user_outlined,
            color: AppColors.amber,
            text: _editing
                ? 'Saving changes sends this plan back to FitKey for review — it is hidden from new buyers until approved. '
                    'Members who already bought it keep their original terms.'
                : 'FitKey reviews every new plan (usually within a working day). It goes on sale for ${widget.venueName} once approved.',
          ),
          const SectionTitle('Plan basics', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Plan name', hintText: 'e.g. Monthly unlimited', counterText: ''),
            validator: (v) => (v ?? '').trim().length < 2 ? 'Give the plan a name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _desc,
            maxLines: 3,
            minLines: 2,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Description (optional)', hintText: 'Who is it for, timings, rules…'),
          ),
          const SectionTitle('Duration', padding: EdgeInsets.fromLTRB(0, 14, 0, 12)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in planDurations.entries)
              ChoiceChip(
                label: Text('${e.value.label} · ${e.value.days}d'),
                selected: _duration == e.key,
                onSelected: (_) => setState(() => _duration = e.key),
              ),
          ]),
          const SectionTitle('Price', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
          TextFormField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Price (₹)', prefixText: '₹ ', hintText: '2499'),
            validator: (_) {
              final p = _pricePaise;
              if (p == null) return 'Enter a price';
              if (p < 100) return 'Minimum ₹1';
              if (p > 10000000) return 'Maximum ₹1,00,000';
              return null;
            },
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Text('Launch offer', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(_offer == 0 ? 'None' : '$_offer% off',
                style: TextStyle(fontWeight: FontWeight.w800, color: _offer == 0 ? AppColors.text3 : AppColors.primary)),
          ]),
          Slider(
            value: _offer.toDouble(),
            max: 90,
            divisions: 90,
            label: '$_offer%',
            onChanged: (v) => setState(() => _offer = v.round()),
          ),
          if (price >= 100)
            AppCard(
              border: true,
              shadow: false,
              color: AppColors.bg,
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                _money('Members pay', formatPaise(memberPays), bold: true),
                const SizedBox(height: 6),
                _money('FitKey commission ($pct)', '− ${formatPaise(fee)}', color: AppColors.text2),
                const Divider(height: 18),
                _money('You receive per sale', formatPaise(memberPays - fee), bold: true, color: AppColors.green),
              ]),
            ),
          const SectionTitle('What\'s included', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final i in {..._suggestedInclusions, ..._inclusions})
              FilterChip(
                label: Text(i),
                selected: _inclusions.contains(i),
                onSelected: (on) => setState(() {
                  if (on) {
                    if (_inclusions.length < 20) _inclusions.add(i);
                  } else {
                    _inclusions.remove(i);
                  }
                }),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _custom,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _addCustom(),
                decoration: const InputDecoration(hintText: 'Add your own (e.g. Zumba)', counterText: '', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(onPressed: _addCustom, icon: const Icon(Icons.add_rounded)),
          ]),
          const SectionTitle('Visit limits',
              subtitle: 'Members book slots or walk in for free within these limits',
              padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(children: [
              _limit('Visits per day', _perDay, 10, (v) => setState(() => _perDay = v)),
              const Divider(height: 1),
              _limit('Visits per week', _perWeek, 70, (v) => setState(() => _perWeek = v)),
            ]),
          ),
          const SizedBox(height: 14),
          AppCard(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Put on sale when approved', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('You can switch it off any time', style: TextStyle(fontSize: 12.5)),
            ),
          ),
          const SizedBox(height: 14),
          const Text('Memberships are non-refundable for members — this is shown to them at checkout.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.text3, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _money(String label, String value, {bool bold = false, Color color = AppColors.text}) => Row(children: [
        Expanded(child: Text(label, style: TextStyle(color: AppColors.text2, fontWeight: bold ? FontWeight.w700 : FontWeight.w500))),
        Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color, fontSize: bold ? 15 : 14)),
      ]);

  Widget _limit(String label, int? value, int max, ValueChanged<int?> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(value == null ? 'Unlimited' : 'Up to $value',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
          ]),
        ),
        if (value == null)
          OutlinedButton(onPressed: () => onChanged(1), child: const Text('Set limit'))
        else ...[
          IconButton(
            tooltip: 'Remove limit',
            onPressed: () => onChanged(null),
            icon: const Icon(Icons.all_inclusive_rounded, color: AppColors.text3),
          ),
          QtyStepper(qty: value, max: max, compact: true, onChanged: (v) => onChanged(v <= 0 ? null : v)),
        ],
      ]),
    );
  }
}
