// Progress revamp (BRD §4): goal-based report, habit goals, editable targets, water and step back-fill.
import 'fitkey_api.dart';
import 'models.dart';

int _i(dynamic v) => v == null ? 0 : (v as num).toInt();
double _d(dynamic v) => v == null ? 0 : (v as num).toDouble();

/// A goal ring on the Overview tab: actual vs target, marked ahead / on_track / behind / no_data.
class GoalRing {
  GoalRing.fromJson(Json j)
      : key = j['key'],
        label = j['label'],
        value = _d(j['value']),
        target = _d(j['target']),
        unit = j['unit'] ?? '',
        status = j['status'] ?? 'no_data',
        progress = _d(j['progress']);

  final String key; // workout_days | steps | calories | protein
  final String label;
  final double value;
  final double target;
  final String unit;
  final String status;
  final double progress;

  bool get hasData => status != 'no_data';
}

class ProgressGoals {
  ProgressGoals.fromJson(Json j)
      : hasGoal = j['hasGoal'] == true,
        goalType = j['goalType'] ?? 'maintenance',
        workoutDaysPerWeek = _i(j['workoutDaysPerWeek']),
        dailyStepsTarget = _i(j['dailyStepsTarget']),
        waterGlassesTarget = _i(j['waterGlassesTarget']),
        calories = _i(j['calories']),
        proteinG = _i(j['proteinG']),
        carbsG = _i(j['carbsG']),
        fatG = _i(j['fatG']),
        targetsSource = j['targetsSource'] ?? 'default',
        targetWeightKg = (j['targetWeightKg'] as num?)?.toDouble();

  final bool hasGoal;
  final String goalType;
  final int workoutDaysPerWeek;
  final int dailyStepsTarget;
  final int waterGlassesTarget;
  final int calories;
  final int proteinG;
  final int carbsG;
  final int fatG;
  final String targetsSource;
  final double? targetWeightKg;
}

class DayMovement {
  DayMovement.fromJson(Json j)
      : date = DateTime.parse(j['date']),
        steps = _i(j['steps']),
        distanceKm = _d(j['distanceKm']),
        activeCalories = _i(j['activeCalories']),
        source = j['source'],
        measured = j['measured'] == true;

  final DateTime date;
  final int steps;
  final double distanceKm;
  final int activeCalories;
  final String? source;
  final bool measured;
}

class DayNutrition {
  DayNutrition.fromJson(Json j)
      : date = DateTime.parse(j['date']),
        calories = _i(j['calories']),
        proteinG = _d(j['proteinG']),
        carbsG = _d(j['carbsG']),
        fatG = _d(j['fatG']),
        meals = _i(j['meals']);

  final DateTime date;
  final int calories;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final int meals;
}

class CaloriesBurned {
  CaloriesBurned.fromJson(Json j)
      : total = _i(j['total']),
        avgPerDay = _i(j['avgPerDay']),
        fromActivities = _i(j['fromActivities']),
        fromGymVisits = _i(j['fromGymVisits']),
        fromSteps = _i(j['fromSteps']),
        fromDevice = _i(j['fromDevice']),
        measuredDays = _i(j['measuredDays']),
        weightKgUsed = _d(j['weightKgUsed']),
        weightSource = j['weightSource'] ?? 'default';

  final int total;
  final int avgPerDay;
  final int fromActivities;
  final int fromGymVisits;
  final int fromSteps;
  final int fromDevice;
  final int measuredDays;
  final double weightKgUsed;
  final String weightSource;
}

class WaterSummary {
  WaterSummary.fromJson(Json j)
      : target = _i(j['target']),
        today = _i(j['today']),
        avgGlasses = _d(j['avgGlasses']),
        loggedDays = _i(j['loggedDays']),
        daysHit = _i(j['daysHit']),
        series = [
          for (final w in (j['series'] as List? ?? const [])) (date: DateTime.parse(w['date']), glasses: _i(w['glasses'])),
        ];

  final int target;
  final int today;
  final double avgGlasses;
  final int loggedDays;
  final int daysHit;
  final List<({DateTime date, int glasses})> series;
}

