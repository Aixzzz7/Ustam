// scripts/build_sql.mjs
// ============================================================================
//  Builds supabase/seed.sql from the ONE data source:
//      shared/data/servicesDatabase.json
//  using the same adapter as the website and the chat server.
//  Run after editing the database file:   npm run sql
// ============================================================================
import { readFileSync, writeFileSync } from 'node:fs'
import { normalizeDatabase } from '../shared/normalize.js'

const raw = JSON.parse(readFileSync(new URL('../shared/data/servicesDatabase.json', import.meta.url), 'utf8'))
const db = normalizeDatabase(raw)

/** SQL literal */
const q = (v) => {
  if (v === null || v === undefined) return 'null'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  if (typeof v === 'number') return String(v)
  if (Array.isArray(v)) return `array[${v.map(q).join(',')}]::text[]`
  return `'${String(v).replace(/'/g, "''")}'`
}
const insert = (table, cols, rows) =>
  rows.length ? `insert into ${table} (${cols.join(', ')}) values\n${rows.map((r) => `(${r.map(q).join(', ')})`).join(',\n')};` : ''

const m = db.meta
const sql = [
  '-- AUTO-GENERATED from shared/data/servicesDatabase.json by scripts/build_sql.mjs — do not edit.',
  'begin;',
  'truncate master_prices, master_services, masters, services, categories, meta cascade;',
  insert('meta', ['id', 'city', 'currency', 'currency_symbol', 'updated_at', 'disclaimer', 'districts'],
    [[1, m.city, m.currency, m.currencySymbol, m.updatedAt, m.disclaimer, db.districts]]),
  insert('categories', ['id', 'title', 'icon', 'sort_order'], db.categories.map((c) => [c.id, c.title, c.icon, c.sortOrder])),
  insert('services', ['id', 'category_id', 'name', 'price_from', 'price_to', 'unit', 'description', 'warranty', 'districts', 'source_olx', 'source_web', 'source_note', 'sort_order'],
    db.services.map((s, i) => [s.id, s.categoryId, s.name, s.priceFrom, s.priceTo, s.unit, s.description, s.warranty, s.districts, s.source.olx ?? null, s.source.web ?? null, s.source.note ?? '', i])),
  insert('masters', ['id', 'name', 'title', 'type', 'category_ids', 'districts', 'location', 'experience_years', 'experience_label', 'response_time', 'response_minutes', 'url', 'olx_listing_id', 'note', 'verified', 'phone', 'phone_display', 'verified_at', 'sort_order'],
    db.masters.map((x, i) => [x.id, x.name, x.title, x.type, x.categoryIds, x.districts, x.location, x.experienceYears, x.experienceLabel, x.responseTime, x.responseMinutes, x.url, x.olxListingId, x.note, x.verified, x.phone, x.phoneDisplay, x.verifiedAt, i])),
  insert('master_services', ['master_id', 'service_id'], db.masters.flatMap((x) => x.serviceIds.map((s) => [x.id, s]))),
  insert('master_prices', ['master_id', 'service_id', 'price_from', 'price_to', 'source'], db.masters.flatMap((x) => x.prices.map((p) => [x.id, p.serviceId, p.priceFrom, p.priceTo, p.source]))),
  'commit;',
].join('\n\n')

writeFileSync(new URL('../supabase/seed.sql', import.meta.url), sql + '\n')
console.log(`seed.sql: ${db.categories.length} categories, ${db.services.length} services, ${db.masters.length} masters`)
