# Setting up accounts, preferences and feature requests

About 20 minutes, all free. You need two things: a **Supabase** project (the database) and a
**Google sign-in client** (so people can "Sign in with Google").

## 1. Make the Supabase project

1. Go to <https://supabase.com>, sign up (GitHub sign-in is quickest), and click **New project**.
2. Name it `micflow`, set a database password (save it in your password manager), pick the region
   closest to your users (e.g. **Singapore** for Bangladesh), and keep the **Free** plan.
3. When it's ready, open **Project Settings › API** (or **Data API**) and copy:
   - the **Project URL** (looks like `https://abcdxyz.supabase.co`)
   - the **publishable** key (or the **anon public** key). It's safe to put in the app.
   Never copy the `service_role` / secret key anywhere.
4. Send me those two values, and I'll put them in `Sources/Backend.swift`.

## 2. Create the database tables

1. In Supabase, open **SQL Editor › New query**.
2. Paste everything from `Backend/schema.sql` and click **Run**.
3. Make yourself the admin: run this with your Google email:
   ```sql
   insert into public.admins (email) values ('you@gmail.com');
   ```

## 3. Turn on the sign-in options

In **Authentication › Sign In / Providers**:
1. Turn on **Allow anonymous sign-ins**. This lets people vote without signing in (one vote per Mac).
2. Open **Google** and keep this tab open for step 4.

In **Authentication › URL Configuration › Redirect URLs**, add `micflow://auth-callback`.

## 4. Make the Google sign-in client

1. Go to <https://console.cloud.google.com>, sign in, and create a project named `MicFlow`.
2. Open **APIs & Services › OAuth consent screen** (or **Google Auth Platform › Branding**):
   - App name **MicFlow**, your email as support and developer contact.
   - Audience: **External**. Leave it in **Testing** while you try it (add your own and friends'
     Gmail addresses as test users), then click **Publish app** for everyone. Basic sign-in (name,
     email, photo) needs no Google review.
3. Open **Clients › Create client** (or **Credentials › Create credentials › OAuth client ID**):
   - Application type: **Web application**, name `MicFlow Supabase`.
   - **Authorized redirect URIs**: paste the **Callback URL** shown in Supabase's Google provider
     page (looks like `https://abcdxyz.supabase.co/auth/v1/callback`).
   - Click **Create** and copy the **Client ID** and **Client secret**.
4. Back in Supabase's **Google** provider: turn it on, paste the Client ID and Client secret, and
   **Save**.

## 5. Try it

Build MicFlow, open **Settings › General › Account**, and click **Sign in with Google**.

## Good to know

- **Free plan limits:** 500 MB database, 1 GB file storage, 50,000 monthly users. A free project
  **pauses after 7 days with no activity**; open the Supabase dashboard and click **Restore**. Any
  use of the app counts as activity.
- **Removing posts:** as an admin you can delete any request or comment in **Table Editor**.
- **API keys** are stored in each user's own row; Row Level Security lets only that user read it
  back, but you (the project owner) can see it in the dashboard.
