// Importer tests on a SYNTHETIC fixture (6 rows named "TEST …") — not real food data.
// Run: node --test test/   (no database needed)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildImport, detectMapping, normaliseHeader, parseDiet, parseNumber, parseType, readFoodFile } from '../src/db/importFoods.js';

const fixture = fileURLToPath(new URL('./fixtures/food_db_TEST_fixture.csv', import.meta.url));

test('normalises headers', () => {
  assert.equal(normaliseHeader('Serving Weight (g)'), 'serving weight g');
  assert.equal(normaliseHeader('Local / Other Name'), 'local other name');
  assert.equal(normaliseHeader('Vitamin B12 (µg)'), 'vitamin b12 ug');
});

test('parses values: blank = not available, trace = 0', () => {
  assert.equal(parseNumber('').value, null);
  assert.equal(parseNumber('NA').value, null);
  assert.equal(parseNumber('1,234.5').value, 1234.5);
  assert.deepEqual(parseNumber('tr'), { value: 0, trace: true });
  assert.equal(parseType('Raw ingredient'), 'raw');
  assert.equal(parseType('Cooked dish'), 'cooked');
  assert.equal(parseDiet('Non-veg'), 'nonveg');
  assert.equal(parseDiet('Egg'), 'egg');
  assert.equal(parseDiet('Veg'), 'veg');
});

test('fails loudly on missing required columns', () => {
  const m = detectMapping(['Food Name', 'Category', 'Calories per serving']);
  assert.ok(m.errors.some((e) => e.includes('"foodId"')));
  assert.ok(m.errors.some((e) => e.includes('protein per 100g')));
});

test('imports the TEST fixture', async () => {
  const file = await readFoodFile(fixture);
  const { mapping, records, report } = buildImport(file);
  assert.deepEqual(mapping.errors, []);
  assert.equal(mapping.fields.localName, 'Local / Other Name');
  assert.equal(mapping.macros.kcal.serving, 'Calories per serving (kcal)');
  assert.equal(mapping.macros.kcal['100g'], 'Calories per 100 g (kcal)');
  assert.ok(mapping.micros.ironMg['100g']);
  assert.equal(records.length, 6);
  assert.deepEqual(report.byType, { cooked: 4, raw: 2 });
  assert.deepEqual(report.byDiet, { veg: 3, egg: 1, nonveg: 2, untagged: 0 });
  const by = Object.fromEntries(records.map((r) => [r.food_id, r]));
  assert.equal(by.TEST002.fibre_g, null); // blank → not available, not 0
  assert.equal(by.TEST003.serving_weight_g, 200); // 250 ÷ 125 × 100
  assert.equal(by.TEST003.serving_weight_computed, true);
  assert.equal(by.TEST005.serving_weight_g, 100); // "100 g" serving
  assert.equal(by.TEST006.fibre_g, 0); // "tr"
  assert.equal(by.TEST006.micros_100g.ironMg, undefined); // NA
  assert.equal(by.TEST006.micros_100g.calciumMg, 480);
  assert.equal(report.noted.length, 1);
  assert.equal(report.noted[0].foodId, 'TEST004');
  assert.equal(report.stats.blanks.fibreServing, 1);
});
