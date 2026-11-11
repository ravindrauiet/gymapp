import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise, formatShortDate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart' show NoteStrip;

Color sourceColor(MemberSource s) => switch (s) {
  MemberSource.self => AppColors.blue,
  MemberSource.fitkeyPass => AppColors.primary,
  MemberSource.fitkeyDirect => AppColors.purple,
  MemberSource.fitpass => AppColors.teal,
  MemberSource.other => AppColors.text2,
};

Color memberStatusColor(MemberStatus s) => switch (s) {
  MemberStatus.active => AppColors.green,
  MemberStatus.expiring => AppColors.amber,
  MemberStatus.expired => AppColors.red,
};

/// Member register (BRD §10.1): every member of a venue — FitKey members automatically, plus the partner's own
/// (manual) members — with plan, joining & renewal dates, source, price paid, earning per day and status.
class MemberRegisterScreen extends StatefulWidget {
  const MemberRegisterScreen({
    super.key,
    required this.venueId,
    required this.venueName,
    this.initialStatus,
    this.openAdd = false,
  });

  final String venueId;
  final String venueName;
  final MemberStatus? initialStatus;

  /// Opens the "Add member" sheet straight away (Home quick action).
  final bool openAdd;

  @override
  State<MemberRegisterScreen> createState() => _MemberRegisterScreenState();
}

class _MemberRegisterScreenState extends State<MemberRegisterScreen> {
  MemberSource? _source;
  late MemberStatus? _status = widget.initialStatus;
  String? _plan;
  String _q = '';
  bool _table = false;
  Timer? _debounce;
  late Future<List<VenueMember>> _future = _load();

  Future<List<VenueMember>> _load() => context.read<PartnerSession>().api.venueMembers(
    widget.venueId,
    source: _source?.api,
    status: _status?.name,
    q: _q.trim().isEmpty ? null : _q.trim(),
  );

  @override
  void initState() {
    super.initState();
    if (widget.openAdd) WidgetsBinding.instance.addPostFrameCallback((_) => _edit(null));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  void _onSearch(String v) {
    _q = v;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reload);
  }

