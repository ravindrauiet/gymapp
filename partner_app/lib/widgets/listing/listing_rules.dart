// Pure listing rules for the 10-step venue wizard (Partner BRD §3, §4): opening hours / split shifts / ladies-only
// windows, FitKey-pass blocks, category-aware equipment suggestions and payout preview strings.
// No Flutter imports: everything here is unit-tested in test/listing_rules_test.dart.

import 'package:fitkey_core/fitkey_core.dart' show formatPaise;

import '../../data/brd_api.dart' show CommissionPlan;
import '../../data/models.dart';

const weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const weekdayShort = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'};
const weekdayLong = {
  'mon': 'Monday',
  'tue': 'Tuesday',
  'wed': 'Wednesday',
  'thu': 'Thursday',
  'fri': 'Friday',
  'sat': 'Saturday',
  'sun': 'Sunday',
};

/// Sports a sports club can offer (contract enum), with labels.
const sportLabels = {
  'badminton': 'Badminton',
  'table_tennis': 'Table tennis',
  'cricket': 'Cricket',
  'football': 'Football',
  'basketball': 'Basketball',
  'tennis': 'Tennis',
  'squash': 'Squash',
  'skating': 'Skating',
  'swimming': 'Swimming',
};

/// What one "court" is called per sport (step 8: "3 badminton courts × 1 hr").
const sportUnit = {
  'badminton': ('court', 'courts'),
  'table_tennis': ('table', 'tables'),
  'cricket': ('net / pitch', 'nets / pitches'),
  'football': ('turf', 'turfs'),
  'basketball': ('court', 'courts'),
  'tennis': ('court', 'courts'),
  'squash': ('court', 'courts'),
  'skating': ('rink', 'rinks'),
  'swimming': ('lane', 'lanes'),
};

/// Slot lengths offered in step 8.
const slotLengths = [30, 45, 60, 90, 120];

// ---------------------------------------------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------------------------------------------

/// "06:30" → minutes after midnight. Returns -1 for malformed input.
int toMinutes(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm);
  if (m == null) return -1;
  return int.parse(m[1]!) * 60 + int.parse(m[2]!);
}