/// Full `/health/report` payload: the classic [HealthReport] plus the goal-based additions.
class ProgressReport {
  ProgressReport.fromJson(Json j)
      : base = HealthReport.fromJson(j),
        defaultTab = j['defaultTab'] ?? 'overview',
        goals = ProgressGoals.fromJson(j['goals'] ?? const {}),
        score = (j['overview']?['score'] as num?)?.toInt(),
        insight = j['overview']?['insight'] ?? '',
        workoutDays = _i(j['overview']?['workoutDays']),
        rings = [for (final r in (j['overview']?['rings'] as List? ?? const [])) GoalRing.fromJson(r)],
        movementSeries = [for (final m in (j['movement']?['series'] as List? ?? const [])) DayMovement.fromJson(m)],
        stepLoggedDays = _i(j['movement']?['loggedDays']),
        lastDeviceSource = j['movement']?['lastDeviceSync']?['source'],
        burned = CaloriesBurned.fromJson(j['caloriesBurned'] ?? const {}),
        estimatedActivities = _i(j['workouts']?['estimatedCount']),
        lastActivity = j['workouts']?['last'] == null ? null : Activity.fromJson(j['workouts']['last']),
        nutritionSeries = [for (final n in (j['nutrition']?['series'] as List? ?? const [])) DayNutrition.fromJson(n)],
        daysOnCalorieTarget = _i(j['nutrition']?['daysOnCalorieTarget']),
        daysHitProtein = _i(j['nutrition']?['daysHitProtein']),
        breakfastDays = _i(j['nutrition']?['breakfastDays']),
        avgMealsPerDay = _d(j['nutrition']?['avgMealsPerDay']),
        water = WaterSummary.fromJson(j['water'] ?? const {}),
        bmi = (j['bmi']?['value'] as num?)?.toDouble(),
        bmiCategory = j['bmi']?['category'],
        targetWeightKg = (j['weight']?['targetKg'] as num?)?.toDouble();

  final HealthReport base;
  final String defaultTab; // overview | workout | nutrition
  final ProgressGoals goals;
  final int? score;
  final String insight;
  final int workoutDays;
  final List<GoalRing> rings;
  final List<DayMovement> movementSeries;
  final int stepLoggedDays;
  final String? lastDeviceSource;
  final CaloriesBurned burned;
  final int estimatedActivities;
  final Activity? lastActivity;
  final List<DayNutrition> nutritionSeries;
  final int daysOnCalorieTarget;
  final int daysHitProtein;
  final int breakfastDays;
  final double avgMealsPerDay;
  final WaterSummary water;
  final double? bmi;
  final String? bmiCategory;
  final double? targetWeightKg;

  int get days => base.days;
}

extension ProgressApi on FitkeyApi {
  Future<ProgressReport> progressReport({int days = 7}) async =>
      ProgressReport.fromJson(await client.get('/health/report', query: {'days': days}));

  /// Edits habit goals and/or nutrition target overrides. Pass `null` for a target to reset it to auto.
  Future<UserGoal> updateGoal(Json fields) async => UserGoal.fromJson((await client.patch('/goals', fields))['goal']);

  Future<({int glasses, int target})> water({String? date}) async {
    final w = (await client.get('/nutrition/water', query: {'date': date}))['water'];
    return (glasses: _i(w['glasses']), target: _i(w['target']));
  }

  /// Adds (+1) or removes (−1) glasses of water for [date] (default today).
  Future<({int glasses, int target})> addWater(int delta, {String? date}) async {
    final w = (await client.post('/nutrition/water', {'delta': delta, 'date': ?date}))['water'];
    return (glasses: _i(w['glasses']), target: _i(w['target']));
  }

  /// Logs the most recent activity again, right now (one-tap repeat).
  Future<Activity> repeatLastActivity() async =>
      Activity.fromJson((await client.post('/health/activities/repeat'))['activity']);

  Future<Activity?> lastActivity() async {
    final list = (await client.get('/health/activities', query: {'limit': 1}))['activities'] as List;
    return list.isEmpty ? null : Activity.fromJson(list.first);
  }

  /// Back-fills several days of steps from Health Connect / HealthKit.
  Future<int> syncStepDays(List<Json> days, {required String source}) async =>
      _i((await client.post('/health/steps/sync', {'source': source, 'days': days}))['synced']);

  /// Manual step entry (fallback / web) — server estimates distance and burn.
  Future<void> saveManualSteps(int steps) => client.post('/health/steps/sync', {'steps': steps, 'source': 'manual'});
}
