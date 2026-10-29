// Typed views over the FITKEY API's JSON (camelCase keys).

typedef Json = Map<String, dynamic>;

List<String> _strings(dynamic v) => (v as List? ?? const []).map((e) => e.toString()).toList();
double? _double(dynamic v) => v == null ? null : (v as num).toDouble();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();
DateTime _date(dynamic v) => DateTime.parse(v as String).toLocal();
DateTime? _dateOrNull(dynamic v) => v == null ? null : _date(v);

class User {
  User.fromJson(Json j)
      : id = j['id'],
        phone = j['phone'],
        email = j['email'],
        name = j['name'],
        city = j['city'],
        gender = j['gender'];

  final String id;
  final String phone;
  final String? email;
  final String? name;
  final String? city;
  final String? gender;

  String get firstName => (name ?? 'there').split(' ').first;
}

class ActiveSubscription {
  ActiveSubscription.fromJson(Json j)
      : id = j['id'],
        planId = j['planId'],
        planName = j['planName'],
        categories = _strings(j['categories']),
        startsAt = _date(j['startsAt']),
        endsAt = _date(j['endsAt']);

  final String id;
  final String planId;
  final String planName;
  final List<String> categories;
  final DateTime startsAt;
  final DateTime endsAt;

  int get daysLeft => endsAt.difference(DateTime.now()).inDays + 1;
}

class Plan {
  Plan.fromJson(Json j)
      : id = j['id'],
        code = j['code'],
        name = j['name'],
        description = j['description'],
        categories = _strings(j['categories']),
        pricePaise = _int(j['pricePaise']),
        durationDays = _int(j['durationDays']),
        features = _strings(j['features']),
        venueCount = _int(j['venueCount']);

  final String id;
  final String code;
  final String name;
  final String? description;
  final List<String> categories;
  final int pricePaise;
  final int durationDays;
  final List<String> features;
  final int venueCount;
}

class Subscription {
  Subscription.fromJson(Json j)
      : id = j['id'],
        planName = j['planName'],
        state = j['state'],
        startsAt = _date(j['startsAt']),
        endsAt = _date(j['endsAt']),
        amountPaise = _int(j['amountPaise']),
        categories = _strings(j['categories']);

  final String id;
  final String planName;
  final String state; // active | upcoming | expired | cancelled
  final DateTime startsAt;
  final DateTime endsAt;
  final int amountPaise;
  final List<String> categories;
}

class VenueSummary {
  VenueSummary.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        area = j['area'],
        city = j['city'],
        categories = _strings(j['categories']),
        opensAt = j['opensAt'],
        closesAt = j['closesAt'],
        trainerAvailable = j['trainerAvailable'] ?? false,
        amenities = _strings(j['amenities']),
        coverPhoto = j['coverPhoto'],
        distanceKm = _double(j['distanceKm']),
        ratingAvg = _double(j['ratingAvg']),
        ratingCount = (j['ratingCount'] as num?)?.toInt();

  final String id;
  final String name;
  final String? area;
  final String? city;
  final List<String> categories;
  final String? opensAt;
  final String? closesAt;
  final bool trainerAvailable;
  final List<String> amenities;
  final String? coverPhoto;
  final double? distanceKm;

  /// Average stars (1–5); null until rated. Shown as "New" until [ratingCount] ≥ 5.
  final double? ratingAvg;

  /// Null when the endpoint does not include ratings.
  final int? ratingCount;

  String get location => [area, city].whereType<String>().join(', ');
}

class Venue {
  Venue.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        description = j['description'],
        categories = _strings(j['categories']),
        address = j['address'],
        area = j['area'],
        city = j['city'],
        latitude = _double(j['latitude']),
        longitude = _double(j['longitude']),
        opensAt = j['opensAt'],
        closesAt = j['closesAt'],
        openDays = _strings(j['openDays']),
        contactPhone = j['contactPhone'],
        trainerAvailable = j['trainerAvailable'] ?? false,
        equipment = _strings(j['equipment']),
        amenities = _strings(j['amenities']),
        photos = _strings(j['photos']),
        ratingAvg = _double(j['ratingAvg']),
        ratingCount = (j['ratingCount'] as num?)?.toInt();

  final String id;
  final String name;
  final String? description;
  final List<String> categories;
  final String? address;
  final String? area;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? opensAt;
  final String? closesAt;
  final List<String> openDays;
  final String? contactPhone;
  final bool trainerAvailable;
  final List<String> equipment;
  final List<String> amenities;
  final List<String> photos;
  final double? ratingAvg;
  final int? ratingCount;
}