String fromMinutes(int minutes) {
  final m = minutes.clamp(0, 24 * 60 - 1);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// "18:00" → "6 PM", "06:30" → "6:30 AM".
String prettyTime(String hhmm) {
  final mins = toMinutes(hhmm);
  if (mins < 0) return hhmm;
  final h = mins ~/ 60, m = mins % 60;
  final suffix = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return m == 0 ? '$h12 $suffix' : '$h12:${m.toString().padLeft(2, '0')} $suffix';
}

String prettyRange(String start, String end) => '${prettyTime(start)} – ${prettyTime(end)}';

/// "Mon–Fri", "All days", "Mon, Wed, Sat", "Weekends".
String prettyDays(Iterable<String> days) {
  final set = days.toSet();
  final sorted = weekdays.where(set.contains).toList();
  if (sorted.isEmpty) return 'No days';
  if (sorted.length == 7) return 'All days';
  if (sorted.length == 2 && set.containsAll(['sat', 'sun'])) return 'Weekends';
  // One contiguous run of 3+ days → "Mon–Fri".
  final first = weekdays.indexOf(sorted.first), last = weekdays.indexOf(sorted.last);
  if (sorted.length >= 3 && last - first + 1 == sorted.length) {
    return '${weekdayShort[sorted.first]}–${weekdayShort[sorted.last]}';
  }
  return sorted.map((d) => weekdayShort[d]).join(', ');
}

/// A [start, end) time range on one day.
class Shift {
  Shift(this.start, this.end);
  String start;
  String end;

  Shift copy() => Shift(start, end);
  int get startMin => toMinutes(start);
  int get endMin => toMinutes(end);

  @override
  bool operator ==(Object other) => other is Shift && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => '$start-$end';
}

/// Time window on a set of weekdays (ladies-only hours).
class DayWindow {
  DayWindow({List<String>? days, this.start = '10:00', this.end = '12:00'}) : days = days ?? List.of(weekdays);
  List<String> days;
  String start;
  String end;

  DayWindow copy() => DayWindow(days: List.of(days), start: start, end: end);
}

/// Editable weekly schedule: open shifts per weekday (empty = closed) + ladies-only windows.
class WeekSchedule {
  WeekSchedule({Map<String, List<Shift>>? open, List<DayWindow>? ladies})
      : open = open ?? {for (final d in weekdays) d: <Shift>[]},
        ladies = ladies ?? [];

  final Map<String, List<Shift>> open;
  final List<DayWindow> ladies;

  /// Builds the schedule from a venue: its `hours` rows when present, else the legacy opensAt/closesAt/openDays.
  factory WeekSchedule.fromVenue(PartnerVenue v) {
    final open = {for (final d in weekdays) d: <Shift>[]};
    final ladiesRows = <VenueHour>[];
    final openRows = v.hours.where((h) => !h.ladiesOnly).toList();
    if (openRows.isEmpty) {
      for (final d in v.openDays) {
        if (open.containsKey(d)) open[d]!.add(Shift(v.opensAt, v.closesAt));
      }
    } else {
      for (final h in openRows) {
        open[h.weekday]?.add(Shift(h.opensAt, h.closesAt));
      }
    }
    for (final list in open.values) {
      list.sort((a, b) => a.startMin.compareTo(b.startMin));
    }
    ladiesRows.addAll(v.hours.where((h) => h.ladiesOnly));
    // Group ladies-only rows that share the same time range into one window.
    final windows = <String, DayWindow>{};
    for (final h in ladiesRows) {
      final key = '${h.opensAt}-${h.closesAt}';
      (windows[key] ??= DayWindow(days: [], start: h.opensAt, end: h.closesAt)).days.add(h.weekday);
    }
    return WeekSchedule(open: open, ladies: windows.values.toList());
  }

  List<String> get openDays => weekdays.where((d) => open[d]!.isNotEmpty).toList();

  /// True when every open day has exactly the same shifts.
  bool get sameEveryDay {
    final days = openDays;
    if (days.length <= 1) return true;
    final first = open[days.first]!;
    return days.every((d) => _sameShifts(open[d]!, first));
  }

  static bool _sameShifts(List<Shift> a, List<Shift> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Shifts of the first open day (the "same hours every day" template).
  List<Shift> get template {
    final d = openDays;
    return d.isEmpty ? [Shift('06:00', '22:00')] : open[d.first]!.map((s) => s.copy()).toList();
  }

  /// Applies [shifts] to every day in [days]; other days are closed.
  void applyToDays(Iterable<String> days, List<Shift> shifts) {
    final set = days.toSet();
    for (final d in weekdays) {
      open[d] = set.contains(d) ? shifts.map((s) => s.copy()).toList() : <Shift>[];
    }
  }

  /// Rows for the API (`hours`), open rows first.
  List<VenueHour> toHours() => [
        for (final d in weekdays)
          for (final s in open[d]!) VenueHour(weekday: d, opensAt: s.start, closesAt: s.end),
        for (final w in ladies)
          for (final d in weekdays.where(w.days.contains))
            VenueHour(weekday: d, opensAt: w.start, closesAt: w.end, kind: 'ladies_only'),
      ];

  /// Earliest opening / latest closing across the week (legacy opensAt / closesAt fields).
  ({String opensAt, String closesAt}) get envelope {
    final all = open.values.expand((s) => s).toList();
    if (all.isEmpty) return (opensAt: '06:00', closesAt: '22:00');
    final start = all.map((s) => s.startMin).reduce((a, b) => a < b ? a : b);
    final end = all.map((s) => s.endMin).reduce((a, b) => a > b ? a : b);
    return (opensAt: fromMinutes(start), closesAt: fromMinutes(end));
  }

  /// Writes the schedule back to the venue (hours rows + legacy fields).
  void writeTo(PartnerVenue v) {
    v.hours = toHours();
    v.openDays = openDays;
    final e = envelope;
    v.opensAt = e.opensAt;
    v.closesAt = e.closesAt;
  }

  WeekSchedule copy() => WeekSchedule(
        open: {for (final e in open.entries) e.key: e.value.map((s) => s.copy()).toList()},
        ladies: ladies.map((w) => w.copy()).toList(),
      );
}

/// Validates one day's shifts: each closes after it opens, and shifts don't overlap.
String? validateShifts(List<Shift> shifts, {String day = ''}) {
  final on = day.isEmpty ? '' : ' on ${weekdayLong[day] ?? day}';
  final sorted = [...shifts]..sort((a, b) => a.startMin.compareTo(b.startMin));
  for (final s in sorted) {
    if (s.startMin < 0 || s.endMin < 0) return 'Pick valid times$on';
    if (s.endMin <= s.startMin) return 'Closing time must be after opening time$on';
  }
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].startMin < sorted[i - 1].endMin) return 'Shifts overlap$on — the 2nd shift must start after the 1st ends';
  }
  return null;
}

