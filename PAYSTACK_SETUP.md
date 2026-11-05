# Switching on Paystack payments (do this in TEST mode first)

1. Create a Paystack account at paystack.com. Stay in **Test mode** (the toggle at the top of the Paystack dashboard).
2. In Paystack open **Settings > API Keys & Webhooks** and copy the **Test Secret Key** (starts with `sk_test_`).
   Never put this key in GitHub or in any web page.
3. In Supabase run `supabase/phase19.sql` in the SQL Editor.
4. In Supabase open **Edge Functions > Secrets** and add two secrets:
   - `PAYSTACK_SECRET_KEY` = your test secret key
   - `SITE_URL` = `https://taskbridj.onrender.com`
5. In Supabase open **Edge Functions**, create a new function named exactly `paystack`, paste the code from
   `supabase/functions/paystack/index.ts`, **turn OFF "Verify JWT"** for this function (the code checks the login itself),
   and deploy.
6. In Paystack **Settings > API Keys & Webhooks**, set the **Test Webhook URL** to
   `https://YOUR-PROJECT-REF.supabase.co/functions/v1/paystack?action=webhook` and save.
7. Upload the new `business.html`. As a business, open a project that is not yet funded and tap **Pay now**.
8. Pay with Paystack's test card details (shown in Paystack's test-mode documentation). The project should show **Funded**.

Going live later means: Paystack business verification, then swapping in the **Live** secret key and live webhook URL.
Withdrawals are still paid by hand from the admin Withdrawals tab. Automatic payouts are a separate step.
