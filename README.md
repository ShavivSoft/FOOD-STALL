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
- [x] GitHub Pages turned on (Settings → Pages → `main` / root)
- [x] Supabase publishable key (`sb_publishable_…`) added to `config.js`
- [x] `supabase/setup.sql` run in the Supabase SQL Editor
- [x] Admin user created and email added to `admins` (STEP 2 in setup.sql)
- [ ] Push notifications: `update-push-and-closed.sql` run + `notify-ready` function deployed (Verify JWT off)

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

### 3. Push notifications (alerts the customer's phone even after they close the page)
1. Go to **SQL Editor** and run [`supabase/update-push-and-closed.sql`](supabase/update-push-and-closed.sql). Fresh installs already have this in `setup.sql`.
2. Go to **Edge Functions → Deploy a new function → Via Editor**. Name it **`notify-ready`**, paste [`supabase/functions/notify-ready/index.ts`](supabase/functions/notify-ready/index.ts), and deploy.
3. Open the function's **Details / Settings** and turn **Verify JWT OFF**. The function checks the admin login itself.
4. Open the admin page. The top bar should say **🔔 Push on**. There are no secrets to paste: the push key pair is created inside Supabase the first time.

### 4. GitHub Pages
Go to repo **Settings → Pages → Source: Deploy from a branch → `main` / root**.

## Using it
- Open `admin.html` and log in. Use **QR code → Print** to make the poster for the counter.
- **🟢 OPEN / 🔴 WE'RE CLOSED** (top bar) switches the customer page to a big "We're closed" screen and blocks new orders. Phones that already have the page open switch within ~15 seconds. **Settings** changes names and prices; new prices only apply to new orders.
- **🍔 Burgers sold** (first tile) counts burgers in **paid** orders for the day, split into with cheese and without. The Total orders tile shows everything ordered, including unpaid.
- Tokens restart at #1 every day (India time) and never repeat within a day. **History** shows each day's orders, burgers sold (cheese / plain) and paid revenue, plus an **All time** total.
- Tapping READY again on a ready order sends the notification again.
- **Reset day** (top bar) permanently deletes all orders for the day you're viewing and restarts tokens at #1. You have to type RESET to confirm. Use it to clear test orders.
- **Notifications:** when a customer taps **Place order**, the phone asks to allow notifications. If they allow it, tapping READY makes their phone alert them, even if they've closed the page.
  - **Android (Chrome):** works straight away.
  - **iPhone:** Apple only allows it for sites added to the Home Screen (iOS 16.4+). The page tells iPhone users to tap Share → Add to Home Screen, open **Burgers** from there and order inside it.
  - Customers who don't allow notifications still see the READY popup while the page is open.
- Free Supabase projects pause after **7 days with no activity**. If the stall has a break, open the dashboard once a week or click **Restore** in Supabase before you open.