class PlanRef {
  PlanRef.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        pricePaise = _int(j['pricePaise']),
        durationDays = _int(j['durationDays']);

  final String id;
  final String name;
  final int pricePaise;
  final int durationDays;
}

class Checkin {
  Checkin.fromJson(Json j)
      : id = j['id'],
        checkedInAt = _date(j['checkedInAt']),
        method = j['method'],
        venueName = j['venueName'] ?? (j['venue']?['name'] as String?) ?? '',
        venueArea = j['venueArea'] ?? (j['venue']?['area'] as String?),
        planName = j['planName'];

  final String id;
  final DateTime checkedInAt;
  final String method;
  final String venueName;
  final String? venueArea;
  final String? planName;
}

class VideoCategoryCount {
  VideoCategoryCount.fromJson(Json j)
      : id = j['id'],
        label = j['label'],
        count = _int(j['count']);

  final String id;
  final String label;
  final int count;
}

class Video {
  Video.fromJson(Json j)
      : id = j['id'],
        category = j['category'],
        title = j['title'],
        description = j['description'],
        trainerName = j['trainerName'],
        level = j['level'] ?? 'beginner',
        videoUrl = j['videoUrl'],
        thumbnailUrl = j['thumbnailUrl'],
        durationSeconds = j['durationSeconds'],
        groupKey = j['groupKey'],
        groupLabel = j['groupLabel'],
        types = ((j['types'] as List?) ?? const []).cast<String>(),
        groups = ((j['groups'] as List?) ?? const []).cast<String>(),
        equipment = j['equipment'];

  final String id;
  final String category;
  final String title;
  final String? description;
  final String? trainerName;
  final String level;
  final String videoUrl;
  final String? thumbnailUrl;
  final int? durationSeconds;

  /// Studio group (BRD §7), e.g. 'gym', 'yoga_mind'; null from older servers.
  final String? groupKey;
  final String? groupLabel;

  /// Studio video type keys, e.g. ['gym_chest', 'body_upper'].
  final List<String> types;

  /// Every Studio group this video is listed in (its primary group + the groups of its types).
  final List<String> groups;

  /// none | dumbbells | gym (null when not tagged).
  final String? equipment;
}

class BuddyPost {
  BuddyPost.fromJson(Json j)
      : id = j['id'],
        venueId = j['venueId'],
        venueName = j['venueName'] ?? '',
        venueArea = j['venueArea'],
        slotDate = DateTime.parse(j['slotDate']),
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        note = j['note'],
        matchCount = _int(j['matchCount']);

  final String id;
  final String venueId;
  final String venueName;
  final String? venueArea;
  final DateTime slotDate;
  final String slotStart;
  final String slotEnd;
  final String? note;
  final int matchCount;
}

class BuddyMatch {
  BuddyMatch.fromJson(Json j)
      : postId = j['postId'],
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        note = j['note'],
        userId = j['userId'],
        name = j['name'],
        gender = j['gender'],
        requestId = j['requestId'],
        requestStatus = j['requestStatus'],
        requestDirection = j['requestDirection'];

  final String postId;
  final String slotStart;
  final String slotEnd;
  final String? note;
  final String userId;
  final String? name;
  final String? gender;
  final String? requestId;
  final String? requestStatus;
  final String? requestDirection;
}

class BuddyRequest {
  BuddyRequest.fromJson(Json j)
      : id = j['id'],
        status = j['status'],
        direction = j['direction'],
        otherUserId = j['otherUserId'],
        otherName = j['otherName'],
        venueName = j['venueName'] ?? '',
        slotDate = DateTime.parse(j['slotDate']),
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        lastMessage = j['lastMessage'];

  final String id;
  final String status; // pending | accepted
  final String direction; // incoming | outgoing
  final String otherUserId;
  final String? otherName;
  final String venueName;
  final DateTime slotDate;
  final String slotStart;
  final String slotEnd;
  final String? lastMessage;
}

class ChatMessage {
  ChatMessage.fromJson(Json j)
      : id = j['id'],
        body = j['body'],
        createdAt = _date(j['createdAt']),
        rawCreatedAt = j['createdAt'],
        isMine = j['isMine'] == true;

  final String id;
  final String body;
  final DateTime createdAt;
  final String rawCreatedAt;
  final bool isMine;
}

