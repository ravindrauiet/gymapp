# Partner App BRD — implementation contract

Source: *FitKey Partner App — BRD* (Nov 7 2026). Every agent builds against this file. If you must change a shape,
add to it (new optional fields), never rename or remove.

All endpoints are under `/api/v1`, JSON, camelCase (the db layer camelCases rows). Money is **paise** (int).
Times are `HH:MM` (24 h). Dates `YYYY-MM-DD`. Weekdays `mon…sun`.

## Shared code (already written — use it, don't fork it)

| File | What |
|---|---|
| `backend/src/db/migrations/210_partner_brd.sql` | core schema (venues v2, hours, pass blocks, closures, timeline, KYC, docs, bank, agreements, partner members, payouts, booking requests) |
| `backend/src/db/migrations/211_partner_types.sql` | trainer / clinic / chemist / store lifecycle columns |
| `backend/src/utils/commission.js` | `commissionPlan()`, `commissionPct()`, `passVisitPayout()`, `directSalePayout()` — **the only place commission/GST maths lives** |
| `backend/src/utils/listing.js` | `LISTING_ENTITIES`, `setListingStatus()`, `maybeGoLive()`, `listingTimeline()`, `REVIEW_TARGET_HOURS` |
| `backend/src/utils/sms.js` | `sendSms(phone, text)` (console stub — SMS / WhatsApp) |
| `partner_app/lib/data/brd_api.dart` | Dart client + models for the **shared** endpoints below (commission plan, timeline, agreement, documents, KYC, bank, partner profile) |
| `partner_app/lib/widgets/commission_plan_card.dart` | `CommissionPlanCard` |
| `partner_app/lib/widgets/status_timeline.dart` | `ListingStatusTimeline` |
| `partner_app/lib/widgets/agreement_sheet.dart` | `showAgreementSheet(context, entityType:, entityId:)` → `Future<bool>` |

Further migrations: agents may add `212_*.sql` (money/run), `213_*.sql` (other types), `214_*.sql` (admin) — additive, idempotent.

## Enums

