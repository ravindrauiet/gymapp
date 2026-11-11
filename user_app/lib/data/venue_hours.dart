// Opening hours, FitKey-pass blocks and closures of a centre (Partner BRD §B / §G). Pure Dart — unit tested.

const weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const weekdayShort = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'};

/// 'mon' … 'sun' for a date.
String weekdayOf(DateTime d) => weekdayKeys[d.weekday - 1];

/// "HH:MM" or "HH:MM:SS" → minutes after midnight ("24:00" = 1440). Null when unparsable.
int? hhmmToMinutes(String? t) {
  if (t == null || t.length < 4) return null;
  final p = t.split(':');
  if (p.length < 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// "YYYY-MM-DD" for a local date.
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 6:00 → "6 AM", 18:30 → "6:30 PM", 0:00 / 24:00 → "12 AM".
String compactTime(String hhmm) {
  final c = _compact(hhmmToMinutes(hhmm) ?? 0);
  return '${c.$1}${c.$2}';
}

(String, String) _compact(int mins) {
  final h24 = (mins ~/ 60) % 24, m = mins % 60;
  final suffix = h24 >= 12 ? ' PM' : ' AM';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return (m == 0 ? '$h12' : '$h12:${m.toString().padLeft(2, '0')}', suffix);
}

/// "6–8 PM", "6 AM – 12 PM", "5:30–9 AM". Uses an en dash like the server's pass-block labels.
String timeRangeLabel(String from, String to) {
  final a = _compact(hhmmToMinutes(from) ?? 0), b = _compact(hhmmToMinutes(to) ?? 0);
  return a.$2 == b.$2 ? '${a.$1}–${b.$1}${b.$2}' : '${a.$1}${a.$2} – ${b.$1}${b.$2}';
}

/// ['mon'..'fri'] → "Mon–Fri"; all 7 → "Every day"; ['sat','sun'] → "Sat–Sun"; gaps → "Mon, Wed, Fri".
String dayRangeLabel(List<String> days) {
  final idx = days.map(weekdayKeys.indexOf).where((i) => i >= 0).toSet().toList()..sort();
  if (idx.isEmpty) return '';
  if (idx.length == 7) return 'Every day';
  final runs = <List<int>>[];
  for (final i in idx) {
    if (runs.isNotEmpty && runs.last.last == i - 1) {
      runs.last.add(i);
    } else {
      runs.add([i]);
    }
  }
  return runs.map((r) {
    final a = weekdayShort[weekdayKeys[r.first]]!, b = weekdayShort[weekdayKeys[r.last]]!;
    if (r.length == 1) return a;
    if (r.length == 2) return '$a, $b';
    return '$a–$b';
  }).join(', ');
}

class OpeningHour {
  const OpeningHour({required this.weekday, required this.opensAt, required this.closesAt, this.kind = 'open'});

  OpeningHour.fromJson(Map<String, dynamic> j)
      : weekday = (j['weekday'] as String? ?? '').toLowerCase(),
        opensAt = j['opensAt'] as String? ?? '00:00',
        closesAt = j['closesAt'] as String? ?? '00:00',
        kind = j['kind'] as String? ?? 'open';

  final String weekday;
  final String opensAt;
  final String closesAt;

  /// open | ladies_only
  final String kind;

  bool get ladiesOnly => kind == 'ladies_only';
  int get _o => hhmmToMinutes(opensAt) ?? 0;
  int get _c {
    final c = hhmmToMinutes(closesAt) ?? 0;
    return c == 0 ? 1440 : c; // "00:00" close = midnight
  }

  bool get overnight => _c <= _o;
  String get label => timeRangeLabel(opensAt, closesAt);
}

class PassBlock {
  const PassBlock({required this.days, required this.startsAt, required this.endsAt, this.note});

  PassBlock.fromJson(Map<String, dynamic> j)
      : days = List<String>.from((j['days'] as List?) ?? weekdayKeys),
        startsAt = j['startsAt'] as String? ?? '00:00',
        endsAt = j['endsAt'] as String? ?? '00:00',
        note = j['note'] as String?;

  final List<String> days;
  final String startsAt;
  final String endsAt;
  final String? note;

  /// "FitKey pass not valid 6–8 PM (Mon–Fri)" — same wording as the server's `passBlockLabels`.
  String get label {
    final d = dayRangeLabel(days);
    return 'FitKey pass not valid ${timeRangeLabel(startsAt, endsAt)}${d.isEmpty || d == 'Every day' ? '' : ' ($d)'}';
  }

  bool covers(DateTime at) {
    if (!days.contains(weekdayOf(at))) return false;
    final n = at.hour * 60 + at.minute;
    return n >= (hhmmToMinutes(startsAt) ?? 0) && n < (hhmmToMinutes(endsAt) ?? 0);
  }
}

class VenueClosure {
  const VenueClosure({required this.closedOn, this.slotStart, this.slotEnd, this.note});

  VenueClosure.fromJson(Map<String, dynamic> j)
      : closedOn = (j['closedOn'] as String? ?? '').length >= 10 ? (j['closedOn'] as String).substring(0, 10) : '',
        slotStart = j['slotStart'] as String?,
        slotEnd = j['slotEnd'] as String?,
        note = j['note'] as String?;

  /// YYYY-MM-DD
  final String closedOn;
  final String? slotStart;
  final String? slotEnd;
  final String? note;

  bool get fullDay => slotStart == null || slotEnd == null;

  bool covers(DateTime at) {
    if (closedOn != ymd(at)) return false;
    if (fullDay) return true;
    final n = at.hour * 60 + at.minute;
    return n >= (hhmmToMinutes(slotStart) ?? 0) && n < (hhmmToMinutes(slotEnd) ?? 0);
  }
}

/// Opening windows for one weekday, earliest first.
List<OpeningHour> hoursOn(List<OpeningHour> hours, String weekday) =>
    hours.where((h) => h.weekday == weekday).toList()..sort((a, b) => a._o.compareTo(b._o));

/// The opening window the venue is in at [at] (split shifts, ladies-only windows and windows past midnight
/// included), or null when it is shut. Closures (holidays / blocked slots) win over the weekly hours.
OpeningHour? openWindowAt(List<OpeningHour> hours, DateTime at, {List<VenueClosure> closures = const []}) {
  if (closures.any((c) => c.covers(at))) return null;
  final n = at.hour * 60 + at.minute;
  for (final h in hoursOn(hours, weekdayOf(at))) {
    if (h.overnight ? n >= h._o : (n >= h._o && n < h._c)) return h;
  }
  // A window that started yesterday and runs past midnight.
  final yesterday = weekdayOf(at.subtract(const Duration(days: 1)));
  for (final h in hoursOn(hours, yesterday)) {
    if (h.overnight && n < h._c) return h;
  }
  return null;
}

/// "Closes 10 PM" while open, "Opens 5 PM" / "Opens Mon 6 AM" while closed; null when there are no hours.
String? nextChangeLabel(List<OpeningHour> hours, DateTime at, {List<VenueClosure> closures = const []}) {
  if (hours.isEmpty) return null;
  final w = openWindowAt(hours, at, closures: closures);
  if (w != null) return 'Closes ${compactTime(w.closesAt)}';
  final n = at.hour * 60 + at.minute;
  for (var i = 0; i < 8; i++) {
    final day = DateTime(at.year, at.month, at.day + i);
    if (closures.any((c) => c.fullDay && c.closedOn == ymd(day))) continue;
    for (final h in hoursOn(hours, weekdayOf(day))) {
      if (i == 0 && h._o <= n) continue;
      final when = i == 0 ? '' : i == 1 ? 'tomorrow ' : '${weekdayShort[weekdayOf(day)]} ';
      return 'Opens $when${compactTime(h.opensAt)}';
    }
  }
  return null;
}

/// Everything the member venue page shows about timings & FitKey access (fields added by the Partner BRD).
class VenueTimings {
  const VenueTimings({
    this.sports = const [],
    this.videoUrl,
    this.slotMinutes,
    this.hours = const [],
    this.passBlocks = const [],
    this.passBlockLabels = const [],
    this.closures = const [],
    this.ladiesOnlyLabels = const [],
  });

  factory VenueTimings.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(Object? v) =>
        v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : const [];
    List<String> strings(Object? v) => v is List ? v.map((e) => '$e').toList() : const [];
    final blocks = maps(j['passBlocks']).map(PassBlock.fromJson).toList();
    final labels = strings(j['passBlockLabels']);
    final video = j['videoUrl'] as String?;
    return VenueTimings(
      sports: strings(j['sports']),
      videoUrl: video == null || video.trim().isEmpty ? null : video.trim(),
      slotMinutes: (j['slotMinutes'] as num?)?.toInt(),
      hours: maps(j['hours']).map(OpeningHour.fromJson).toList(),
      passBlocks: blocks,
      passBlockLabels: labels.isNotEmpty ? labels : blocks.map((b) => b.label).toList(),
      closures: maps(j['closures']).map(VenueClosure.fromJson).where((c) => c.closedOn.isNotEmpty).toList()
        ..sort((a, b) => a.closedOn.compareTo(b.closedOn)),
      ladiesOnlyLabels: strings(j['ladiesOnlyLabels']),
    );
  }

  final List<String> sports;
  final String? videoUrl;
  final int? slotMinutes;
  final List<OpeningHour> hours;
  final List<PassBlock> passBlocks;
  final List<String> passBlockLabels;
  final List<VenueClosure> closures;
  final List<String> ladiesOnlyLabels;

  bool get hasHours => hours.isNotEmpty;
  bool get hasLadiesOnly => hours.any((h) => h.ladiesOnly) || ladiesOnlyLabels.isNotEmpty;
}

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

String sportLabel(String s) =>
    sportLabels[s] ?? (s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' '));
