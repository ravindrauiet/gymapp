/**
 * Indian food database importer (BRD §5 — Fuel Log). Source: Indian Nutrient Databank (INDB) 2024, ICMR-NIN,
 * delivered as FitKey_Food_Database.xlsx (sheets "Food List", "All Nutrients", "Categories", "Column Guide")
 * or FitKey_Food_List.csv.
 *
 *   npm run import-foods -- <file.xlsx|file.csv> [--dry-run] [--map field="Header"] [--nutrients-basis 100g|serving]
 *   npm run import-foods -- --purge-test          # removes synthetic TEST… rows created by the test fixture
 *
 * - Columns are matched by NORMALISED header name + aliases (exact column names were not known when this was
 *   written). The detected mapping is printed; a required column that can't be mapped stops the import.
 *   Use --map to point a field at a header explicitly, e.g. --map localName="Hindi / Other Name"
 *   (nutrients: --map kcal100g="Energy (kcal)" ; fields listed by --help).
 * - Upserts by Food ID (stable): re-running never duplicates. Rows that disappeared from the file are left alone.
 * - Blank cell = not available → NULL (never 0). "tr"/"trace" → 0 and counted in the report.
 * - Serving Weight (g): taken from the file; else "100 g" serving → 100; else per-serving kcal ÷ per-100 g kcal × 100.
 * - Rows with a Data Note are stored with review_status 'pending' (hidden from member search until an admin approves
 *   them in the admin panel → Food DB tab). Admin decisions (approve / hide / fixed serving) survive re-imports;
 *   an approved row whose Data Note text changes goes back to 'pending'.
 * - --dry-run parses + validates + prints the full report and writes nothing.
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// ----------------------------------------------------------------------------------------------- header matching

/** "Serving Weight (g)" → "serving weight g"; "Local / Other Name" → "local other name"; µg/mcg → ug. */
export function normaliseHeader(h) {
  return String(h ?? '')
    .replace(/ /g, ' ')
    .toLowerCase()
    .replace(/µg|μg|mcg/g, 'ug')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

/** Identity / descriptive columns. */
export const FIELDS = {
  foodId: { required: true, aliases: ['food id', 'food code', 'fitkey food id', 'fitkey id', 'indb code', 'food_code', 'id', 'code'] },
  name: { required: true, aliases: ['food name', 'name', 'dish name', 'food', 'food item', 'english name', 'item name'] },
  localName: {
    aliases: ['local other name', 'local or other name', 'local name', 'other name', 'other names', 'local names', 'hindi name',
      'also known as', 'aka', 'alias', 'aliases', 'regional name', 'common name', 'local other names'],
  },
  category: { required: true, aliases: ['category', 'food category', 'food group', 'group', 'sub category', 'subcategory'] },
  type: {
    required: true,
    aliases: ['type', 'food type', 'type cooked raw', 'cooked raw', 'cooked or raw', 'dish or ingredient', 'item type',
      'kind', 'dish type', 'type cooked dish raw ingredient'],
  },
  diet: {
    aliases: ['veg tag', 'diet', 'diet tag', 'veg', 'veg non veg', 'veg egg non veg', 'veg egg nonveg', 'diet type',
      'dietary tag', 'veg status', 'vegetarian', 'food preference', 'veg nonveg'],
  },
  servingUnit: {
    required: true,
    aliases: ['serving unit', 'serving', 'serving size', 'unit', 'portion', 'portion size', 'serving description',
      'household measure', 'serving measure', 'standard serving'],
  },
  servingWeightG: {
    aliases: ['serving weight g', 'serving weight', 'serving weight grams', 'serving wt g', 'serving grams', 'serving g',
      'grams per serving', 'serving size g', 'portion weight g', 'weight g', 'weight per serving g'],
  },
  dataNote: { aliases: ['data note', 'data notes', 'note', 'notes', 'remarks', 'remark', 'data flag', 'flag', 'flags', 'qa note'] },
};

/** Macro nutrients — required at BOTH bases (per serving and per 100 g), except fibre (optional). */
export const MACROS = {
  kcal: { required: true, re: /\b(energy|calories|calorie|kcal|cal)\b/, not: /\bkj\b/ },
  protein: { required: true, re: /\bproteins?\b/ },
  carbs: { required: true, re: /\b(carbs?|carbohydrates?|cho)\b/, not: /\b(sugar|fibre|fiber)\b/ },
  fat: { required: true, re: /\b(fats?|total fat|lipids?)\b/, not: /\b(saturated|sfa|mufa|pufa|trans|mono|poly|fatty)\b/ },
  fibre: { required: false, re: /\b(fibre|fiber|dietary fibre|dietary fiber)\b/ },
};

/** Key vitamins / minerals (optional) — stored in JSONB under a key that carries the unit. */
export const MICROS = {
  ironMg: { re: /\b(iron|fe)\b/, unit: 'mg' },
  calciumMg: { re: /\b(calcium|ca)\b/, unit: 'mg' },
  magnesiumMg: { re: /\bmagnesium\b/, unit: 'mg' },
  sodiumMg: { re: /\b(sodium|na)\b/, unit: 'mg' },
  potassiumMg: { re: /\b(potassium|k)\b/, unit: 'mg' },
  zincMg: { re: /\b(zinc|zn)\b/, unit: 'mg' },
  phosphorusMg: { re: /\b(phosphorus|phosphorous)\b/, unit: 'mg' },
  vitaminAUg: { re: /\b(vitamin a|vit a|retinol equivalent|vitamin a rae)\b/, unit: 'ug' },
  vitaminCMg: { re: /\b(vitamin c|vit c|ascorbic acid)\b/, unit: 'mg' },
  vitaminDUg: { re: /\b(vitamin d|vit d)\b/, unit: 'ug' },
  vitaminB12Ug: { re: /\b(vitamin b12|vit b12|b12|cobalamin)\b/, unit: 'ug' },
  folateUg: { re: /\b(folate|folic acid|vitamin b9)\b/, unit: 'ug' },
  sugarG: { re: /\b(sugar|sugars|free sugar|total sugars?)\b/, unit: 'g' },
  saturatedFatG: { re: /\b(saturated fat|saturated fatty acids|sfa)\b/, unit: 'g' },
  cholesterolMg: { re: /\bcholesterol\b/, unit: 'mg' },
};

const UNIT_FACTOR = { g: 1, mg: 1e-3, ug: 1e-6 };

/** Which basis a nutrient header refers to: '100g', 'serving' or null (not stated). */
export function headerBasis(n) {
  if (/\b100 ?g\b|\bper 100\b|\b100 ml\b|\b100g\b/.test(n)) return '100g';
  if (/\b(per )?(serving|serve|portion|srv)\b/.test(n)) return 'serving';
  return null;
}

/** Unit written in a header ("iron mg" → mg), or null. */
function headerUnit(n) {
  const stripped = n.replace(/\b100 ?g\b|\b100g\b/g, ' ');
  const m = stripped.match(/\b(mg|ug|g|kcal|iu|kj)\b/);
  return m ? m[1] : null;
}

/**
 * Builds the column mapping for the "Food List" sheet.
 * @returns {{fields: Record<string,string>, macros: Record<string,{serving?:string,'100g'?:string}>,
 *   micros: Record<string,{serving?:{header,unit},'100g'?:{header,unit}}>, extra: string[], errors: string[], warnings: string[]}}
 */
export function detectMapping(headers, { overrides = {} } = {}) {
  const errors = [];
  const warnings = [];
  const used = new Set();
  const fields = {};
  const norm = new Map(headers.filter((h) => String(h ?? '').trim()).map((h) => [h, normaliseHeader(h)]));
  const findHeader = (label) => {
    const want = normaliseHeader(label);
    return [...norm.keys()].find((h) => h === label || norm.get(h) === want);
  };

  // 1. explicit overrides (--map field="Header")
  const macros = {};
  const micros = {};
  for (const [key, header] of Object.entries(overrides)) {
    const h = findHeader(header);
    if (!h) {
      errors.push(`--map ${key}="${header}": no such column (columns: ${[...norm.keys()].join(' | ')})`);
      continue;
    }
    const mm = key.match(/^(kcal|protein|carbs|fat|fibre)(Serving|100g)$/);
    const mi = key.match(/^(\w+?)(Serving|100g)$/);
    if (FIELDS[key]) fields[key] = h;
    else if (mm) (macros[mm[1]] ??= {})[mm[2] === 'Serving' ? 'serving' : '100g'] = h;
    else if (mi && MICROS[mi[1]]) {
      (micros[mi[1]] ??= {})[mi[2] === 'Serving' ? 'serving' : '100g'] = { header: h, unit: headerUnit(norm.get(h)) ?? MICROS[mi[1]].unit };
    } else {
      errors.push(`--map ${key}: unknown field (use ${Object.keys(FIELDS).join(', ')}, kcalServing, kcal100g, proteinServing, … ironMg100g …)`);
      continue;
    }
    used.add(h);
  }

  // 2. identity fields by alias (exact normalised match, alias order = priority)
  for (const [key, spec] of Object.entries(FIELDS)) {
    if (fields[key]) continue;
    for (const alias of spec.aliases) {
      const h = [...norm.keys()].find((x) => !used.has(x) && norm.get(x) === normaliseHeader(alias));
      if (h) {
        fields[key] = h;
        used.add(h);
        break;
      }
    }
  }

  // 3. nutrients by keyword + basis
  const unbased = []; // [{kind, key, header}]
  for (const [h, n] of norm) {
    if (used.has(h)) continue;
    const basis = headerBasis(n);
    const unit = headerUnit(n);
    const macro = Object.entries(MACROS).find(([, s]) => s.re.test(n) && !(s.not && s.not.test(n)));
    const micro = macro ? null : Object.entries(MICROS).find(([, s]) => s.re.test(n));
    if (macro) {
      if (macro[0] === 'kcal' && unit === 'kj') continue;
      if (!basis) {
        unbased.push({ kind: 'macro', key: macro[0], header: h });
        continue;
      }
      const slot = (macros[macro[0]] ??= {});
      if (slot[basis]) {
        errors.push(`Two columns look like ${macro[0]} per ${basis}: "${slot[basis]}" and "${h}" — pick one with --map ${macro[0]}${basis === 'serving' ? 'Serving' : '100g'}="…"`);
        continue;
      }
      slot[basis] = h;
      used.add(h);
    } else if (micro) {
      if (unit === 'iu') {
        warnings.push(`"${h}" is in IU — kept verbatim in extra, not converted.`);
        continue;
      }
      if (!basis) {
        unbased.push({ kind: 'micro', key: micro[0], header: h, unit });
        continue;
      }
      const slot = (micros[micro[0]] ??= {});
      if (slot[basis]) {
        warnings.push(`Second column for ${micro[0]} per ${basis} ("${h}") ignored — kept in extra.`);
        continue;
      }
      slot[basis] = { header: h, unit: unit ?? MICROS[micro[0]].unit };
      used.add(h);
    }
  }
  // A nutrient column without "per 100 g" / "per serving" in its name: assign it to the basis that is still free.
  for (const u of unbased) {
    const slot = u.kind === 'macro' ? (macros[u.key] ??= {}) : (micros[u.key] ??= {});
    const free = ['serving', '100g'].filter((b) => !slot[b]);
    if (free.length === 1) {
      slot[free[0]] = u.kind === 'macro' ? u.header : { header: u.header, unit: u.unit ?? MICROS[u.key].unit };
      used.add(u.header);
      warnings.push(`"${u.header}" does not say per serving / per 100 g — assumed per ${free[0]} (the other basis is mapped). Override with --map if wrong.`);
    } else if (u.kind === 'macro') {
      errors.push(`"${u.header}" looks like ${u.key} but does not say per serving or per 100 g — use --map ${u.key}Serving="…" / --map ${u.key}100g="…"`);
    } else {
      warnings.push(`"${u.header}" (${u.key}) has no basis — kept verbatim in extra.`);
    }
  }
  for (const k of Object.keys(micros)) if (!micros[k].serving && !micros[k]['100g']) delete micros[k];

  // 4. required checks — fail loudly
  for (const [key, spec] of Object.entries(FIELDS)) {
    if (fields[key]) continue;
    if (spec.required) errors.push(`Required column "${key}" not found (tried: ${spec.aliases.join(', ')}). Use --map ${key}="<header>".`);
    else warnings.push(`Optional column "${key}" not found — ${key === 'diet' ? 'Veg / Egg / Non-veg filter will have no data' : 'left empty'}.`);
  }
  for (const [key, spec] of Object.entries(MACROS)) {
    for (const basis of ['serving', '100g']) {
      if (macros[key]?.[basis]) continue;
      const msg = `Column for ${key} per ${basis} not found. Use --map ${key}${basis === 'serving' ? 'Serving' : '100g'}="<header>".`;
      if (spec.required) errors.push(msg);
      else warnings.push(msg);
    }
  }

  const extra = [...norm.keys()].filter((h) => !used.has(h));
  return { fields, macros, micros, extra, errors, warnings };
}

// ----------------------------------------------------------------------------------------------- value parsing

const BLANK = new Set(['', '-', '--', '—', '–', 'na', 'n/a', 'n a', 'nd', 'n.d.', 'null', 'none', 'nil', '?']);

/** Number or null (blank / NA = not available). 'tr'/'trace' → 0 with trace=true. */
export function parseNumber(v) {
  if (v == null) return { value: null };
  if (typeof v === 'number') return { value: Number.isFinite(v) ? v : null };
  const s = String(v).trim().toLowerCase();
  if (BLANK.has(s)) return { value: null };
  if (s === 'tr' || s === 'trace' || s === 'traces') return { value: 0, trace: true };
  const n = Number(s.replace(/,/g, '').replace(/^<\s*/, ''));
  return Number.isFinite(n) ? { value: n } : { value: null, bad: true };
}

export function parseType(v) {
  const s = normaliseHeader(v);
  if (!s) return null;
  if (/\b(raw|ingredient|ingredients|uncooked)\b/.test(s)) return 'raw';
  if (/\b(cooked|dish|dishes|recipe|recipes|prepared)\b/.test(s)) return 'cooked';
  return null;
}

export function parseDiet(v) {
  const s = normaliseHeader(v);
  if (!s) return null;
  if (/\bnon ?veg|nonvegetarian|non vegetarian|\bnv\b|meat|fish/.test(s)) return 'nonveg';
  if (/\begg|eggetarian|ovo/.test(s)) return 'egg';
  if (/\bveg|vegetarian|vegan|\bv\b/.test(s)) return 'veg';
  return undefined; // present but unrecognised
}

const text = (v) => {
  if (v == null) return null;
  const s = String(v).replace(/ /g, ' ').trim();
  return s === '' ? null : s;
};

/** exceljs cell value → plain JS (rich text, formulas, hyperlinks, dates). */
export function cellValue(v) {
  if (v == null) return null;
  if (typeof v !== 'object') return v;
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (Array.isArray(v.richText)) return v.richText.map((t) => t.text).join('');
  if ('result' in v) return cellValue(v.result);
  if ('text' in v) return v.text;
  if ('error' in v) return null;
  return String(v);
}

const round = (n, d = 3) => (n == null ? null : Math.round(n * 10 ** d) / 10 ** d);

/** One file row → a food_db record, or {error}. */
export function mapRow(raw, mapping, stats) {
  const get = (h) => (h ? raw[h] : undefined);
  const num = (h, col) => {
    if (!h) return null;
    const r = parseNumber(get(h));
    if (r.value == null) stats.blanks[col] = (stats.blanks[col] ?? 0) + 1;
    if (r.trace) stats.trace[col] = (stats.trace[col] ?? 0) + 1;
    if (r.bad) stats.badNumbers.push({ column: h, value: String(get(h)) });
    return r.value;
  };
  const str = (key) => {
    const v = text(get(mapping.fields[key]));
    if (mapping.fields[key] && v == null) stats.blanks[key] = (stats.blanks[key] ?? 0) + 1;
    return v;
  };

  const foodId = str('foodId');
  const name = str('name');
  if (!foodId) return { error: 'missing Food ID', name };
  if (!name) return { error: 'missing Food Name', foodId };
  const typeRaw = get(mapping.fields.type);
  const foodType = parseType(typeRaw);
  if (!foodType) return { error: `unrecognised Type "${text(typeRaw) ?? ''}" (expected cooked / raw)`, foodId, name };
  const category = str('category') ?? 'Uncategorised';
  let diet = null;
  if (mapping.fields.diet) {
    const d = parseDiet(get(mapping.fields.diet));
    if (d === undefined) {
      stats.unknownDiet.push({ foodId, value: text(get(mapping.fields.diet)) });
      diet = null;
    } else diet = d;
  }
  let servingUnit = str('servingUnit');
  if (!servingUnit) {
    if (foodType === 'raw') servingUnit = '100 g';
    else return { error: 'missing Serving Unit for a cooked dish', foodId, name };
  }

  const m = mapping.macros;
  const rec = {
    food_id: foodId,
    name: name.slice(0, 300),
    local_name: str('localName'),
    category,
    food_type: foodType,
    diet,
    serving_unit: servingUnit,
    kcal: num(m.kcal?.serving, 'kcalServing'),
    protein_g: num(m.protein?.serving, 'proteinServing'),
    carbs_g: num(m.carbs?.serving, 'carbsServing'),
    fat_g: num(m.fat?.serving, 'fatServing'),
    fibre_g: num(m.fibre?.serving, 'fibreServing'),
    kcal_100g: num(m.kcal?.['100g'], 'kcal100g'),
    protein_100g: num(m.protein?.['100g'], 'protein100g'),
    carbs_100g: num(m.carbs?.['100g'], 'carbs100g'),
    fat_100g: num(m.fat?.['100g'], 'fat100g'),
    fibre_100g: num(m.fibre?.['100g'], 'fibre100g'),
    micros_100g: {},
    micros_serving: {},
    extra: {},
    data_note: str('dataNote'),
    serving_weight_computed: false,
  };
  for (const [key, slot] of Object.entries(mapping.micros)) {
    const want = MICROS[key].unit;
    for (const basis of ['serving', '100g']) {
      if (!slot[basis]) continue;
      const v = num(slot[basis].header, `${key}${basis === 'serving' ? 'Serving' : '100g'}`);
      if (v == null) continue;
      const from = UNIT_FACTOR[slot[basis].unit] && UNIT_FACTOR[want] ? UNIT_FACTOR[slot[basis].unit] / UNIT_FACTOR[want] : 1;
      rec[basis === 'serving' ? 'micros_serving' : 'micros_100g'][key] = round(v * from, 4);
    }
  }
  for (const h of mapping.extra) {
    const v = cellValue(raw[h]);
    if (v != null && String(v).trim() !== '') rec.extra[h] = v;
  }

  // Serving weight (g): file → "100 g" → kcal/serving ÷ kcal/100 g × 100 (developer note).
  let w = mapping.fields.servingWeightG ? num(mapping.fields.servingWeightG, 'servingWeightG') : null;
  if (w == null && /^100\s*(g|gm|gms|grams?)$/i.test(servingUnit.trim())) w = 100;
  if (w == null && rec.kcal != null && rec.kcal_100g) {
    w = round((rec.kcal / rec.kcal_100g) * 100, 1);
    rec.serving_weight_computed = true;
    stats.computedWeights += 1;
  }
  rec.serving_weight_g = w != null && w > 0 ? round(w, 2) : null;

  if (rec.kcal != null && rec.kcal > 1200 && !rec.data_note) stats.bigServingNoNote.push({ foodId, name, kcal: rec.kcal });
  return { rec };
}

// ----------------------------------------------------------------------------------------------- file reading

/** Minimal RFC 4180 CSV parser (quotes, escaped quotes, CRLF, newlines inside quotes, BOM). */
export function parseCsv(textIn) {
  const s = textIn.replace(/^﻿/, '');
  const firstLine = s.slice(0, s.indexOf('\n') === -1 ? s.length : s.indexOf('\n'));
  const delim = (firstLine.match(/;/g) ?? []).length > (firstLine.match(/,/g) ?? []).length ? ';' : firstLine.includes('\t') && !firstLine.includes(',') ? '\t' : ',';
  const rows = [];
  let row = [];
  let field = '';
  let q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === '"') {
        if (s[i + 1] === '"') {
          field += '"';
          i++;
        } else q = false;
      } else field += c;
    } else if (c === '"') q = true;
    else if (c === delim) {
      row.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && s[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += c;
  }
  if (field !== '' || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.some((x) => String(x).trim() !== ''));
}

