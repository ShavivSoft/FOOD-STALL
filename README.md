# 🍔 Chicken Burger Stall — QR ordering & token manager

The customer scans a QR code and orders **Chicken Burger with Cheese (₹120)** and/or **without cheese (₹100)**.
They get a **token number, the total to pay and the item count**. The token manager marks **PAID → PREPARING → READY → DELIVERED**.
On READY, the customer's phone shows a full-screen popup and gets a push notification.

## 🔗 Live links
| | |
|---|---|
| 🍔 Customer page (put this in the QR) | https://shavivsoft.github.io/FOOD-STALL/ |
| 🧑‍🍳 Token manager | https://shavivsoft.github.io/FOOD-STALL/admin.html |
| 🗄️ Supabase project | https://supabase.com/dashboard/project/vyfbyihamirthdftkfxg |

It's hosted on GitHub Pages (static), and the data is in Supabase (free plan).

## ✅ Setup status
- [x] Code pushed to GitHub
- [x] Supabase project URL set in `config.js`
- [ ] GitHub Pages turned on (Settings → Pages → `main` / root)
- [ ] Supabase publishable key (`sb_publishable_…`) added to `config.js`
- [ ] `supabase/setup.sql` run in the Supabase SQL Editor
- [ ] Admin user created and email added to `admins` (STEP 2 in setup.sql)
- [ ] Push notifications: `notify-ready` edge function and VAPID secrets (optional)

## One-time setup

### 1. Supabase database
1. Open Supabase → **SQL Editor** → paste all of [`supabase/setup.sql`](supabase/setup.sql) → **Run**.
2. Go to **Authentication → Users → Add user → Create new user**. Use your email and a password, and tick *Auto Confirm User*.
3. In the SQL Editor, run this with your email:
   ```sql
   insert into public.admins (email) values (lower('you@example.com')) on conflict do nothing;
   ```
4. Go to **Authentication → Sign In / Providers** and turn **off** "Allow new users to sign up".

### 2. Website config
Edit [`config.js`](config.js): `SUPABASE_URL` is already set. Put the **publishable** key (`sb_publishable_…`, from **Project Settings → API Keys**) in `SUPABASE_ANON_KEY`.
The publishable key is meant to be public. **Never** put the secret key (`sb_secret_…`) or `service_role` key here.

### 3. Push notifications (optional — the live page and popup work without this)
1. Go to **Edge Functions → Deploy a new function → Via Editor**. Name it `notify-ready`, paste [`supabase/functions/notify-ready/index.ts`](supabase/functions/notify-ready/index.ts), and deploy.
2. Go to **Edge Functions → Secrets** and add:
   - `VAPID_PUBLIC_KEY`: the same value as in `config.js`
   - `VAPID_PRIVATE_KEY`: the private key. Keep it secret and never commit it.

   To make a new key pair: `npx web-push generate-vapid-keys`. Then update both `config.js` and the secrets.

### 4. GitHub Pages
Go to repo **Settings → Pages → Source: Deploy from a branch → `main` / root**.

## Using it
- Open `admin.html` and log in. Use **QR code → Print** to make the poster for the counter.
- **Orders paused** stops new orders. **Settings** changes names and prices; new prices only apply to new orders.
- Tokens restart at #1 every day (India time) and never repeat within a day. **History** shows past days.
- Tapping READY again on a ready order sends the notification again.
- iPhone push needs iOS 16.4+ with the site added to the Home Screen. Without that, the customer keeps the page open and it updates on its own every few seconds.
- Free Supabase projects pause after **7 days with no activity**. If the stall has a break, open the dashboard once a week or click **Restore** in Supabase before you open.