/// Validates the whole schedule (step 4 hours part). Returns the first problem or null.
String? validateSchedule(WeekSchedule s) {
  if (s.openDays.isEmpty) return 'Select the days you are open';
  for (final d in weekdays) {
    final e = validateShifts(s.open[d]!, day: d);
    if (e != null) return e;
  }
  for (final w in s.ladies) {
    if (w.days.isEmpty) return 'Pick the days for ladies-only hours';
    if (toMinutes(w.end) <= toMinutes(w.start)) return 'Ladies-only hours must end after they start';
    for (final d in w.days) {
      final shifts = s.open[d]!;
      final inside = shifts.any((sh) => sh.startMin <= toMinutes(w.start) && toMinutes(w.end) <= sh.endMin);
      if (!inside) {
        return 'Ladies-only ${prettyRange(w.start, w.end)} on ${weekdayLong[d]} is outside your open hours';
      }
    }
  }
  return null;
}

/// Validates FitKey-pass access (step 4). [mode] is `all` | `blocked`.
String? validatePassBlocks(String mode, List<PassBlock> blocks) {
  if (mode != 'blocked') return null;
  if (blocks.isEmpty) return 'Add at least one time when FitKey pass users are blocked';
  for (final b in blocks) {
    if (b.days.isEmpty) return 'Pick the days for each blocked time';
    if (toMinutes(b.endsAt) <= toMinutes(b.startsAt)) return 'A blocked time must end after it starts';
  }
  return null;
}

/// Member-facing label for a pass block: "FitKey pass not valid 6 PM – 8 PM (Mon–Fri)".
String passBlockLabel(PassBlock b) => 'FitKey pass not valid ${prettyRange(b.startsAt, b.endsAt)} (${prettyDays(b.days)})';

/// One-line summary of a schedule for the review step.
String scheduleSummary(WeekSchedule s) {
  final days = s.openDays;
  if (days.isEmpty) return 'Closed all week';
  if (s.sameEveryDay) {
    return '${prettyDays(days)} · ${s.open[days.first]!.map((x) => prettyRange(x.start, x.end)).join(', ')}';
  }
  return '${prettyDays(days)} · different hours per day';
}

// ---------------------------------------------------------------------------------------------------------------
// Description, categories, equipment
// ---------------------------------------------------------------------------------------------------------------

const minDescriptionLength = 40;
const minPhotosToSubmit = 4;
const maxPhotos = 10;

/// Equipment quick-add per venue category. The BRD bug: a gym listing must not suggest "Badminton courts".
const _equipmentByCategory = <String, List<String>>{
  'gym': [
    'Treadmills',
    'Dumbbells',
    'Squat racks',
    'Bench press',
    'Cable machines',
    'Leg press',
    'Smith machine',
    'Spin bikes',
    'Rowing machines',
    'Cross trainers',
    'Kettlebells',
    'Battle ropes',
  ],
  'yoga_studio': ['Yoga mats', 'Yoga blocks', 'Straps', 'Bolsters', 'Meditation cushions', 'Aerial yoga hammocks'],
  'mma': ['Punching bags', 'Boxing ring', 'MMA cage', 'Gloves', 'Mats', 'Speed bags', 'Pads & mitts'],
  'martial_arts': ['Mats', 'Punching bags', 'Kick shields', 'Wooden dummy', 'Training weapons'],
  'dance': ['Sprung floor', 'Wall mirrors', 'Sound system', 'Ballet barre'],
  'swimming_pool': ['Swimming lanes', 'Kickboards', 'Pull buoys', 'Lane ropes', 'Lifeguard on duty', 'Kids\' pool'],
  'sports_club': [],
};