  Future<void> _edit(VenueMember? m) async {
    if (m != null && !m.manual) {
      toast(context, 'FitKey members are added automatically and can\'t be edited', icon: Icons.info_outline_rounded);
      return;
    }
    final changed = await showAppSheet<bool>(
      context,
      builder: (_) => MemberFormSheet(venueId: widget.venueId, member: m),
    );
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Member register'),
            Text(
              widget.venueName,
              style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _table ? 'Card view' : 'Table view',
            icon: Icon(_table ? Icons.view_agenda_rounded : Icons.table_chart_rounded),
            onPressed: () => setState(() => _table = !_table),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add member'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search name or phone',
              ),
            ),
          ),
          const SizedBox(height: 6),
          ChoiceChips<MemberSource?>(
            options: [null, ...MemberSource.values],
            selected: _source,
            onSelected: (s) {
              _source = s;
              _reload();
            },
            label: (s) => s?.label ?? 'All sources',
          ),
          const SizedBox(height: 8),
          ChoiceChips<MemberStatus?>(
            options: [null, ...MemberStatus.values],
            selected: _status,
            onSelected: (s) {
              _status = s;
              _reload();
            },
            label: (s) => s?.label ?? 'Any status',
          ),
          Expanded(
            child: FutureBuilder<List<VenueMember>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 110);
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final all = snap.data!;
                final plans = {
                  for (final m in all)
                    if (m.planLabel.isNotEmpty) m.planLabel,
                }.toList()..sort();
                final members = _plan == null ? all : all.where((m) => m.planLabel == _plan).toList();
                return RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 96),
                    children: [
                      if (plans.length > 1) ...[
                        SizedBox(
                          height: 40,
                          child: ChoiceChips<String?>(
                            padding: EdgeInsets.zero,
                            options: [null, ...plans],
                            selected: _plan,
                            onSelected: (p) => setState(() => _plan = p),
                            label: (p) => p ?? 'All plans',
                            icon: (p) => p == null ? Icons.card_membership_rounded : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      _Summary(members: members),
                      const SizedBox(height: 10),
                      const NoteStrip(
                        text: 'Renewal alerts: we\'ll remind you 7 days and 1 day before each renewal date.',
                        icon: Icons.notifications_active_rounded,
                      ),
                      const SizedBox(height: 12),
                      if (members.isEmpty)
                        EmptyView(
                          icon: Icons.groups_rounded,
                          title: 'No members found',
                          message: _q.isNotEmpty || _source != null || _status != null || _plan != null
                              ? 'Try a different search or filter.'
                              : 'Add your own members here. FitKey members appear automatically.',
                        )
                      else if (_table)
                        _MemberTable(members: members, onTap: _edit)
                      else
                        for (final m in members)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _MemberCard(member: m, onTap: () => _edit(m)),
                          ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.members});
  final List<VenueMember> members;

  @override
  Widget build(BuildContext context) {
    int count(MemberStatus s) => members.where((m) => m.status == s).length;
    final perDay = members.where((m) => m.status != MemberStatus.expired).fold(0, (s, m) => s + m.earningPerDayPaise);
    Widget cell(String v, String l, Color c) => Expanded(
      child: Column(
        children: [
          Text(
            v,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c),
          ),
          Text(
            l,
            style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Row(
        children: [
          cell('${count(MemberStatus.active)}', 'Active', AppColors.green),
          cell('${count(MemberStatus.expiring)}', 'Expiring', AppColors.amber),
          cell('${count(MemberStatus.expired)}', 'Expired', AppColors.red),
          cell(compactRupees(perDay), 'Earning / day', AppColors.text),
        ],
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.onTap});
  final VenueMember member;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = member;
    Widget kv(String k, String v) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(fontSize: 11, color: AppColors.text3, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            v,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ],
      ),
    );
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PersonAvatar(name: m.name, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    if (m.phone != null) Text(m.phone!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                  ],
                ),
              ),
              Tag(m.status.label, color: memberStatusColor(m.status), dense: true),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tag(m.source.label, color: sourceColor(m.source), dense: true),
              if (m.planLabel.isNotEmpty) Tag(m.planLabel, color: AppColors.text2, dense: true),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              kv('Joined', m.joinedOn == null ? '–' : formatShortDate(m.joinedOn!)),
              kv('Renews', m.renewalOn == null ? '–' : formatShortDate(m.renewalOn!)),
              kv('Paid', m.pricePaise == 0 ? '–' : formatPaise(m.pricePaise)),
              kv('Per day', m.earningPerDayPaise == 0 ? '–' : formatPaise(m.earningPerDayPaise)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberTable extends StatelessWidget {
  const _MemberTable({required this.members, required this.onTap});
  final List<VenueMember> members;
  final ValueChanged<VenueMember> onTap;

  @override
  Widget build(BuildContext context) {
    String d(DateTime? v) => v == null ? '–' : formatShortDate(v);
    return AppCard(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          showCheckboxColumn: false,
          headingTextStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: AppColors.text2),
          dataTextStyle: const TextStyle(fontSize: 13, color: AppColors.text),
          columnSpacing: 18,
          columns: const [
            DataColumn(label: Text('Name')),
            DataColumn(label: Text('Phone')),
            DataColumn(label: Text('DOJ')),
            DataColumn(label: Text('Plan')),
            DataColumn(label: Text('Renewal')),
            DataColumn(label: Text('Source')),
            DataColumn(label: Text('Price paid'), numeric: true),
            DataColumn(label: Text('Per day'), numeric: true),
            DataColumn(label: Text('Status')),
          ],
          rows: [
            for (final m in members)
              DataRow(
                onSelectChanged: (_) => onTap(m),
                cells: [
                  DataCell(Text(m.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                  DataCell(Text(m.phone ?? '–')),
                  DataCell(Text(d(m.joinedOn))),
                  DataCell(Text(m.planLabel.isEmpty ? '–' : m.planLabel)),
                  DataCell(Text(d(m.renewalOn))),
                  DataCell(
                    Text(
                      m.source.label,
                      style: TextStyle(color: sourceColor(m.source), fontWeight: FontWeight.w700),
                    ),
                  ),
                  DataCell(Text(m.pricePaise == 0 ? '–' : formatPaise(m.pricePaise))),
                  DataCell(Text(m.earningPerDayPaise == 0 ? '–' : formatPaise(m.earningPerDayPaise))),
                  DataCell(Tag(m.status.label, color: memberStatusColor(m.status), dense: true)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Add / edit / delete a manual member. Pops `true` when something changed.
class MemberFormSheet extends StatefulWidget {
  const MemberFormSheet({super.key, required this.venueId, this.member});
  final String venueId;
  final VenueMember? member;

  @override
  State<MemberFormSheet> createState() => _MemberFormSheetState();
}

class _MemberFormSheetState extends State<MemberFormSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.member?.name);
  late final _phone = TextEditingController(text: widget.member?.phone);
  late final _plan = TextEditingController(text: widget.member?.planLabel);
  late final _price = TextEditingController(
    text: widget.member == null || widget.member!.pricePaise == 0 ? '' : '${(widget.member!.pricePaise / 100).round()}',
  );
  late MemberSource _source = MemberSource.manual.contains(widget.member?.source)
      ? widget.member!.source
      : MemberSource.self;
  late DateTime _joined = widget.member?.joinedOn ?? DateUtils.dateOnly(DateTime.now());
  late DateTime? _renewal = widget.member?.renewalOn;
  late bool _remind = widget.member?.remindMember ?? false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _plan.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool renewal}) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: renewal ? (_renewal ?? _joined.add(const Duration(days: 30))) : _joined,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null) return;
    setState(() => renewal ? _renewal = d : _joined = d);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_renewal != null && _renewal!.isBefore(_joined)) {
      toast(context, 'Renewal date must be after the joining date', error: true);
      return;
    }
    setState(() => _busy = true);
    final api = context.read<PartnerSession>().api;
    final input = MemberInput(
      name: _name.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      joinedOn: _joined,
      planLabel: _plan.text.trim(),
      renewalOn: _renewal,
      source: _source,
      pricePaise: rupeesToPaise(_price.text) ?? 0,
      remindMember: _remind,
    );
    try {
      if (widget.member?.id == null) {
        await api.addVenueMember(widget.venueId, input);
      } else {
        await api.updateVenueMember(widget.venueId, widget.member!.id!, input);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text('${widget.member!.name} will be removed from your register.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.deleteVenueMember(widget.venueId, widget.member!.id!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final perDay = earningPerDayPaise(rupeesToPaise(_price.text) ?? 0, _joined, _renewal);
    Widget dateField(String label, DateTime? v, bool renewal) => Expanded(
      child: Tap(
        onTap: () => _pick(renewal: renewal),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_today_rounded, size: 18)),
          child: Text(v == null ? 'Not set' : formatDate(v), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.member == null ? 'Add member' : 'Edit member',
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (widget.member != null)
                    IconButton(
                      tooltip: 'Remove',
                      onPressed: _busy ? null : _delete,
                      icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the member\'s name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                decoration: const InputDecoration(labelText: 'Phone (optional)', prefixText: '+91 '),
                validator: (v) => (v ?? '').isNotEmpty && v!.length != 10 ? 'Enter a 10-digit mobile number' : null,
              ),
              const SizedBox(height: 16),
              const Text('Source', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in MemberSource.manual)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: _source == s,
                      onSelected: (_) => setState(() => _source = s),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'FitKey pass and FitKey direct-plan members are added automatically.',
                style: TextStyle(color: AppColors.text3, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _plan,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Plan', hintText: 'e.g. Monthly, Quarterly'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the plan' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  dateField('Date of joining', _joined, false),
                  const SizedBox(width: 12),
                  dateField('Renewal date', _renewal, true),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Price paid',
                  prefixText: '₹ ',
                  helperText: perDay > 0 ? 'Earning per day: ${formatPaise(perDay)}' : null,
                ),
                onChanged: (_) => setState(() {}),
                validator: (v) => (v ?? '').trim().isNotEmpty && rupeesToPaise(v!) == null ? 'Enter an amount' : null,
              ),
              const SizedBox(height: 14),
              const NoteStrip(
                text: 'We\'ll remind you 7 days and 1 day before the renewal date.',
                icon: Icons.notifications_active_rounded,
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _remind,
                onChanged: (v) => setState(() => _remind = v),
                title: const Text('Also remind the member on WhatsApp', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Needs their phone number'),
              ),
              const SizedBox(height: 8),
              AppButton(label: widget.member == null ? 'Add member' : 'Save changes', busy: _busy, onPressed: _save),
            ],
          ),
        ),
      ),
    );
  }
}