class Contest {
  Contest.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        description = j['description'],
        period = j['period'],
        metric = j['metric'],
        startsOn = DateTime.parse(j['startsOn']),
        endsOn = DateTime.parse(j['endsOn']),
        reward = j['reward'],
        city = j['city'],
        participantCount = _int(j['participantCount']),
        joined = j['joined'] == true,
        unit = j['unit'] ?? '';

  final String id;
  final String title;
  final String? description;
  final String period;
  final String metric;
  final DateTime startsOn;
  final DateTime endsOn;
  final String? reward;
  final String? city;
  final int participantCount;
  final bool joined;
  final String unit;

  int get daysLeft => endsOn.difference(DateTime.now()).inDays + 1;
}

class LeaderEntry {
  LeaderEntry.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        city = j['city'],
        score = _double(j['score']) ?? 0,
        rank = _int(j['rank']);

  final String userId;
  final String? name;
  final String? city;
  final double score;
  final int rank;
}

class Leaderboard {
  Leaderboard.fromJson(Json j)
      : entries = (j['entries'] as List).map((e) => LeaderEntry.fromJson(e)).toList(),
        me = j['me'] == null ? null : LeaderEntry.fromJson(j['me']);

  final List<LeaderEntry> entries;
  final LeaderEntry? me;
}

class Activity {
  Activity.fromJson(Json j)
      : id = j['id'],
        type = j['type'],
        title = j['title'],
        durationMin = j['durationMin'],
        distanceKm = _double(j['distanceKm']),
        calories = j['calories'],
        loggedAt = _date(j['loggedAt']);

  final String id;
  final String type;
  final String? title;
  final int? durationMin;
  final double? distanceKm;
  final int? calories;
  final DateTime loggedAt;
}

class WeightPoint {
  WeightPoint.fromJson(Json j)
      : weightKg = _double(j['weightKg'])!,
        loggedOn = DateTime.parse(j['loggedOn']);

  final double weightKg;
  final DateTime loggedOn;
}

class HealthReport {
  HealthReport.fromJson(Json j)
      : days = _int(j['days']),
        totalCheckins = _int(j['attendance']?['totalCheckins']),
        activeDays = _int(j['attendance']?['activeDays']),
        uniqueVenues = _int(j['attendance']?['uniqueVenues']),
        currentStreak = _int(j['attendance']?['currentStreak']),
        gymConsistencyScore = _int(j['attendance']?['gymConsistencyScore']),
        checkinsPerDay = {
          if (j['attendance']?['perDay'] is List)
            for (final d in j['attendance']['perDay'] as List) DateTime.parse(d['date']): _int(d['count']),
        },
        topVenues = [
          if (j['attendance']?['topVenues'] is List)
            for (final v in j['attendance']['topVenues'] as List) (name: v['name'] as String, visits: _int(v['visits'])),
        ],
        workoutCount = _int(j['workouts']?['count']),
        totalMinutes = _int(j['workouts']?['totalMinutes']),
        totalDistanceKm = _double(j['workouts']?['totalDistanceKm']) ?? 0,
        totalCalories = _int(j['workouts']?['totalCalories']),
        workoutsByType = [
          if (j['workouts']?['byType'] is List)
            for (final t in j['workouts']['byType'] as List)
              (type: t['type'] as String, count: _int(t['count']), minutes: _int(t['minutes'])),
        ],
        latestWeight = j['weight']?['latest'] == null ? null : WeightPoint.fromJson(j['weight']['latest']),
        weightChangeKg = _double(j['weight']?['changeKg']),
        weightSeries = (j['weight']?['series'] as List? ?? const []).map((w) => WeightPoint.fromJson(w)).toList(),
        movement = j['movement'] == null ? null : MovementReport.fromJson(j['movement']),
        nutrition = j['nutrition'] == null ? null : NutritionReport.fromJson(j['nutrition']),
        integrationRows = [
          if (j['integrationArchitecture'] is List)
            for (final r in j['integrationArchitecture'] as List)
              (source: r['source'] as String, metric: r['metric'] as String, outcome: r['outcome'] as String),
        ];