/** Header row = first row (of the first 15) with ≥ 3 non-empty cells containing something like "name". */
export function tableFromRows(rows) {
  let hi = rows.findIndex((r, i) => i < 15 && r.filter((x) => String(x ?? '').trim()).length >= 3 && r.some((x) => /name|food|id/i.test(String(x ?? ''))));
  if (hi < 0) hi = 0;
  const headers = (rows[hi] ?? []).map((x) => String(cellValue(x) ?? '').trim());
  const seen = new Map();
  const unique = headers.map((h) => {
    if (!h) return h;
    const n = (seen.get(h) ?? 0) + 1;
    seen.set(h, n);
    return n > 1 ? `${h} (${n})` : h;
  });
  const data = rows.slice(hi + 1).map((r, idx) => {
    const o = { __row: hi + 2 + idx };
    unique.forEach((h, i) => {
      if (h) o[h] = cellValue(r[i]);
    });
    return o;
  });
  return { headers: unique.filter(Boolean), rows: data.filter((o) => Object.entries(o).some(([k, v]) => k !== '__row' && v != null && String(v).trim() !== '')) };
}

async function readWorkbook(file) {
  const { default: ExcelJS } = await import('exceljs');
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.readFile(file);
  const sheets = {};
  wb.eachSheet((ws) => {
    const rows = [];
    ws.eachRow({ includeEmpty: false }, (r) => {
      const vals = r.values; // 1-based
      rows.push(Array.isArray(vals) ? vals.slice(1) : []);
    });
    sheets[ws.name] = rows;
  });
  return sheets;
}

