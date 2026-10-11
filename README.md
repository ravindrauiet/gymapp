# FITKEY — Phase 1

*Your Key to Fitness Everywhere.*

```
gym app/
├── backend/                 Express + Postgres (Neon) API — one backend for everything
│   └── public/admin/        FITKEY team web panel (served at http://localhost:4000/admin)
├── packages/fitkey_core/    Shared Flutter code: API client, theme, formatting, common widgets
├── user_app/                Flutter member app      — FITKEY
└── partner_app/             Flutter venue-owner app — FITKEY Partner
```

## How the pieces connect

```
 FITKEY Partner app ──┐                        ┌── FITKEY member app
  list venue, photos  │                        │   explore, buy plan, scan QR
  show QR / OTP       ├──►  Express API  ◄─────┤   buddy, contests, reports
  attendance          │     (/api/v1)          │
                      │         │              │
 Admin web panel ─────┘         ▼              │
  approve listings          Neon Postgres ◄────┘
  plans, videos, contests
```

1. A **partner** lists a venue, uploads 4–5 photos and submits it. The listing status is `submitted`.
2. The **FITKEY team** opens `/admin`, reviews the listing and approves it. The status moves to `under_review`, then `live`.
3. **Members** see live venues in Explore, buy a plan that covers the venue's category, then scan the QR shown in the partner app.
4. The **partner** sees the check-in immediately, in the live feed on the QR screen and in the attendance dashboard.

## 1. Backend

1. Create a project at https://console.neon.tech and copy the **pooled** connection string.
2. Configure and run:

```bash
cd backend
cp .env.example .env          # fill in DATABASE_URL + the three secrets
npm install
npm run migrate               # creates all tables (safe to re-run)
npm run seed                  # demo plans, 7 Bengaluru venues, videos, contests, admin account
npm run dev                   # API: http://localhost:4000/api/v1   Admin: http://localhost:4000/admin
```

Generate a secret with `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"`.

### One backend, three roles

Every account is a row in `users` with `role` = `user` | `partner` | `admin`. All three clients use the same
`/auth/otp/*` login and send their role. One phone number can be both a member and a partner.

| Area | Endpoints | Used by |
|---|---|---|
| Auth / profile | `POST /auth/otp/request`, `POST /auth/otp/verify`, `GET/PATCH /me`, `GET /meta` | all |
| Photos | `POST /uploads` (multipart `file`, partner/admin) → `/api/v1/files/:id`, `GET /files/:id` | partner, both apps display |
| Plans (U2) | `GET /plans`, `GET /plans/:id/venues`, `GET /subscriptions/me`, `POST /subscriptions` | member |
| Venues (U3) | `GET /venues?category&city&q&lat&lng&radiusKm`, `GET /venues/:id` | member |
| Check-in (U4) | `POST /checkins` `{qr}` or `{venueId, otp}`, `GET /checkins/me` | member |
| Studio (U5) | `GET /videos/categories`, `GET /videos?category` | member |
| Gym buddy (U6) | `/buddy/posts`, `/buddy/posts/:id/matches`, `/buddy/requests`, `/buddy/requests/:id/messages`, `/buddy/block`, `/buddy/report` | member |
| Contests (U7) | `GET /contests?status`, `GET /contests/:id`, `POST /contests/:id/join` | member |
| Leaderboard (U8) | `GET /leaderboard?period=weekly|monthly&city` | member |
| Health (U9) | `/health/weights`, `/health/activities`, `GET /health/report?days` | member |
| Listing (P2–P5, P8) | `GET/POST /partner/venues`, `GET/PUT/DELETE /partner/venues/:id`, `POST /partner/venues/:id/submit` | partner |
| Check-in code (P6) | `GET /partner/venues/:id/checkin-code` → rotating QR + 6-digit OTP (5 min) | partner |
| Attendance (P7) | `GET /partner/venues/:id/attendance?date`, `.../attendance/summary?month` | partner |
| FITKEY team | `/admin/stats`, `/admin/venues` (+ `PATCH :id/status`), `/admin/plans`, `/admin/videos`, `/admin/contests`, `/admin/reports` | admin panel |