  final int days;
  final int totalCheckins;
  final int activeDays;
  final int uniqueVenues;
  final int currentStreak;
  final int gymConsistencyScore;
  final Map<DateTime, int> checkinsPerDay;
  final List<({String name, int visits})> topVenues;
  final int workoutCount;
  final int totalMinutes;
  final double totalDistanceKm;
  final int totalCalories;
  final List<({String type, int count, int minutes})> workoutsByType;
  final WeightPoint? latestWeight;
  final double? weightChangeKg;
  final List<WeightPoint> weightSeries;
  final MovementReport? movement;
  final NutritionReport? nutrition;
  final List<({String source, String metric, String outcome})> integrationRows;
}

class MovementReport {
  MovementReport.fromJson(Json j)
      : totalSteps = _int(j['totalSteps']),
        avgDailySteps = _int(j['avgDailySteps']),
        totalDistanceKm = _double(j['totalDistanceKm']) ?? 0.0,
        totalActiveBurn = _int(j['totalActiveBurn']),
        avgDailyActiveBurn = _int(j['avgDailyActiveBurn']),
        movementScore = _int(j['movementScore']);

  final int totalSteps;
  final int avgDailySteps;
  final double totalDistanceKm;
  final int totalActiveBurn;
  final int avgDailyActiveBurn;
  final int movementScore;
}

class NutritionReport {
  NutritionReport.fromJson(Json j)
      : avgDailyCalories = _int(j['avgDailyCalories']),
        avgDailyProtein = _double(j['avgDailyProtein']) ?? 0.0,
        avgDailyCarbs = _double(j['avgDailyCarbs']) ?? 0.0,
        avgDailyFat = _double(j['avgDailyFat']) ?? 0.0,
        deficitSurplusStatus = j['deficitSurplusStatus'] ?? 'Balanced',
        mealDays = _int(j['mealDays']),
        dailyCalorieBaseline = _int(j['baselines']?['dailyCalories']),
        dailyProteinBaseline = _int(j['baselines']?['dailyProteinG']),
        goalType = j['baselines']?['goalType'] ?? 'maintenance';

  final int avgDailyCalories;
  final double avgDailyProtein;
  final double avgDailyCarbs;
  final double avgDailyFat;
  final String deficitSurplusStatus;
  final int mealDays;
  final int dailyCalorieBaseline;
  final int dailyProteinBaseline;
  final String goalType;
}

// ---- Goal-Based Onboarding & User Profiling ----------------------------------
class UserGoal {
  UserGoal.fromJson(Json j)
      : goalType = j['goal_type'] ?? j['goalType'],
        age = _int(j['age']),
        gender = j['gender'],
        heightCm = _double(j['height_cm'] ?? j['heightCm']) ?? 170.0,
        currentWeightKg = _double(j['current_weight_kg'] ?? j['currentWeightKg']) ?? 70.0,
        targetWeightKg = _double(j['target_weight_kg'] ?? j['targetWeightKg']) ?? 65.0,
        activityLevel = j['activity_level'] ?? j['activityLevel'],
        dailyCalorieTarget = _int(j['daily_calorie_target'] ?? j['dailyCalorieTarget']),
        dailyProteinG = _int(j['daily_protein_g'] ?? j['dailyProteinG']),
        dailyCarbsG = _int(j['daily_carbs_g'] ?? j['dailyCarbsG']),
        dailyFatG = _int(j['daily_fat_g'] ?? j['dailyFatG']),
        workoutDaysPerWeek = j['workoutDaysPerWeek'] == null ? 4 : _int(j['workoutDaysPerWeek']),
        dailyStepsTarget = j['dailyStepsTarget'] == null ? 8000 : _int(j['dailyStepsTarget']),
        waterGlassesTarget = j['waterGlassesTarget'] == null ? 8 : _int(j['waterGlassesTarget']),
        calorieOverride = (j['calorieTargetOverride'] as num?)?.toInt(),
        proteinOverride = (j['proteinGOverride'] as num?)?.toInt(),
        carbsOverride = (j['carbsGOverride'] as num?)?.toInt(),
        fatOverride = (j['fatGOverride'] as num?)?.toInt(),
        customTargets = j['customTargets'] == true,
        autoCalorieTarget = _int(j['autoTargets']?['dailyCalorieTarget'] ?? j['daily_calorie_target'] ?? j['dailyCalorieTarget']),
        autoProteinG = _int(j['autoTargets']?['dailyProteinG'] ?? j['daily_protein_g'] ?? j['dailyProteinG']),
        autoCarbsG = _int(j['autoTargets']?['dailyCarbsG'] ?? j['daily_carbs_g'] ?? j['dailyCarbsG']),
        autoFatG = _int(j['autoTargets']?['dailyFatG'] ?? j['daily_fat_g'] ?? j['dailyFatG']);