const pickSheet = (sheets, names) => {
  const keys = Object.keys(sheets);
  for (const n of names) {
    const k = keys.find((x) => normaliseHeader(x) === normaliseHeader(n));
    if (k) return k;
  }
  return null;
};

/** Reads .xlsx or .csv → { main: {headers, rows}, nutrients?: {headers, rows}, categories?, sheetNames } */
export async function readFoodFile(file) {
  const ext = path.extname(file).toLowerCase();
  if (ext === '.csv' || ext === '.tsv' || ext === '.txt') {
    return { main: tableFromRows(parseCsv(await readFile(file, 'utf8'))), sheetNames: ['(csv)'] };
  }
  if (ext !== '.xlsx' && ext !== '.xlsm') throw new Error(`Unsupported file type "${ext}" — use .xlsx or .csv`);
  const sheets = await readWorkbook(file);
  const names = Object.keys(sheets);
  const mainName = pickSheet(sheets, ['Food List', 'Foods', 'Food Database']) ?? names[0];
  const nutName = pickSheet(sheets, ['All Nutrients', 'Nutrients']);
  const catName = pickSheet(sheets, ['Categories', 'Category']);
  return {
    main: tableFromRows(sheets[mainName]),
    mainSheet: mainName,
    nutrients: nutName && nutName !== mainName ? tableFromRows(sheets[nutName]) : null,
    categories: catName ? tableFromRows(sheets[catName]) : null,
    sheetNames: names,
  };
}