- partnerType: `fitness_centre | sports_centre | trainer | clinic | chemist | store_seller`
- listing status: `draft | submitted | under_review | changes_needed | approved | live | rejected`
  (`approved` = admin OK, waiting for owner's OTP acceptance; live needs **both** admin approval and owner acceptance)
- entityType: `venue | trainer | clinic | chemist | store`
- sports: `badminton | table_tennis | cricket | football | basketball | tennis | squash | skating | swimming`
- docType: `licence | gst | fssai | drug_licence | clinic_registration | doctor_registration | certificate | achievement | trademark | other`
- member source: `self | fitkey_pass | fitkey_direct | fitpass | other`
- centre plan duration: `hourly | day | weekly | monthly | quarterly | yearly` (`annual` = legacy alias of yearly)
- fitkeyPassMode: `all | blocked`

## A. Partner profile & onboarding (owner: backend-listing)

- `GET /auth/me` / the partner `me` payload gains `partnerType`, `isFitkeyStaff`, `partnerGoLiveAt`, `actingStaff` (staff name when an employee is acting for this partner, else null).
- `PUT /partner/profile` `{ partnerType?, name?, email?, city? }` → `{ user }`. Email validation must accept normal addresses (`name@gmail.com`).
- `GET /partner/commission-plan` → `commissionPlan(users.partner_go_live_at)` from utils/commission.js:
  `{ standardPct, goLiveAt, currentYear, currentPct, currentYearEndsOn, years:[{year,pct,label,note,from,to,current}], message, payoutRule }`

## B. Venue listing (10 steps) (owner: backend-listing)

Venue JSON (GET/POST/PUT `/partner/venues[/:id]`) = existing fields **plus**
`sports[]`, `videoUrl`, `fitkeyPassMode`, `passAccepted`, `monthlyFeePaise`, `slotMinutes`, `slotCapacity`, `passSlotCap`,
`courts`, `autoAcceptBookings`, `listingStep`, `listedBy`, `partnerAcceptedAt`, `adminApprovedAt`, `submittedAt`, `goLiveAt`,
`photos` (max **10**), and nested arrays (accepted on PUT/POST, always returned on GET by id):
- `hours: [{ weekday, opensAt, closesAt, kind: 'open'|'ladies_only' }]` (several rows a day = split shift; replaces all rows when sent)
- `passBlocks: [{ id?, days:[weekday], startsAt, endsAt, note? }]` (replaces all when sent)
- `closures: [{ id?, closedOn, slotStart?, slotEnd?, note? }]` (upcoming only on GET)
- GET by id also returns `plans` (centre plans), `checklist: { percent, done:[step], missing:[{step,label}] }`, `timeline` (as in E), `passPayoutPreview: passVisitPayout(...)` when monthlyFeePaise is set.

Checklist steps: 1 Category · 2 Details · 3 Location · 4 Timings & FitKey access · 5 Photos · 6 Facilities · 7 Pricing & FitKey pass · 8 Slots & capacity · 9 Documents & bank · 10 Review & submit.
Step 7 done = ≥1 active centre plan **and** `monthlyFeePaise` **and** `passAccepted`. Step 9 done = a `licence` doc + KYC + bank account (pending or verified).
Description must be ≥ 40 chars (BRD §11 fix). Photos ≥ 4 to submit.

- `POST /partner/venues/:id/submit` → 400 `{ error, missing:[{step,label}] }` when incomplete; else status `submitted` (+ timeline + notify). Allowed from `draft | changes_needed | rejected`.
- Centre plans keep using the existing memberships endpoints (`/memberships/partner/...`); durations gain hourly/weekly/yearly.

## C. Documents, KYC, bank, agreement (owner: backend-listing)

- `GET /partner/documents?entityType=&entityId=` → `{ documents:[{id,docType,fileUrl,docNumber,expiresOn,status,reviewNote,createdAt}] }`
- `POST /partner/documents` `{ entityType, entityId, docType, fileUrl, docNumber?, expiresOn? }` → `{ document }` (fileUrl from `POST /uploads`; PDFs allowed)
- `DELETE /partner/documents/:id`
- `GET /partner/kyc` → `{ kyc: { method, aadhaarMasked, nameOnId, status, verifiedAt } | null }`
- `POST /partner/kyc` `{ method: 'digilocker'|'offline_ekyc', aadhaarLast4, nameOnId }` → stores **only** `XXXX-XXXX-<last4>` (mock verification, `KYC_MODE=mock`; a real DigiLocker integration plugs in here). Never accept/store a 12-digit number.
- `GET /partner/bank` → `{ account: { id, holderName, last4, ifsc, bankName, status, verifiedName, verifiedAt } | null }` (never the full number)
- `POST /partner/bank` `{ holderName, accountNumber, ifsc }` → penny-drop (mock: verified at once, verifiedName = holderName) → `{ account }`
- `POST /partner/agreement/otp` `{ entityType, entityId }` → `{ sent: true, devOtp? }` (OTP to the owner's phone; dev returns devOtp like login)
- `POST /partner/agreement/accept` `{ entityType, entityId, otp }` → `{ agreement, listing }` — stores `partner_agreements` (terms = commission plan + payout rule snapshot), sets `partner_accepted_at`, then `maybeGoLive()`.
- `GET /partner/pending-acceptance` → `{ items:[{ entityType, entityId, name, listedByName }] }` — approved listings (usually assisted) waiting for the owner's OTP.

## D. Assisted listing (owner: backend-listing)

- Staff = partner account with `users.is_fitkey_staff = true` (admin sets it).
- `POST /partner/staff/partners` `{ phone, name, partnerType, city? }` → `{ partner, actAsToken }`: creates/gets the partner user (role partner) and returns a JWT for that partner with claim `staffId`. The app swaps to this token while "listing on behalf".
- Requests carrying a `staffId` claim: listings they create get `listed_by = staffId`; **403** on earnings, payouts, members, bank (GET full), payout statements; **403** once the partner has any live listing (access removed at go-live).
- `GET /partner/staff/listings` (staff's own token) → `{ listings:[{ entityType, entityId, name, status, partnerName, partnerPhone, createdAt }] }`
- On admin approval of a listing whose owner hasn't accepted: status `approved`, SMS/WhatsApp to owner with app link + "log in with your mobile number".

## E. Status timeline (owner: backend-listing)

- `GET /partner/listings/:entityType/:id/timeline` → `listingTimeline()` = `{ events:[{status,note,fixes:[{step,message}],createdAt,actorName}], reviewTargetHours }`

## F. Run / Sell / Earn (owner: backend-money)

- `GET /partner/home` → `{ live, venues:[{id,name,status}], earnings:{ todayPaise, weekPaise, monthPaise, bySource:[{source,netPaise}] }, today:{ checkins, bookings, pendingRequests, renewalsDue }, commission: commissionPlan, checklist? (first non-live venue) }`
- Members: `GET /partner/venues/:id/members?source=&status=&q=` → `{ members:[{ key, id?, name, phone (masked for FitKey users: 98XXXXXX21), joinedOn, planLabel, renewalOn, source, pricePaise, earningPerDayPaise, status:'active'|'expiring'|'expired', manual:boolean }] }`
  (FitKey direct memberships → source fitkey_direct, FitKey-pass visitors (last 30 d) → fitkey_pass, plus manual rows). Status: expiring = renewal within 7 days.
  `POST /partner/venues/:id/members` `{ name, phone?, joinedOn, planLabel, renewalOn?, source, pricePaise, remindMember? }`, `PUT …/members/:memberId`, `DELETE …/members/:memberId`.
- Renewal alerts: daily job — partner notified 7 d and 1 d before renewal; optional SMS/WhatsApp to the member (`remind_member`).
- Slot board: `GET /partner/venues/:id/slot-board?date=` → `{ date, slotMinutes, slots:[{ start, end, capacity, booked, passBooked, passCap, available, blocked, passBlocked, ladiesOnly }] }`
- Requests: `GET /partner/venues/:id/booking-requests` → `{ requests:[booking] }`; `POST /partner/bookings/:id/accept`; `POST /partner/bookings/:id/reject` `{ reason? }`; auto-accept via venue `autoAcceptBookings`.
  Auto-accept toggle: `PUT /partner/venues/:id/booking-settings` `{ autoAcceptBookings }` (backend-money).
- Closures / blocked slots: `POST /partner/venues/:id/closures` `{ closedOn, slotStart?, slotEnd?, note? }`, `DELETE /partner/venues/:id/closures/:closureId`.
- Earnings: `GET /partner/earnings?from=&to=&venueId=` → `{ totals:{grossPaise,commissionPaise,gstPaise,netPaise}, bySource:[{source,count,grossPaise,commissionPaise,gstPaise,netPaise}], byDay:[{date,netPaise}] }`
  `GET /partner/earnings/visits?date=&venueId=` → per FitKey-pass visit `{ visits:[{ checkinId, memberName, time, grossPaise, commissionPct, commissionPaise, netPaise }] }`
- Payouts: `GET /partner/payouts` → `{ schedule:'weekly', nextPayoutOn, payouts:[{ id, periodStart, periodEnd, grossPaise, commissionPaise, gstPaise, netPaise, status, utr, paidAt }] }`; `GET /partner/payouts/:id/statement.csv`; `GET /partner/payouts/:id/invoice` (HTML GST invoice).
- Payout rules (use utils/commission.js): FitKey-pass check-in → `passVisitPayout(venue.monthly_fee_paise, owner.partner_go_live_at, visitDate)` into `visit_payouts.gross_paise/commission_pct/commission_paise/amount_paise`; direct plan sale → `directSalePayout(...)` into `direct_memberships.gst_paise/commission_pct/commission_paise/partner_net_paise`. Venues without monthlyFeePaise keep the old rule.

## G. Member-facing (owner: user-app + backend-money for API)

- `GET /venues/:id` (member) gains `sports`, `videoUrl`, `slotMinutes`, `hours`, `passBlocks`, `passBlockLabels:["FitKey pass not valid 6–8 PM (Mon–Fri)"]`, `closures` (next 30 days), `ladiesOnlyLabels`.
- Booking/check-in with the FitKey pass (coins / session / legacy pass) inside a pass block → 409 `{ error: 'FitKey pass not valid 6–8 PM at this venue. Your own <venue> pass works at any time.' , code:'PASS_BLOCKED' }`. Direct-membership members are not affected. Closed dates / blocked slots / outside hours → 409 `code:'VENUE_CLOSED'`. Pass cap per slot → 409 `code:'PASS_SLOT_FULL'`.
- Booking when `autoAcceptBookings=false` → status `requested`; member notified on accept/reject.

## H. Other partner types (owner: backend-types)

Profile → pricing → availability → documents → review, per BRD §7 table. Endpoints (owner = req.user, one listing per type per owner):
- `GET/PUT /partner/listing/clinic`, `POST /partner/listing/clinic/submit`
- `GET/PUT /partner/listing/chemist`, `POST /partner/listing/chemist/submit`
- `GET/PUT /partner/listing/trainer`, `POST /partner/listing/trainer/submit` (extends existing trainer profile)
- `GET/PUT /partner/listing/store`, `POST /partner/listing/store/submit` (extends marketplace vendor)
Each GET returns `{ listing, checklist:{percent,missing:[{step,label}]}, timeline }`. Submit uses `setListingStatus(...,'submitted')`.
Rules: supplements / healthy_food store sellers can't go live without a verified `fssai` document; trainer "Verified" badge only when certificates verified (`certificates_verified_at`).

## I. Admin (owner: backend-listing for API, admin-ui agent for panel)

- `GET /admin/listings?status=&entityType=` → queue across all entity types, with owner, listedBy (staff name), submittedAt, docs counts.
- `GET /admin/listings/:entityType/:id` → full listing + documents + kyc + bank (last4) + timeline.
- `POST /admin/listings/:entityType/:id/review` `{ action: 'under_review'|'changes_needed'|'approve'|'reject', note?, fixes?:[{step,message}] }` → approve sets `admin_approved_at` then `maybeGoLive()`; if the owner hasn't accepted yet → status `approved` + SMS.
- `POST /admin/partner-documents/:id` `{ status:'verified'|'rejected', note? }`; `POST /admin/partner-bank/:id` `{ status }`.
- `PUT /admin/users/:id/staff` `{ isFitkeyStaff }`; `GET /admin/staff-report` → per employee: listings created, approved, live.
- `GET /admin/payouts` + `POST /admin/payouts/run` `{ periodStart, periodEnd }` (creates partner_payouts rows from visit_payouts + direct_memberships + nothing for manual sources) + `POST /admin/payouts/:id` `{ status, utr? }`.

## Partner app structure (BRD §9)

Bottom nav: **Home · Run · Sell · Earn · Account**. Before any venue is live: Home shows setup checklist + timeline +
commission card; quick actions (Show QR, Attendance, Events) are locked. After live: earnings (today/week/month by
source), today's summary, quick actions (Show QR, Scan check-in, Add member, Bookings, Ratings), commission card.
Partner-type aware (§10.4): trainers / clinics / chemists / store sellers see their own Run/Sell/Earn content.

## Changes by backend-types

Files: `backend/src/routes/partner_types.js` (new), `backend/src/utils/partner_types.js` (+ `.test.js`), `backend/src/db/migrations/213_partner_types_run.sql`,
edits in `routes/trainers.js`, `routes/marketplace.js`, `routes/healthstop.js`, `app.js` (mounts only).

**Admin hook (backend-listing: please wire this).** `POST /admin/partner-documents/:id` must call, after updating the row,
`await onDocumentVerified(doc)` from `backend/src/utils/partner_types.js` (pass the updated `partner_documents` row, camel or
snake case). It recomputes `trainers.certificates_verified_at` (trainer + `certificate`) and `marketplace_vendors.fssai_verified_at`
(store + `fssai`) from the documents (verified and not expired → set; otherwise NULL). Call it for both verify and reject.
Also: `goLiveBlockers(entityType, listing)` (same file) returns `[{step,label}]` — for a store with supplements / healthy_food
and no `fssaiVerifiedAt` it is non-empty; admin approve should refuse (or not flip to live) while it is non-empty.

**Listing (§H)** — `GET|PUT /partner/listing/:type`, `POST /partner/listing/:type/submit`, type = `trainer|clinic|chemist|store`.
Response (all three): `{ listing, checklist:{percent,done:[step],missing:[{step,label}]}, timeline, documents:[…], goLiveBlockers:[{step,label}] }`.
`listing` = the camelCased row + `entityType`, `status` (= listingStatus), and: trainer `verifiedBadge`; clinic `opdHoursLabel`;
chemist `openHoursLabel`; store `fssaiRequired`, `productsSummary:{total,active,inStock}`. `listing` is null before the first PUT.
`missing` may hold several entries for one step (one per missing item). Steps: 1 Profile · 2 Pricing · 3 Availability · 4 Documents & bank · 5 Review & submit.
PUT is a partial save (only sent keys change); first PUT creates the row as `draft` with `listed_by = req.staffId`. Bodies:
- trainer: `name, photoUrl, bio, subtypes[physiotherapist|yoga_master|gym_trainer_gym|gym_trainer_home|sports_coach|boxing|karate|mma|dance|nutritionist], trainerTypes?, experienceYears, achievements[], languages[], trainingModes[online|home|gym], serviceArea, certifications[], specializations[], hourlyRatePaise (≥10000), packages:[{name,sessions,pricePaise}], weeklySlots:[{weekday,start,end}], maxSessionsPerDay, bufferMinutes, listingStep`
- clinic: `name, speciality, doctors:[{name,specialty?,degree?,registrationNo?,experienceYears?,photoUrl?}], address, area, city, phone, latitude, longitude, photos[≤10], facilities[], consultationFeePaise, opdHours:[{weekday,opensAt,closesAt}], slotMinutes, listingStep`
- chemist: `name, address, area, city, phone, latitude, longitude, photos[≤10], deliveryRadiusKm, discountPct (0–90), openHours:[{weekday,opensAt,closesAt}], homeDelivery, deliveryTimeEst, listingStep`
- store: `businessName, brandName, logoUrl, about, categories[supplements|activewear|gym_gear|healthy_food|wellness|accessories], gstin, dispatchDays (0–30), listingStep` (SKUs/prices/stock stay on `/partner/vendor/products`)
Required docs (pending or verified) + KYC + bank: trainer `certificate`; clinic `clinic_registration`, `doctor_registration`; chemist `drug_licence`, `gst`;
store `gst`, `trademark`, + `fssai` when categories include supplements / healthy_food. Submit: 400 `{ error, missing }` when incomplete, 409 if not in
`draft|changes_needed|rejected` (or legacy NULL). `GET /partner/listing/meta/options` → `{ trainerSubtypes, storeCategories, productCategories, weekdays }`.

**Trainer run/earn** (`/partner/trainer/*`): existing `GET /bookings`; `GET /calendar?from=&days=` → `{ from, to, maxSessionsPerDay, weeklySlots, days:[{date,weekday,sessions,freeSlots,full}] }`;
`GET /clients` → `{ clients:[{userId,name,phone,sessions,completed,lastSessionOn,nextSessionOn,totalPaise}] }`; `POST /bookings/:id/status {status:'completed'|'cancelled',note?}`;
`GET /earnings?from=&to=` → `{ from, to, totals:{count,grossPaise,commissionPaise,netPaise}, bySource:[{source,…}], byDay:[{date,netPaise}], commissionPct }` (403 for staff).
Old `POST /partner/trainer/profile` now creates new trainers as `draft` (existing rows untouched).

**Clinic run/earn** (`/partner/clinic/*`, 404 until the clinic listing exists): `GET /appointments?date=|from=&to=&status=`; `GET /queue?date=` → `{ date, nowServing, queue, done, counts }`;
`POST /appointments` (walk-in) `{ patientName, patientPhone?, doctorName?, date?, slotTime?, feePaise?, reason? }`; `POST /appointments/:id/status { status: checked_in|in_consultation|completed|cancelled|no_show|booked, note? }`;
`GET /patients?q=`; `GET /earnings?from=&to=` (same shape as trainer + `walkIns:{count,feesPaise}`; commission only on FitKey bookings).
Appointment: `{ id, clinicId, userId, patientName, patientPhone, doctorName, apptDate, slotTime, tokenNo, feePaise, source:'fitkey'|'walk_in', status, reason, note }`.

**Chemist run/earn** (`/partner/chemist/*`): `GET /orders?status=&open=true`; `POST /orders/:id { status: accepted|packed|out_for_delivery|delivered|picked_up|rejected|cancelled, mrpPaise? (required on accept → discountPaise/amountPaise from the store's discountPct), note?, rejectReason? }`;
`GET /earnings?from=&to=`. Order: `{ id, items:[{name,qty,note}], prescriptionUrl, fulfilment:'delivery'|'pickup', address, phone, status, mrpPaise, discountPaise, amountPaise, memberName, … }`.

**Store seller** (`/partner/vendor/*`): products gain `lowStock`, `hiddenReason` (`unlisted|store_not_live|fssai_pending|out_of_stock|null`), `lowStockThreshold`, `sku`; categories now
`supplements|apparel|wearables|gear|activewear|gym_gear|healthy_food|wellness|accessories`; selling price must be ≤ MRP. `GET /low-stock`; `GET /returns?status=`; `POST /returns/:itemId { status: approved|rejected|received|refunded, note? }` (received restocks);
`GET /earnings?from=&to=`; `GET /commissions` keeps its shape but now uses the founding-partner rate (commission.js) instead of `commission_rate`. Vendor order items include `id`, `productId`, `returnStatus`. Low-stock notification to the vendor after each order.

**Member side**: `/healthstop/clinics|chemists` list only `listing_status IS NULL OR 'live'`, rows gain `bookable` / `orderable`; `GET /healthstop/clinics/:id`, `GET /healthstop/chemists/:id`,
`GET /healthstop/clinics/:id/slots?date=` → `{ date, slotMinutes, slots:[{time,available}] }`, `POST /healthstop/clinics/:id/appointments { date, slotTime, doctorName?, patientName?, reason? }`,
`GET /healthstop/appointments/me`, `POST /healthstop/appointments/:id/cancel`, `POST /healthstop/chemists/:id/orders { items:[{name,qty,note?}], prescriptionUrl?, fulfilment, address?:{addressLine,city?,pincode?}, phone?, note? }`,
`GET /healthstop/chemist-orders/me`, `POST /healthstop/chemist-orders/:id/cancel`. Trainers: members see legacy verified or `live` partner trainers only; `verificationStatus` is
`verified` for partner trainers only once `certificatesVerifiedAt` is set; new `verifiedBadge`; `GET /trainers/:id` adds `slotsByDate` from weekly slots; booking respects modes and max sessions/day.
`POST /marketplace/orders/:id/items/:itemId/return { reason }` (delivered orders). Store products of non-live vendors and supplements / healthy_food without vendor FSSAI verification are hidden and not orderable.

## Changes by backend-listing

Additive only — nothing above was renamed or removed.

- **Me payload**: `GET /me`, `PATCH /me`, `PUT /partner/profile` and `POST /auth/otp/verify` return `partnerType`, `isFitkeyStaff`, `partnerGoLiveAt` (and `/me` + `/partner/profile` also `actingStaff`). E-mail inputs are trimmed, lower-cased, zero-width chars dropped; `''` = "not provided" (no 400).
- **Venue POST** now only requires `name` + `categories` (address / city optional so the wizard can save a draft early; step 3 of the checklist covers them). Nullable fields (`description, area, latitude, longitude, opensAt, closesAt, contactPhone, contactEmail, videoUrl, monthlyFeePaise, passSlotCap`) accept `null` on PUT to clear. `description: ''` clears; 1–39 chars → 400.
- When `hours` is sent and `opensAt/closesAt/openDays` are not, the legacy columns are derived from it (earliest open / latest close of `kind:'open'` rows; days = any row) so old booking/check-in code keeps working.
- `closures` on PUT/POST replaces **upcoming** closures only (past ones are history). `passBlocks[].days` defaults to all 7 days.
- Venue JSON (GET by id, and also the POST/PUT responses) additionally has `listedByName`, `passConsentAt`; `checklist.missing[]` items carry `hint` (what to do) besides `{step,label}`. Venue list (`GET /partner/venues`) gains `sports, listingStep, submittedAt, adminApprovedAt, partnerAcceptedAt, goLiveAt, listedBy`.
- Submit 400 body: `{ error, missing:[{step,label,hint}] }` (sent directly, not via `details`). Successful submit sets `listing_step = 10`.
- Checklist rules (utils/partner_rules.js `venueChecklist`): 1 category (+ ≥1 sport if `sports_club`) · 2 name + description ≥ 40 · 3 address + city + lat/lng · 4 hours (venue_hours rows or legacy opens/closes) and, when `fitkeyPassMode='blocked'`, ≥1 pass block · 5 ≥ 4 photos · 6 ≥1 amenity or equipment · 7 active non-rejected plan + monthlyFeePaise + passAccepted · 8 slotMinutes + slotCapacity · 9 licence doc (not rejected) + KYC (not rejected) + primary bank (pending/verified) · 10 status beyond draft/changes_needed/rejected.
- Exports for other agents: `routes/partner.js` → `venueDetail(venueRow)`, `checklistForVenue(venueRow)` (e.g. for `/partner/home`); `routes/partner_listing.js` → `listingsUnionSql()`, `loadListingMeta()`, `assertOwnListing()`, `assertListingAccess()`; `routes/admin_listings.js` → `reviewListing(entityType, id, action, {note, fixes, actorId})`.
- **Assisted listing**: `req.staffId` (null for normal tokens) and `req.staffName` are set by `requireAuth`. **backend-types: set `listed_by = req.staffId` when creating trainer/clinic/chemist/store listings.** Act-as tokens expire after 12 h. Global 403 for act-as tokens (no route changes needed): `/partner/earnings*`, `/partner/payouts*`, `/partner/statement(s)*`, `/partner/venues/:id/members*`, `/partner/bank/full`, `/partner/vendor/commissions`, `/memberships/partner/{earnings,statement}`, `/memberships/partner/venues/:id/{members,fitkey-visitors}`, `/bookings/partner/venues/:id/visits`, `/partner/staff/*`; and every request once the partner has any live listing (or the employee lost `is_fitkey_staff` → 401). Route-level helpers: `forbidStaffActing`, `requireStaff` in middleware/auth.js. `GET /partner/bank` stays allowed for staff (it only ever returns last 4).
- `POST /partner/staff/partners` → 201 (new) / 200 (existing) `{ partner:{…, isNew}, actAsToken }`; 403 if the phone is a staff account or the partner is already live. `GET /partner/staff/listings` items also have `partnerId, submittedAt, adminApprovedAt, partnerAcceptedAt, goLiveAt`.
- Timeline endpoint is also readable by the employee who listed it (own token).
- Agreement: `POST /partner/agreement/otp` → `{ sent, expiresInSeconds, devOtp? }` (409 if already accepted). OTP is bound to the listing (hash includes entityType + entityId). `accept` → `{ agreement:{id,entityType,entityId,version,terms,acceptedAt}, listing:{entityType,entityId,name,status,partnerAcceptedAt,adminApprovedAt,goLiveAt} }`. Owner may accept before or after admin approval; whichever is last flips to live.
- `GET /partner/pending-acceptance` items also have `adminApprovedAt`.
- Bank: account number 9–18 digits; IFSC normalised to upper case; `bankName` derived from the IFSC prefix. Penny-drop mocked unless `PENNY_DROP_MODE=live` (then status `pending` until admin/provider verifies). KYC mocked unless `KYC_MODE=live`. `aadhaarLast4` may be `"1234"` or `"XXXX-XXXX-1234"`; anything with ≥ 8 digits → 400.
- **Admin** (mounted inside routes/admin.js): `GET /admin/listings` default = submitted + under_review, `status=all` for everything, optional `q` (name / owner phone); rows include `docsTotal, docsPending, docsVerified, kycStatus, bankStatus, ownerName, ownerPhone, partnerType, listedByName`. `GET /admin/listings/:entityType/:id` → `{ entityType, listing (venue = full venueDetail), owner, listedBy, documents, kyc, bank, agreements, timeline }`. Review: `changes_needed` needs `fixes` or `note`; `reject` needs `note`. Approve when the owner already accepted → `approved` event then `live`. `POST /admin/partner-documents/:id` also accepts `pending` and calls `onDocumentVerified(doc)` (utils/partner_types.js) after every status change. Approve is refused with 400 `{ error, details: goLiveBlockers(...) }` when `goLiveBlockers(entityType, row)` is non-empty (also for the legacy venue PATCH); `GET /admin/listings/:entityType/:id` returns `goLiveBlockers`. `POST /admin/partner-bank/:id` `{ status, verifiedName? }`. `PUT /admin/users/:id/staff` only for role `partner`. `GET /admin/staff-report` → `{ staff:[{id,name,phone,isFitkeyStaff,listingsCreated,inReview,approved,live,lastListingAt}] }`.
- Legacy `PATCH /admin/venues/:id/status` now accepts `under_review|live|approved|changes_needed|rejected` and routes through `reviewListing` (`live` = approve → `approved` until the owner accepts). Already-live venues are untouched. `GET /admin/venues?status=` accepts every listing status.
- Bug fixed in utils/listing.js `setListingStatus`: the `"__owner"`/`"__name"` aliases were camel-cased by the db layer to `_Owner`/`_Name`, so owners were never notified and the aliases leaked into the returned row. Renamed to `zz_listing_owner`/`zz_listing_name`.
- **Open item (not owned by backend-listing)**: `POST /uploads` (routes/files.js) rejects PDFs — add `'application/pdf'` to `ALLOWED` (and a size cap) so licence/GST PDFs can be uploaded as the contract promises.

## Changes by backend-money

Files: `routes/bookings.js`, `routes/checkins.js`, `routes/memberships.js`, `routes/venues.js`, new `routes/partner_rse.js`
(mounted at `/partner` **before** routes/partner.js, per-route `requireAuth('partner')`), new `routes/admin_payouts.js`
(mounted at `/admin/payouts` before routes/admin.js), new `utils/slots.js` (pure timing rules), new `utils/partner_money.js`
(pure helpers), new `utils/renewals.js` (`startMoneyJobs()` from index.js; skipped when `NODE_ENV=test` / under `node --test`),
migration `212_money_run.sql` (`visit_payouts.payout_id`, `direct_memberships.payout_id`, `checkins.scanned_by`, one-booking-per-day
unique index now ignores `rejected`). Tests: `utils/slots.test.js`, `utils/partner_money.test.js`.

**Access-rule errors** are 409 `{ error, code, details? }`, `code` ∈ `PASS_BLOCKED | VENUE_CLOSED | PASS_SLOT_FULL`
(bookings, member check-in, partner member-QR scan).

**Timing rules** (utils/slots.js):
- Hours: `venue_hours` rows (several a day = split shift, each shift starts its own slot grid of `slotMinutes`); a weekday with no rows is
  closed once the venue has any rows; with no rows at all the old `opens_at/closes_at/open_days` apply (default 06:00–22:00, Mon–Sat).
  `ladies_only` rows count as open time; slots overlapping them get `ladiesOnly: true` (flag only — not enforced, users have no gender).
- Pass blocks apply only when `fitkeyPassMode = 'blocked'`; `'all'` = FitKey pass valid at all open hours (rows ignored, no labels).
  Overlap is half-open: a 17:00–18:00 slot is NOT blocked by an 18:00–20:00 block; a walk-in at 19:59 is, at 20:00 is not.
- Capacity per slot = `slotCapacity × courts`; pass cap per slot = `passSlotCap` (null = capacity). Counted statuses: requested, booked, attended.
- Walk-in check-in (no booking for today): closure / outside hours → `VENUE_CLOSED` (30-min early grace before each shift);
  FitKey-pass admission (legacy pass, coins, session) inside a block → `PASS_BLOCKED`. Direct-membership members skip pass blocks;
  event registrants are still admitted during a block. A check-in backed by today's booking skips these checks (validated at booking).

**Member** (user app):
- `GET /venues/:id` → `venue` gains `sports, videoUrl, slotMinutes, fitkeyPassMode, passAccepted, autoAcceptBookings,
  hours:[{weekday,opensAt,closesAt,kind}], passBlocks:[{id,days,startsAt,endsAt,note}] ([] when mode 'all'),
  passBlockLabels:["FitKey pass not valid 6–8 PM (Mon–Fri)"], closures:[{id,closedOn,slotStart,slotEnd,note}] (today … +30 d),
  ladiesOnlyLabels:["Ladies only 7–9 AM (Mon–Sat)"]`.
- `GET /bookings/venues/:venueId/slots?date=` → existing fields plus `slotMinutes, closedNote, passBlockLabels, ladiesOnlyLabels,
  requiresApproval` and `days[].closedNote`; each slot `{ start, end, capacity, booked, left, past, available, blocked, passBlocked,
  passFull, ladiesOnly, reason: null|'past'|'closed'|'full'|'pass_blocked'|'pass_full' }` (pass reasons only when the member would
  pay with the FitKey pass — a usable direct membership ignores them). `GET /bookings/venues/:venueId/access` gains `passBlockLabels`.
- `POST /bookings` → `booking.status` is `'requested'` when the venue has `autoAcceptBookings=false` (+ `booking.message`, `ladiesOnly`).
  **Decision: the visit is charged when requested (a hold)** and refunded in full on reject, on member withdrawal
  (`POST /bookings/:id/cancel` — always free for requests) or automatically if still undecided at the slot start (job every 15 min,
  and on `GET …/booking-requests`). The member is notified on accept (`booking_accepted`) and reject/expiry (`booking_rejected`).
  `GET /bookings/me` upcoming includes requests; bookings carry `decidedAt, rejectReason`. Checking in at the desk with a
  pending request admits on it (marks attended).
- `GET /checkins/member-qr` → `{ qr: 'FITKEYMEMBER:<jwt>', expiresAt, ttlSeconds: 300 }`. jwt claims `{ mqr: userId, typ: 'member_qr' }`,
  5-min TTL, signed with HMAC-SHA256(JWT_SECRET, 'fitkey-member-qr') (derived from the app JWT secret so it can never act as an access
  token). The user app renders `qr` as a QR code and refreshes it before `expiresAt`.

**Partner** (all `/partner/...`, partner token):
- `GET /home` as §F, plus `setupVenue` (first non-live venue) and `checklist` (from routes/partner.js `checklistForVenue`).
  `today.pendingRequests` = undecided requests from today on; `renewalsDue` = manual + direct renewals in the next 7 days.
- `GET /venues/:id/members?source=&status=&q=` → `{ venueId, today, counts:{total,active,expiring,expired,bySource}, members }`.
  Rows as §F plus: direct → `membershipId`; fitkey_pass → `visits, lastVisitOn`, `pricePaise` = your net from their visits in the last
  30 days, `earningPerDayPaise` = that ÷ 30; manual → `remindMember, notes`. `renewalOn` of a direct membership = its `ends_on`.
  Status: expired when `renewalOn` < today, expiring when ≤ 7 days away, active otherwise / when no renewal date. Direct memberships that
  ended > 90 days ago are left out. Phones: FitKey users masked `98XXXXXX21`; manual rows shown as entered.
  `POST` body adds optional `notes`; `remindMember` needs `phone`; `renewalOn ≥ joinedOn`. `PUT` = partial. `DELETE` archives → 204.
- `GET /venues/:id/slot-board?date=` → §F fields plus `requested`, `closureNote` per slot and `open, closedNote, passBlockLabels,
  ladiesOnlyLabels, autoAcceptBookings` at the top. `available` = capacity − booked (0 when blocked).
- `GET /venues/:id/booking-requests` → `{ autoAcceptBookings, requests:[{ id, venueId, slotDate, slotStart, slotEnd, status, paidVia,
  costLabel, createdAt, memberName, memberPhone (masked), membershipName }] }`.
  `POST /bookings/:id/accept` / `POST /bookings/:id/reject {reason?}` → `{ booking }`; 409 when not `requested` (or accept after the slot ended).
- **New:** `PUT /venues/:id/booking-settings { autoAcceptBookings }` → `{ venueId, autoAcceptBookings, pendingRequests }`
  (switching it on does not auto-accept requests already waiting).
- Closures: **new** `GET /venues/:id/closures` (upcoming); `POST /venues/:id/closures` → 201 `{ closure, affectedBookings }` (existing
  bookings in that time are NOT cancelled — the partner handles them); `DELETE /venues/:id/closures/:closureId` → 204.
- **New:** `POST /venues/:id/checkin/scan { code }` (venue must be live) → 201 `{ checkin, member:{ name, phone (masked) } }`. Same flow as
  `POST /checkins` (booking → membership → legacy pass → event → coins/session walk-in, visit_payouts, PASS_BLOCKED / VENUE_CLOSED,
  402 when the member can't pay, 409 when already checked in today). Stored with `method 'qr'` and `checkins.scanned_by`.
- `GET /earnings?from=&to=&venueId=` (default: month to date) → §F plus `from, to`; bySource always lists all five sources.
  fitkey_pass by visit date; fitkey_direct by purchase date (net = `partner_net_paise`, legacy rows = amount − commission);
  self/fitpass/other = manual `price_paise` on `joined_on` (manual rows tagged fitkey_* are notes and never counted).
- `GET /earnings/visits?date=&venueId=` → `{ date, visits:[{ checkinId, memberName, venueName, time, paidVia, grossPaise, commissionPct,
  commissionPaise, netPaise }], totals }`.
- `GET /payouts` → §F plus `unsettledPaise` (earned, not yet in a payout) and `bankStatus`. `nextPayoutOn` = next Monday after today.
  `GET /payouts/:id/statement.csv` (UTF-8 BOM, one line per visit / sale + total). `GET /payouts/:id/invoice` → printable HTML
  "Tax invoice & payout statement" (partner GSTIN from a `gst` document's `docNumber` when present).

**Payout maths at the source**: FitKey-pass check-ins write `visit_payouts.gross_paise/commission_pct/commission_paise/amount_paise(net)`
with `passVisitPayout(monthlyFeePaise, owner.partner_go_live_at, check-in time)`; without `monthlyFeePaise` the old flat rate
(`visit_payout_paise` or coin cost) with 0% commission. Direct plan sales write `gst_paise, commission_pct, commission_paise,
partner_net_paise` with `directSalePayout(amount paid, go-live, now)` for **every** venue (the old per-category 15% rule is retired;
`GET /memberships/partner/venues/:id/plans` `commissionPct` now shows the founding-partner rate). `/memberships/partner/earnings` and
`/statement` use the partner net and add `gstPaise`.

**Centre plans**: `duration` ∈ `hourly | day | weekly | monthly | quarterly | yearly | annual` (days 1/1/7/30/90/365/365).
`hourly` = a single 1-hour visit pass: duration_days 1 and forced `maxVisitsPerDay = maxVisitsPerWeek = 1` (plan and bought membership).

**Renewal alerts** (`utils/renewals.js`, every 6 h, deduped by `partner_member_alerts`): partner notified (`member_renewal`) 7 d and 1 d
before a manual member's `renewal_on` and before a direct membership's `ends_on` (skipped for hourly/day plans and when the member has
already bought a later membership there). Manual members with `remindMember` + phone get `sendSms`; direct members get an in-app
`membership_renewal` notification.

**Admin** (`/admin/payouts`, admin token):
- `GET /admin/payouts?status=&ownerId=` → `{ schedule:'weekly', nextPayoutOn, suggestedPeriod:{periodStart,periodEnd} (last full Mon–Sun),
  unsettled:{ visitNetPaise, directNetPaise }, payouts:[{ id, ownerId, ownerName, ownerPhone, periodStart, periodEnd, grossPaise,
  commissionPaise, gstPaise, netPaise, status, utr, paidAt, createdAt, bankAccountId, bankLast4, bankIfsc, bankStatus }] }`.
- `POST /admin/payouts/run { periodStart?, periodEnd? }` (default last full week; periodEnd must be before today) → 201
  `{ periodStart, periodEnd, created:[payout], skipped }`. One payout per owner from unsettled visit_payouts (by visit_date) +
  direct_memberships (by purchase date, not cancelled); those rows get `payout_id` so a later run never pays them twice. Owner without a
  VERIFIED primary bank account → status `on_hold` (partner notified to verify); else `scheduled`. Re-running the same period is skipped.
- `POST /admin/payouts/:id { status, utr? }` — `scheduled|processing|paid` need a verified bank account (409 otherwise; it is
  re-linked); `paid` needs a UTR; a paid payout can't be moved back. Partner notified (`payout_paid`) when it becomes paid.