  final String goalType; // weight_loss | muscle_gain | maintenance
  final int age;
  final String gender;
  final double heightCm;
  final double currentWeightKg;
  final double targetWeightKg;
  final String activityLevel; // sedentary | light | moderate | very_active
  final int dailyCalorieTarget;
  final int dailyProteinG;
  final int dailyCarbsG;
  final int dailyFatG;

  /// Habit goals (BRD §4): workout days per week, daily steps, glasses of water.
  final int workoutDaysPerWeek;
  final int dailyStepsTarget;
  final int waterGlassesTarget;

  /// Member overrides of the auto-calculated nutrition targets (null = auto).
  final int? calorieOverride;
  final int? proteinOverride;
  final int? carbsOverride;
  final int? fatOverride;
  final bool customTargets;

  /// Mifflin-St Jeor targets calculated from body stats (before overrides).
  final int autoCalorieTarget;
  final int autoProteinG;
  final int autoCarbsG;
  final int autoFatG;

  String get goalLabel => switch (goalType) {
        'weight_loss' => 'Weight Loss (Patla hona hai)',
        'muscle_gain' => 'Muscle / Weight Gain (Bulk / Mota hona hai)',
        _ => 'Maintenance (Jaisa hoon waisa rehna hai)',
      };
}

// ---- Marketplace / Store ----------------------------------------------------
class MarketplaceProduct {
  MarketplaceProduct.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        brand = j['brand'],
        category = j['category'],
        description = j['description'],
        pricePaise = _int(j['price_paise'] ?? j['pricePaise']),
        originalPricePaise = _int(j['original_price_paise'] ?? j['originalPricePaise']),
        stockQuantity = _int(j['stock_quantity'] ?? j['stockQuantity']),
        images = _strings(j['images']),
        specs = (j['specs'] is Map) ? Map<String, dynamic>.from(j['specs'] as Map) : {},
        vendorName = j['vendor_name'] ?? j['vendorName'];

  final String id;
  final String title;
  final String brand;
  final String category; // supplements | apparel | wearables | gear
  final String description;
  final int pricePaise;
  final int originalPricePaise;
  final int stockQuantity;
  final List<String> images;
  final Map<String, dynamic> specs;
  final String? vendorName;

  int get discountPercent =>
      originalPricePaise > pricePaise ? (((originalPricePaise - pricePaise) / originalPricePaise) * 100).round() : 0;
}

class MarketplaceOrderItem {
  MarketplaceOrderItem.fromJson(Json j)
      : id = j['id'],
        productId = j['productId'] ?? j['product_id'],
        title = j['title'],
        pricePaise = _int(j['pricePaise'] ?? j['price_paise']),
        quantity = _int(j['quantity']);

  final String? id;
  final String? productId;
  final String title;
  final int pricePaise;
  final int quantity;
}

class MarketplaceOrder {
  MarketplaceOrder.fromJson(Json j)
      : id = j['id'],
        status = j['status'],
        totalAmountPaise = _int(j['total_amount_paise'] ?? j['totalAmountPaise']),
        paymentMethod = j['payment_method'] ?? j['paymentMethod'],
        paymentStatus = j['payment_status'] ?? j['paymentStatus'],
        trackingNumber = j['tracking_number'] ?? j['trackingNumber'],
        createdAt = _date(j['created_at'] ?? j['createdAt']),
        shippingAddress = (j['shipping_address'] is Map)
            ? Map<String, dynamic>.from(j['shipping_address'] as Map)
            : {},
        items = (j['items'] as List? ?? const []).map((i) => MarketplaceOrderItem.fromJson(i)).toList();

  final String id;
  final String status;
  final int totalAmountPaise;
  final String paymentMethod;
  final String paymentStatus;
  final String? trackingNumber;
  final DateTime createdAt;
  final Map<String, dynamic> shippingAddress;
  final List<MarketplaceOrderItem> items;
}