// ----------------------------------------------------------------------------------------------- pipeline

/** Parses + validates everything. Pure (no DB). */
export function buildImport(file, { overrides = {}, nutrientsBasis = null } = {}) {
  const mapping = detectMapping(file.main.headers, { overrides });
  const stats = { blanks: {}, trace: {}, badNumbers: [], unknownDiet: [], computedWeights: 0, bigServingNoNote: [] };
  const report = { mapping, stats, invalid: [], duplicates: [] };
  if (mapping.errors.length) return { mapping, records: [], report };

  const byId = new Map();
  for (const raw of file.main.rows) {
    const r = mapRow(raw, mapping, stats);
    if (r.error) {
      report.invalid.push({ row: raw.__row, foodId: r.foodId ?? null, name: r.name ?? null, error: r.error });
      continue;
    }
    if (byId.has(r.rec.food_id)) report.duplicates.push({ row: raw.__row, foodId: r.rec.food_id });
    byId.set(r.rec.food_id, r.rec);
  }

  // "All Nutrients" sheet: joined by Food ID. Explicit-basis micro columns fill micros; everything else → extra.
  if (file.nutrients) {
    const nh = file.nutrients.headers;
    const idH = nh.find((h) => FIELDS.foodId.aliases.some((a) => normaliseHeader(a) === normaliseHeader(h)));
    const nm = { joined: 0, unmatched: 0, idColumn: idH ?? null, micros: {}, assumedBasis: nutrientsBasis };
    if (idH) {
      const skip = new Set([idH, ...nh.filter((h) => Object.values(FIELDS).some((f) => f.aliases.some((a) => normaliseHeader(a) === normaliseHeader(h))))]);
      for (const h of nh) {
        if (skip.has(h)) continue;
        const n = normaliseHeader(h);
        const micro = Object.entries(MICROS).find(([, s]) => s.re.test(n));
        const basis = headerBasis(n) ?? nutrientsBasis;
        if (micro && basis && headerUnit(n) !== 'iu') nm.micros[h] = { key: micro[0], basis, unit: headerUnit(n) ?? micro[1].unit };
      }
      for (const raw of file.nutrients.rows) {
        const id = text(raw[idH]);
        const rec = id && byId.get(id);
        if (!rec) {
          nm.unmatched += 1;
          continue;
        }
        nm.joined += 1;
        const all = {};
        for (const h of nh) {
          if (skip.has(h)) continue;
          const v = cellValue(raw[h]);
          if (v == null || String(v).trim() === '') continue;
          all[h] = v;
          const mi = nm.micros[h];
          if (mi) {
            const target = mi.basis === 'serving' ? rec.micros_serving : rec.micros_100g;
            const pv = parseNumber(v).value;
            const from = UNIT_FACTOR[mi.unit] && UNIT_FACTOR[MICROS[mi.key].unit] ? UNIT_FACTOR[mi.unit] / UNIT_FACTOR[MICROS[mi.key].unit] : 1;
            if (pv != null && target[mi.key] == null) target[mi.key] = round(pv * from, 4);
          }
        }
        rec.extra.allNutrients = all;
      }
    } else {
      mapping.warnings.push('"All Nutrients" sheet has no recognisable Food ID column — sheet skipped.');
    }
    report.nutrientsSheet = nm;
  }
  if (file.categories) report.categoriesSheet = { rows: file.categories.rows.length, headers: file.categories.headers };

  const records = [...byId.values()];
  // summary
  const byType = { cooked: 0, raw: 0 };
  const byCategory = {};
  const byDiet = { veg: 0, egg: 0, nonveg: 0, untagged: 0 };
  const noted = [];
  for (const r of records) {
    byType[r.food_type] += 1;
    const k = `${r.food_type}|${r.category}`;
    byCategory[k] = (byCategory[k] ?? 0) + 1;
    byDiet[r.diet ?? 'untagged'] += 1;
    if (r.data_note) noted.push({ foodId: r.food_id, name: r.name, kcal: r.kcal, servingUnit: r.serving_unit, note: r.data_note });
  }
  Object.assign(report, { rowsInFile: file.main.rows.length, valid: records.length, byType, byCategory, byDiet, noted });
  return { mapping, records, report };
}

