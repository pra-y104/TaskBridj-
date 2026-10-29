# TaskBridj
HTML + custom CSS + Supabase. No build step.

## Setup
1. Create a project at supabase.com. Run `supabase/schema.sql` in the SQL Editor.
2. Put your Project URL and anon key in `assets/config.js`.
3. Push this folder to GitHub, then enable GitHub Pages (Settings > Pages > main branch / root). Render static site also works.
4. In Supabase > Authentication > URL Configuration, add your site URL.
5. Make yourself admin: sign up, then run
   `update profiles set role='admin' where id=(select id from auth.users where email='YOUR_EMAIL');`

## Pages
index, signup, login, participant, business, admin. No real payment processing yet.