### How check-in works
The partner app shows a QR code (`FITKEY:<signed token>`) plus a 6-digit OTP, and refreshes both every 5 minutes.
The member scans the QR or types the OTP. The API then checks three things:
- the venue is live
- the member has an active plan that covers one of the venue's categories (if not, it returns `402`)
- the member hasn't already checked in at that venue today (if they have, it returns `409`)

### Photos
Uploaded photos are stored in Postgres (the `files` table), so Phase 1 needs no S3 or Cloudinary account. The API
returns a relative path (`/api/v1/files/<id>`), and each app adds whichever server address that device uses
(`resolveMediaUrl` in `fitkey_core`). That way a photo uploaded from an emulator still shows on a real phone. If photo
volume grows, move the files to object storage. Neither app needs to change.

### Things that are stubbed for Phase 1
- **SMS:** OTPs are printed to the server console. With `EXPOSE_DEV_OTP=true` they are also returned to the apps and the admin panel, which show a "Dev OTP" chip. Connect MSG91 or Twilio in `src/utils/sms.js`.
- **Payments:** `PAYMENTS_MODE=mock` activates plans instantly. Replace this with a Razorpay order and webhook in `src/routes/plans.js`.
- **Chat:** the app polls every 4 seconds. Move to websockets or FCM later.

## 2. Admin panel (FITKEY team)

Open http://localhost:4000/admin and sign in with the `ADMIN_PHONE` from `.env`. The dev OTP is shown on screen.
- **Dashboard:** members, partners, live and pending venues, active subscriptions, this month's revenue, today's check-ins.
- **Venues:** filter by status, see photos, map location, facilities and owner contact, then start review, approve or reject (with a note the partner sees).
- **Plans / Studio videos / Contests:** create and edit the content the member app shows.
- **Reports:** gym-buddy safety reports.

## 3. Apps

Both apps depend on `packages/fitkey_core` through a path dependency, so run `flutter pub get` in each app.

```bash
cd user_app      # or partner_app
flutter pub get
flutter run                                                           # Android emulator → 10.0.2.2:4000
flutter run --dart-define=API_URL=http://192.168.1.10:4000/api/v1    # real phone on the same Wi-Fi
```

Demo login: enter any 10-digit number and tap the "Dev OTP" chip. Seeded partner: `0000000001`, which owns the 7 demo venues.

### Member app (FITKEY)
| Tab | Screens |
|---|---|
| Home | membership card, quick actions, weekly stats, live contests, nearby venues |
| Explore | search, category chips, city filter → venue detail (photos, timings, facilities, plans, directions) |
| Check in (FAB) | QR scanner with OTP fallback → success screen |
| Studio | category grid → video list → player |
| Community | Gym buddy (plan → matches → request → chat, block/report), Contests, Leaderboard |
| Me | profile, plans & payments, progress report, attendance history, activity log |

### Partner app (FITKEY Partner)
| BRD | Screen |
|---|---|
| P1 | Phone OTP login → owner name + business email |
| P2–P5 | 6-step listing wizard: categories (multi-select) → name, description, contact → address, area, city, GPS pin → opening hours and days → 4–5 photos (gallery/camera, cover photo) → trainer, amenities, equipment |
| P6 | Front-desk screen: large QR, OTP fallback, 5-minute auto-refresh, live "just checked in" feed |
| P7 | Attendance: daily member list (name, last 4 digits, plan, QR/OTP), monthly totals, unique members, per-day chart |
| P8 | Status pill and timeline Submitted → Under review → Live, with the review note if changes are needed; edit and resubmit |
| — | Dashboard across all venues: today, this month, live count; quick "Show QR" |

## Open BRD questions reflected in code
- **Plan tiers:** seeded as separate Gym, Sports and Combat plans plus an All Access plan. Change them in the admin panel.
- **Check-in method:** QR with an OTP fallback is implemented.
- **Buddy safety:** block and report are implemented, and reports appear in the admin panel. Profile verification and women-only matching are still to decide.
- **Refund (30%) and partner payout:** not implemented yet, because the rules are still undefined. The attendance data needed for per-check-in payouts is already recorded.
- **Launch city:** the seed data uses Bengaluru.
