import 'fitkey_api.dart';
import 'models.dart';

/// Indian food database (INDB 2024, ICMR-NIN) — search, categories and logging by Food ID + quantity.
/// A `null` nutrient means "not available in the source" — show it as "—", never as 0.

double? _d(dynamic v) => v == null ? null : (v as num).toDouble();

class FoodNutrients {
  const FoodNutrients({this.calories, this.proteinG, this.carbsG, this.fatG, this.fibreG});

  FoodNutrients.fromJson(Json? j)
      : calories = _d(j?['calories']),
        proteinG = _d(j?['proteinG']),
        carbsG = _d(j?['carbsG']),
        fatG = _d(j?['fatG']),
        fibreG = _d(j?['fibreG']);

  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final double? fibreG;

  bool get hasAny => calories != null || proteinG != null || carbsG != null || fatG != null;
}

class DbFood {
  DbFood.fromJson(Json j)
      : id = j['id'] as String,
        source = j['source'] as String? ?? 'indb',
        name = j['name'] as String? ?? 'Food',
        localName = j['localName'] as String?,
        category = j['category'] as String? ?? 'Other',
        type = j['type'] as String? ?? 'cooked',
        diet = j['diet'] as String?,
        servingUnit = j['servingUnit'] as String? ?? '1 serving',
        servingWeightG = _d(j['servingWeightG']),
        perServing = FoodNutrients.fromJson(j['perServing'] as Json?),
        per100g = j['per100g'] == null ? null : FoodNutrients.fromJson(j['per100g'] as Json),
        microsServing = {
          for (final e in (j['microsServing'] as Map? ?? const {}).entries)
            if (e.value != null) e.key as String: (e.value as num).toDouble(),
        },
        _raw = j;

  final String id;

  /// 'indb' (food database), 'packaged' (barcode food) or 'legacy' (old list, only before the import).
  final String source;
  final String name;
  final String? localName;
  final String category;

  /// 'cooked' | 'raw' | 'packaged'
  final String type;

  /// 'veg' | 'egg' | 'nonveg' | null
  final String? diet;
  final String servingUnit;
  final double? servingWeightG;
  final FoodNutrients perServing;
  final FoodNutrients? per100g;

  /// Key vitamins/minerals for one serving, keys carry the unit (ironMg, vitaminB12Ug, sugarG …).
  final Map<String, double> microsServing;
  final Json _raw;

  bool get isDb => source == 'indb';

  /// Grams can be entered when per-100 g values (or a serving weight) are known.
  bool get gramsAvailable =>
      isDb && (per100g?.calories != null || (perServing.calories != null && servingWeightG != null));

  /// Nutrients for a quantity — servings: per serving × n; grams: per 100 g × g ÷ 100 (same rule as the server).
  FoodNutrients nutrientsFor({required bool grams, required double quantity}) {
    double? pick(double? p100, double? ps) {
      if (!grams) return ps == null ? null : ps * quantity;
      if (p100 != null) return p100 * quantity / 100;
      if (ps != null && servingWeightG != null && servingWeightG! > 0) return ps * quantity / servingWeightG!;
      return null;
    }

    final p = per100g;
    final s = perServing;
    return FoodNutrients(
      calories: pick(p?.calories, s.calories),
      proteinG: pick(p?.proteinG, s.proteinG),
      carbsG: pick(p?.carbsG, s.carbsG),
      fatG: pick(p?.fatG, s.fatG),
      fibreG: pick(p?.fibreG, s.fibreG),
    );
  }

  /// Barcode / legacy foods keep using the existing [FoodItem] log sheet.
  FoodItem toFoodItem() => FoodItem.fromJson({
        'id': id,
        'name': name,
        'servingUnit': servingUnit,
        'calories': perServing.calories ?? 0,
        'proteinG': perServing.proteinG ?? 0,
        'carbsG': perServing.carbsG ?? 0,
        'fatG': perServing.fatG ?? 0,
        'fibreG': perServing.fibreG ?? 0,
        'ironMg': microsServing['ironMg'] ?? 0,
        'calciumMg': microsServing['calciumMg'] ?? 0,
        'magnesiumMg': microsServing['magnesiumMg'] ?? 0,
        'sodiumMg': microsServing['sodiumMg'] ?? 0,
        'category': category,
        'barcode': _raw['barcode'],
      });
}