// ---- Fuel Log (Nutrition & Meal Tracker) -------------------------------------
class FoodItem {
  FoodItem.fromJson(Json j)
      : id = j['id'] ?? '',
        name = j['name'] ?? 'Food',
        servingUnit = j['serving_unit'] ?? j['servingUnit'] ?? '1 serving',
        calories = _int(j['calories']),
        proteinG = _double(j['protein_g'] ?? j['proteinG']) ?? 0.0,
        carbsG = _double(j['carbs_g'] ?? j['carbsG']) ?? 0.0,
        fatG = _double(j['fat_g'] ?? j['fatG']) ?? 0.0,
        fibreG = _double(j['fibre_g'] ?? j['fibreG']) ?? 0.0,
        ironMg = _double(j['iron_mg'] ?? j['ironMg']) ?? 0.0,
        magnesiumMg = _double(j['magnesium_mg'] ?? j['magnesiumMg']) ?? 0.0,
        calciumMg = _double(j['calcium_mg'] ?? j['calciumMg']) ?? 0.0,
        sodiumMg = _double(j['sodium_mg'] ?? j['sodiumMg']) ?? 0.0,
        category = j['category'] ?? 'General',
        educationalNotes = j['educational_notes'] ?? j['educationalNotes'];

  final String id;
  final String name;
  final String servingUnit;
  final int calories;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final double fibreG;
  final double ironMg;
  final double magnesiumMg;
  final double calciumMg;
  final double sodiumMg;
  final String category;
  final String? educationalNotes;
}

class MealLog {
  MealLog.fromJson(Json j)
      : id = j['id'],
        mealType = j['meal_type'] ?? j['mealType'],
        foodId = j['food_id'] ?? j['foodId'],
        foodName = j['food_name'] ?? j['foodName'],
        servings = _double(j['servings']) ?? 1.0,
        calories = _int(j['calories']),
        proteinG = _double(j['protein_g'] ?? j['proteinG']) ?? 0.0,
        carbsG = _double(j['carbs_g'] ?? j['carbsG']) ?? 0.0,
        fatG = _double(j['fat_g'] ?? j['fatG']) ?? 0.0,
        loggedOn = j['logged_on'] ?? j['loggedOn'];

  final String id;
  final String mealType; // breakfast | lunch | dinner | snacks
  final String? foodId;
  final String foodName;
  final double servings;
  final int calories;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final String loggedOn;
}

class MealDailySummary {
  MealDailySummary.fromJson(Json j)
      : date = j['date'] ?? 'today',
        totalCalories = _int(j['summary']?['totalCalories']),
        totalProteinG = _double(j['summary']?['totalProteinG']) ?? 0.0,
        totalCarbsG = _double(j['summary']?['totalCarbsG']) ?? 0.0,
        totalFatG = _double(j['summary']?['totalFatG']) ?? 0.0,
        calorieBalance = j['summary']?['calorieBalance'] ?? '',
        calorieTarget = _int(j['summary']?['targets']?['calories']),
        proteinTarget = _int(j['summary']?['targets']?['proteinG']),
        carbsTarget = _int(j['summary']?['targets']?['carbsG']),
        fatTarget = _int(j['summary']?['targets']?['fatG']),
        nudges = _strings(j['nudges']),
        breakfast = (j['categories']?['breakfast'] as List? ?? const []).map((m) => MealLog.fromJson(m)).toList(),
        lunch = (j['categories']?['lunch'] as List? ?? const []).map((m) => MealLog.fromJson(m)).toList(),
        dinner = (j['categories']?['dinner'] as List? ?? const []).map((m) => MealLog.fromJson(m)).toList(),
        snacks = (j['categories']?['snacks'] as List? ?? const []).map((m) => MealLog.fromJson(m)).toList(),
        targetsSource = j['summary']?['targets']?['source'] ?? 'goal',
        waterGlasses = _int(j['water']?['glasses']),
        waterTarget = j['water']?['target'] == null ? 8 : _int(j['water']?['target']);

  final String date;
  final int totalCalories;
  final double totalProteinG;
  final double totalCarbsG;
  final double totalFatG;
  final String calorieBalance;
  final int calorieTarget;
  final int proteinTarget;
  final int carbsTarget;
  final int fatTarget;
  final List<String> nudges;
  final List<MealLog> breakfast;
  final List<MealLog> lunch;
  final List<MealLog> dinner;
  final List<MealLog> snacks;

  /// 'goal' (auto-calculated), 'custom' (member override) or 'default' (no goal set yet).
  final String targetsSource;
  final int waterGlasses;
  final int waterTarget;
}