const COLS = [
  'food_id', 'name', 'local_name', 'category', 'food_type', 'diet', 'serving_unit', 'serving_weight_g', 'kcal', 'protein_g',
  'carbs_g', 'fat_g', 'fibre_g', 'kcal_100g', 'protein_100g', 'carbs_100g', 'fat_100g', 'fibre_100g', 'micros_100g',
  'micros_serving', 'extra', 'serving_weight_computed', 'data_note',
];
const COL_TYPES = {
  food_id: 'text', name: 'text', local_name: 'text', category: 'text', food_type: 'text', diet: 'text', serving_unit: 'text',
  data_note: 'text', micros_100g: 'jsonb', micros_serving: 'jsonb', extra: 'jsonb', serving_weight_computed: 'boolean',
};

/** Upserts records by food_id in batches. Returns {inserted, updated}. */
export async function upsertFoods(client, records, importId) {
  let inserted = 0;
  let updated = 0;
  const recordset = COLS.map((c) => `${c} ${COL_TYPES[c] ?? 'numeric'}`).join(', ');
  const setCols = COLS.filter((c) => c !== 'food_id').map((c) => `${c} = EXCLUDED.${c}`).join(',\n         ');
  for (let i = 0; i < records.length; i += 400) {
    const batch = records.slice(i, i + 400);
    const res = await client.query(
      `INSERT INTO food_db (${COLS.join(', ')}, review_status, import_id, updated_at)
       SELECT ${COLS.join(', ')}, CASE WHEN data_note IS NULL THEN 'live' ELSE 'pending' END, $2::uuid, now()
         FROM jsonb_to_recordset($1::jsonb) AS x(${recordset})
       ON CONFLICT (food_id) DO UPDATE SET
         ${setCols},
         review_status = CASE
           WHEN food_db.review_status = 'hidden' THEN 'hidden'
           WHEN EXCLUDED.data_note IS NULL THEN CASE WHEN food_db.review_status = 'pending' THEN 'live' ELSE food_db.review_status END
           WHEN food_db.review_status = 'approved' AND food_db.data_note IS NOT DISTINCT FROM EXCLUDED.data_note THEN 'approved'
           ELSE 'pending' END,
         import_id = EXCLUDED.import_id,
         updated_at = now()
       RETURNING (xmax = 0) AS inserted`,
      [JSON.stringify(batch), importId],
    );
    for (const r of res.rows) (r.inserted ? inserted++ : updated++);
  }
  return { inserted, updated };
}