class FoodCategory {
  FoodCategory.fromJson(Json j)
      : name = j['name'] as String,
        type = j['type'] as String? ?? 'cooked',
        count = (j['count'] as num? ?? 0).toInt();

  final String name;
  final String type; // cooked | raw
  final int count;
}

class FoodSearchPage {
  FoodSearchPage.fromJson(Json j)
      : ready = j['ready'] == true,
        foods = (j['foods'] as List? ?? const []).map((f) => DbFood.fromJson(f as Json)).toList(),
        hasMore = j['hasMore'] == true,
        credit = j['credit'] as String?;

  /// false until the Indian food database is imported (the old list is returned meanwhile).
  final bool ready;
  final List<DbFood> foods;
  final bool hasMore;
  final String? credit;
}

/// Extra per-entry details of a meal log that the shared [MealLog] model doesn't carry.
class MealLogExtra {
  MealLogExtra.fromJson(Json j)
      : quantity = _d(j['quantity']),
        unit = j['quantityUnit'] as String?,
        grams = _d(j['grams']),
        servingUnit = j['servingUnit'] as String?,
        unavailable = {for (final u in (j['unavailable'] as List? ?? const [])) u as String};

  final double? quantity;

  /// 'serving' | 'g' | null (older entries)
  final String? unit;
  final double? grams;
  final String? servingUnit;

  /// Nutrients the source didn't have: calories, proteinG, carbsG, fatG, fibreG.
  final Set<String> unavailable;
}

class FuelDay {
  FuelDay(this.summary, this.extras, this.unavailableItems);
  final MealDailySummary summary;
  final Map<String, MealLogExtra> extras;

  /// Logged items with at least one macro "not available" — totals then sum only the available values.
  final int unavailableItems;
}

extension FoodDbApi on FitkeyApi {
  Future<FoodSearchPage> searchFoods({String? q, String? category, String? type, String? diet, int limit = 30, int offset = 0}) async {
    final r = await client.get('/nutrition/food-search', query: {
      'q': q,
      'category': category,
      'type': type,
      'diet': diet,
      'limit': '$limit',
      'offset': '$offset',
    });
    return FoodSearchPage.fromJson(r);
  }

  Future<List<FoodCategory>> foodCategories({String? diet}) async {
    final r = await client.get('/nutrition/food-db/categories', query: {'diet': diet});
    return (r['categories'] as List? ?? const []).map((c) => FoodCategory.fromJson(c as Json)).toList();
  }

  /// Logs a database food by Food ID; the server computes the nutrients. [unit] is 'serving' or 'g'.
  Future<void> logDbFood({
    required String mealType,
    required String foodId,
    required String unit,
    required double quantity,
    String? loggedOn,
  }) =>
      client.post('/nutrition/meals', {
        'mealType': mealType,
        'dbFoodId': foodId,
        'unit': unit,
        'quantity': quantity,
        'loggedOn': ?loggedOn,
      });

  /// The day's diary + per-entry quantity details and the "some values unavailable" count.
  Future<FuelDay> fuelDay({String? date}) async {
    final r = await client.get('/nutrition/meals', query: {'date': date});
    final extras = <String, MealLogExtra>{};
    for (final list in (r['categories'] as Map? ?? const {}).values) {
      for (final m in (list as List? ?? const [])) {
        final j = m as Json;
        extras[j['id'] as String] = MealLogExtra.fromJson(j);
      }
    }
    return FuelDay(
      MealDailySummary.fromJson(r),
      extras,
      ((r['summary'] as Map?)?['unavailableItems'] as num? ?? 0).toInt(),
    );
  }
}