// ---- FitPro On-Demand (Trainers) --------------------------------------------
class Trainer {
  Trainer.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        photoUrl = j['photo_url'] ?? j['photoUrl'],
        bio = j['bio'],
        rating = _double(j['ratingAvg'] ?? j['rating']),
        reviewCount = _int(j['ratingCount'] ?? j['review_count'] ?? j['reviewCount']),
        trainerTypes = _strings(j['trainerTypes']),
        trainerTypeLabels = _strings(j['trainerTypeLabels']),
        certifications = _strings(j['certifications']),
        specializations = _strings(j['specializations']),
        trainingModes = _strings(j['training_modes'] ?? j['trainingModes']),
        hourlyRatePaise = _int(j['hourly_rate_paise'] ?? j['hourlyRatePaise']),
        bufferMinutes = _int(j['buffer_minutes'] ?? j['bufferMinutes']);

  final String id;
  final String name;
  final String? photoUrl;
  final String bio;
  /// Real average stars from member ratings; null until rated. Shown as "New" until [reviewCount] ≥ 5.
  final double? rating;
  final int reviewCount;

  /// BRD §6 trainer type keys, e.g. personal_trainer, zumba, physiotherapist.
  final List<String> trainerTypes;

  /// Display labels for [trainerTypes], e.g. "Zumba", "Physiotherapist".
  final List<String> trainerTypeLabels;
  final List<String> certifications;
  final List<String> specializations;
  final List<String> trainingModes;
  final int hourlyRatePaise;
  final int bufferMinutes;
}

class TrainerBooking {
  TrainerBooking.fromJson(Json j)
      : id = j['id'],
        trainerId = j['trainer_id'] ?? j['trainerId'],
        trainerName = j['trainer_name'] ?? j['trainerName'] ?? 'Trainer',
        photoUrl = j['photo_url'] ?? j['photoUrl'],
        mode = j['mode'],
        sessionDate = j['session_date'] ?? j['sessionDate'],
        slotTime = j['slot_time'] ?? j['slotTime'],
        amountPaise = _int(j['amount_paise'] ?? j['amountPaise']),
        status = j['status'];

  final String id;
  final String trainerId;
  final String trainerName;
  final String? photoUrl;
  final String mode; // online | home | gym
  final String sessionDate;
  final String slotTime;
  final int amountPaise;
  final String status;
}

// ---- HealthStop Near You ----------------------------------------------------
class HealthChemist {
  HealthChemist.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        address = j['address'],
        city = j['city'],
        distanceKm = _double(j['distance_km'] ?? j['distanceKm']) ?? 1.0,
        operationalHours = j['operational_hours'] ?? j['operationalHours'],
        deliveryAvailable = j['delivery_available'] ?? j['deliveryAvailable'] ?? true,
        deliveryTimeEst = j['delivery_time_est'] ?? j['deliveryTimeEst'] ?? '30-45 mins',
        phone = j['phone'],
        latitude = _double(j['latitude']),
        longitude = _double(j['longitude']);

  final String id;
  final String name;
  final String address;
  final String city;
  final double distanceKm;
  final String operationalHours;
  final bool deliveryAvailable;
  final String deliveryTimeEst;
  final String phone;
  final double? latitude;
  final double? longitude;
}

class ClinicDoctor {
  ClinicDoctor.fromJson(Json j)
      : name = j['name'] ?? '',
        degree = j['degree'] ?? '',
        specialty = j['specialty'] ?? '';

  final String name;
  final String degree;
  final String specialty;
}

class HealthClinic {
  HealthClinic.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        address = j['address'],
        city = j['city'],
        distanceKm = _double(j['distance_km'] ?? j['distanceKm']) ?? 1.0,
        doctors = [
          if (j['doctors'] is List)
            for (final d in j['doctors'] as List) ClinicDoctor.fromJson(Map<String, dynamic>.from(d as Map)),
        ],
        facilities = _strings(j['facilities']),
        slotTimings = j['slot_timings'] ?? j['slotTimings'],
        consultationFeePaise = _int(j['consultation_fee_paise'] ?? j['consultationFeePaise']),
        phone = j['phone'],
        latitude = _double(j['latitude']),
        longitude = _double(j['longitude']);

  final String id;
  final String name;
  final String address;
  final String city;
  final double distanceKm;
  final List<ClinicDoctor> doctors;
  final List<String> facilities;
  final String slotTimings;
  final int consultationFeePaise;
  final String phone;
  final double? latitude;
  final double? longitude;
}

DateTime? parseDateOrNull(dynamic v) => _dateOrNull(v);