const _equipmentBySport = <String, List<String>>{
  'badminton': ['Badminton courts', 'Rackets on rent', 'Shuttlecocks', 'Wooden flooring'],
  'table_tennis': ['TT tables', 'Paddles on rent', 'Balls'],
  'cricket': ['Cricket nets', 'Bowling machine', 'Turf pitch', 'Bats & pads on rent'],
  'football': ['Football turf', 'Floodlights', 'Footballs', 'Bibs'],
  'basketball': ['Basketball court', 'Basketballs', 'Floodlights'],
  'tennis': ['Tennis courts', 'Rackets on rent', 'Ball machine', 'Floodlights'],
  'squash': ['Squash courts', 'Rackets on rent', 'Glass back wall'],
  'skating': ['Skating rink', 'Skates on rent', 'Helmets & pads'],
  'swimming': ['Swimming lanes', 'Kickboards', 'Lifeguard on duty'],
};

/// Quick-add equipment for the selected categories (and sports, when Sports Club is selected), without duplicates.
List<String> equipmentSuggestions(List<String> categories, List<String> sports) {
  final out = <String>[];
  void add(Iterable<String> items) {
    for (final i in items) {
      if (!out.contains(i)) out.add(i);
    }
  }

  for (final c in categories) {
    add(_equipmentByCategory[c] ?? const []);
  }
  if (categories.contains('sports_club')) {
    for (final s in sports) {
      add(_equipmentBySport[s] ?? const []);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Pricing & payouts (maths lives in CommissionPlan — same as backend utils/commission.js)
// ---------------------------------------------------------------------------------------------------------------

/// Venue plan durations offered in step 7, in display order (contract: hourly | day | weekly | monthly | quarterly | yearly).
const venuePlanDurations = <String, String>{
  'hourly': 'Hourly',
  'day': 'Day pass',
  'weekly': 'Weekly',
  'monthly': 'Monthly',
  'quarterly': 'Quarterly',
  'yearly': 'Yearly',
};

/// Normalises the legacy `annual` duration to `yearly`.
String canonicalDuration(String d) => d == 'annual' ? 'yearly' : d;

/// "₹50 per check-in in Year 1".
String passPreviewLine(int monthlyFeePaise, int year) {
  final net = CommissionPlan.passVisitNetPaise(monthlyFeePaise, year: year);
  final label = year >= 3 ? 'Year 3 onwards' : 'Year $year';
  return '${formatPaise(net)} per check-in in $label';
}

/// Breakdown of a direct plan sale for the live preview under each price.
({int gst, int commission, int net}) directSaleBreakdown(int pricePaise, {int year = 1}) {
  final gst = CommissionPlan.gstPartPaise(pricePaise);
  final net = CommissionPlan.directSaleNetPaise(pricePaise, year: year);
  return (gst: gst, commission: pricePaise - gst - net, net: net);
}

/// "You get ₹952 (₹48 GST deducted, 0% commission in Year 1)".
String directSaleLine(int pricePaise, {int year = 1}) {
  final b = directSaleBreakdown(pricePaise, year: year);
  final pct = CommissionPlan.pctForYear(year);
  final pctLabel = pct == pct.roundToDouble() ? '${pct.toInt()}%' : '$pct%';
  final yearLabel = year >= 3 ? 'from Year 3' : 'in Year $year';
  return 'You get ${formatPaise(b.net)} · ${formatPaise(b.gst)} GST + $pctLabel commission $yearLabel';
}

/// Parses a rupee amount typed by the partner ("1,499" / "1499.50") into paise. Null when empty / invalid.
int? rupeesToPaise(String text) {
  final t = text.replaceAll(',', '').replaceAll('₹', '').trim();
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

String paiseToRupeesText(int? paise) {
  if (paise == null) return '';
  return paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);
}

/// Step 8 courts line, e.g. "3 badminton courts × 1 hr".
String courtsLine(int courts, String? sport, int slotMinutes) {
  final unit = sportUnit[sport] ?? ('court', 'courts');
  final name = sport == null ? '' : '${(sportLabels[sport] ?? sport).toLowerCase()} ';
  final dur = slotMinutes % 60 == 0 ? '${slotMinutes ~/ 60} hr' : (slotMinutes > 60 ? '${slotMinutes / 60} hr' : '$slotMinutes min');
  return '$courts $name${courts == 1 ? unit.$1 : unit.$2} × $dur';
}