// ----------------------------------------------------------------------------------------------- report printing

function printMapping(m) {
  console.log('\nDetected column mapping');
  for (const [k, h] of Object.entries(m.fields)) console.log(`  ${k.padEnd(16)} ← "${h}"`);
  for (const [k, s] of Object.entries(m.macros)) {
    console.log(`  ${(k + ' /serving').padEnd(16)} ← ${s.serving ? `"${s.serving}"` : '(none)'}`);
    console.log(`  ${(k + ' /100 g').padEnd(16)} ← ${s['100g'] ? `"${s['100g']}"` : '(none)'}`);
  }
  for (const [k, s] of Object.entries(m.micros)) {
    const p = (b) => (s[b] ? `"${s[b].header}" [${s[b].unit}]` : '(none)');
    console.log(`  ${k.padEnd(16)} ← serving ${p('serving')} · 100 g ${p('100g')}`);
  }
  if (m.extra.length) console.log(`  kept verbatim in "extra": ${m.extra.map((h) => `"${h}"`).join(', ')}`);
  for (const w of m.warnings) console.log(`  ⚠ ${w}`);
  for (const e of m.errors) console.log(`  ✖ ${e}`);
}

function printReport(r, { existing } = {}) {
  const s = r.stats;
  console.log('\nImport report');
  console.log(`  rows in file           ${r.rowsInFile}`);
  console.log(`  valid foods            ${r.valid}   (cooked dishes ${r.byType.cooked} · raw ingredients ${r.byType.raw})`);
  console.log(`  invalid rows           ${r.invalid.length}`);
  for (const x of r.invalid.slice(0, 25)) console.log(`     row ${x.row}: ${x.error}${x.foodId ? ` [${x.foodId}]` : ''}${x.name ? ` ${x.name}` : ''}`);
  if (r.invalid.length > 25) console.log(`     … ${r.invalid.length - 25} more`);
  console.log(`  duplicate Food IDs     ${r.duplicates.length}${r.duplicates.length ? ' (last row wins): ' + r.duplicates.slice(0, 10).map((d) => d.foodId).join(', ') : ''}`);
  console.log(`  diet tags              veg ${r.byDiet.veg} · egg ${r.byDiet.egg} · non-veg ${r.byDiet.nonveg} · untagged ${r.byDiet.untagged}`);
  if (s.unknownDiet.length) console.log(`  unrecognised diet tags ${s.unknownDiet.length}: ${[...new Set(s.unknownDiet.map((d) => d.value))].slice(0, 10).join(', ')}`);
  console.log(`  serving weight computed (kcal ÷ kcal/100 g × 100): ${s.computedWeights}`);
  console.log(`  rows with a Data Note  ${r.noted.length}  → imported as PENDING (hidden from search until approved in admin → Food DB)`);
  for (const n of r.noted.slice(0, 15)) console.log(`     [${n.foodId}] ${n.name} — ${n.servingUnit}, ${n.kcal ?? '—'} kcal — ${n.note}`);
  if (r.noted.length > 15) console.log(`     … ${r.noted.length - 15} more (see admin panel)`);
  if (s.bigServingNoNote.length) {
    console.log(`  ⚠ serving > 1,200 kcal WITHOUT a Data Note: ${s.bigServingNoNote.length}`);
    for (const b of s.bigServingNoNote.slice(0, 10)) console.log(`     [${b.foodId}] ${b.name} — ${b.kcal} kcal`);
  }
  console.log('  per category (cooked first)');
  const cats = Object.entries(r.byCategory).sort(([a], [b]) => (a.startsWith('cooked') === b.startsWith('cooked') ? a.localeCompare(b) : a.startsWith('cooked') ? -1 : 1));
  for (const [k, n] of cats) {
    const [t, c] = k.split('|');
    console.log(`     ${t.padEnd(7)} ${c.padEnd(34)} ${n}`);
  }
  console.log('  blanks per column (blank = not available, stored as NULL)');
  const blanks = Object.entries(s.blanks).sort((a, b) => b[1] - a[1]);
  if (!blanks.length) console.log('     none');
  for (const [k, n] of blanks) console.log(`     ${k.padEnd(22)} ${n}`);
  if (Object.keys(s.trace).length) console.log(`  "trace" values stored as 0: ${Object.entries(s.trace).map(([k, n]) => `${k} ${n}`).join(', ')}`);
  if (s.badNumbers.length) {
    console.log(`  ⚠ non-numeric values treated as not available: ${s.badNumbers.length}`);
    for (const b of s.badNumbers.slice(0, 10)) console.log(`     "${b.column}": ${b.value}`);
  }
  if (r.nutrientsSheet) {
    const n = r.nutrientsSheet;
    console.log(`  "All Nutrients" sheet  joined ${n.joined} · unmatched ${n.unmatched} · id column ${n.idColumn ?? '(none)'} · micro columns used ${Object.keys(n.micros).length}`);
    if (!n.assumedBasis) console.log('     (columns without "per 100 g"/"per serving" are kept in extra only — pass --nutrients-basis 100g if the sheet is per 100 g)');
  }
  if (r.categoriesSheet) console.log(`  "Categories" sheet     ${r.categoriesSheet.rows} rows (informational; chips come from each food's Category)`);
  if (existing) console.log(`  database               would insert ${existing.insert} · would update ${existing.update} · in DB but not in file ${existing.missing}`);
}

// ----------------------------------------------------------------------------------------------- CLI

function parseArgs(argv) {
  const args = { file: null, dryRun: false, overrides: {}, nutrientsBasis: null, purgeTest: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run' || a === '--dry') args.dryRun = true;
    else if (a === '--purge-test') args.purgeTest = true;
    else if (a === '--help' || a === '-h') args.help = true;
    else if (a === '--nutrients-basis') args.nutrientsBasis = argv[++i] === 'serving' ? 'serving' : '100g';
    else if (a.startsWith('--nutrients-basis=')) args.nutrientsBasis = a.endsWith('serving') ? 'serving' : '100g';
    else if (a === '--map' || a.startsWith('--map=')) {
      const spec = a === '--map' ? argv[++i] : a.slice(6);
      const eq = spec?.indexOf('=') ?? -1;
      if (eq > 0) args.overrides[spec.slice(0, eq).trim()] = spec.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    } else if (!a.startsWith('--')) args.file = a;
    else throw new Error(`Unknown option ${a}`);
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || (!args.file && !args.purgeTest)) {
    console.log(`Usage: npm run import-foods -- <FitKey_Food_Database.xlsx | FitKey_Food_List.csv> [--dry-run]
         [--map field="Header"] [--nutrients-basis 100g|serving]
       npm run import-foods -- --purge-test
Fields for --map: ${Object.keys(FIELDS).join(', ')}, ${Object.keys(MACROS).flatMap((k) => [`${k}Serving`, `${k}100g`]).join(', ')},
                  <micro>Serving / <micro>100g for ${Object.keys(MICROS).join(', ')}`);
    process.exitCode = args.help ? 0 : 1;
    return;
  }

  const { pool, withTransaction } = await import('./index.js');
  try {
    if (args.purgeTest) {
      const r = await pool.query(`DELETE FROM food_db WHERE food_id LIKE 'TEST%' AND name LIKE 'TEST %' RETURNING food_id`);
      const i = await pool.query(`DELETE FROM food_db_imports WHERE file_name ILIKE '%TEST%fixture%'`);
      console.log(`✔ removed ${r.rowCount} synthetic TEST rows and ${i.rowCount} fixture import records`);
      return;
    }
    const abs = path.resolve(process.env.INIT_CWD ?? process.cwd(), args.file);
    console.log(`Reading ${abs}`);
    const file = await readFoodFile(abs);
    console.log(`  sheets: ${file.sheetNames.join(', ')}${file.mainSheet ? ` — using "${file.mainSheet}"` : ''} · ${file.main.rows.length} data rows · ${file.main.headers.length} columns`);
    const { mapping, records, report } = buildImport(file, { overrides: args.overrides, nutrientsBasis: args.nutrientsBasis });
    printMapping(mapping);
    if (mapping.errors.length) {
      console.error(`\n✖ ${mapping.errors.length} column problem(s) — nothing imported. Fix the file or pass --map.`);
      process.exitCode = 2;
      return;
    }
    let existing = null;
    try {
      const ids = records.map((r) => r.food_id);
      const row = (
        await pool.query(
          `SELECT COUNT(*) FILTER (WHERE food_id = ANY($1)) AS hit, COUNT(*) FILTER (WHERE NOT (food_id = ANY($1))) AS missing FROM food_db`,
          [ids],
        )
      ).rows[0];
      existing = { update: +row.hit, insert: ids.length - +row.hit, missing: +row.missing };
    } catch (e) {
      console.log(`  (could not compare with the database: ${e.message})`);
    }
    printReport(report, { existing });
    if (args.dryRun) {
      console.log('\nDry run — nothing written.');
      return;
    }
    if (!records.length) {
      console.error('\n✖ No valid rows — nothing imported.');
      process.exitCode = 2;
      return;
    }
    const result = await withTransaction(async (client) => {
      const imp = await client.query(
        `INSERT INTO food_db_imports (file_name, rows_total, skipped, mapping, report) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
        [
          path.basename(abs),
          report.rowsInFile,
          report.invalid.length,
          JSON.stringify({ fields: mapping.fields, macros: mapping.macros, micros: mapping.micros, extra: mapping.extra, warnings: mapping.warnings }),
          JSON.stringify({
            valid: report.valid, byType: report.byType, byDiet: report.byDiet, byCategory: report.byCategory,
            noted: report.noted.length, invalid: report.invalid.slice(0, 200), duplicates: report.duplicates.length,
            blanks: report.stats.blanks, computedWeights: report.stats.computedWeights,
            bigServingNoNote: report.stats.bigServingNoNote.slice(0, 200),
          }),
        ],
      );
      const id = imp.rows[0].id;
      const counts = await upsertFoods(client, records, id);
      await client.query(`UPDATE food_db_imports SET inserted = $2, updated = $3 WHERE id = $1`, [id, counts.inserted, counts.updated]);
      return counts;
    });
    console.log(`\n✔ Imported: ${result.inserted} new, ${result.updated} updated (by Food ID). Data-Note rows await review in admin → Food DB.`);
  } finally {
    await pool.end();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((err) => {
    console.error(`✖ ${err.message}`);
    process.exitCode = 1;
  });
}
