# Firebase migration

This migration keeps the Mac snapshot as the source of truth and leaves the existing Supabase project untouched until Firebase has been verified.

## What Firebase needs

Use a separate Firebase project for taskboard on the Spark plan. Do not link billing.

Enable:

1. Authentication with the Email/Password provider.
2. Realtime Database in locked mode.
3. A Firebase Web app so you can copy the public client configuration.

Publish the exact rules from [`../web/firebase/database.rules.json`](../web/firebase/database.rules.json). They restrict each snapshot to its authenticated owner.

The clients need only browser-visible configuration. Do not commit project-specific values to the repository:

- Web API key
- Auth domain
- Realtime Database URL
- Project ID
- App ID

Do not download or share an Admin SDK service-account JSON file.

## Safe cutover

1. Quit taskboard on every device except the Mac being migrated.
2. Copy `~/Library/Application Support/taskboard/boards.json` somewhere safe, or export a JSON backup from the PWA.
3. In the Mac app, open **Settings → Firebase Sync** and enter the Realtime Database URL, Web API key, and new account credentials.
4. Select **Create Account** and restart the Mac app.
5. The Mac uploads its local snapshot when `taskboardSnapshots/{uid}` does not exist.
6. Configure the PWA with the five Firebase Web app values and sign in to the same account.
7. Open the PWA and confirm the board and task counts.
8. Do not make any PWA edits until that count is correct.
9. Make one harmless edit on the Mac and confirm it appears in the PWA. Undo it, then test the reverse direction.
10. Keep Supabase available for at least a day. Only then disconnect its legacy sync or pause that project.

Never connect an empty Mac profile after populating Firebase. Existing remote data wins unless the remote snapshot itself has no user content.

## Rollback

The migration does not delete Supabase data or its saved session.

1. Export the current Firebase snapshot from the PWA if it contains newer edits.
2. In **Settings → Firebase Sync**, select **Disconnect**.
3. Restart taskboard. If the legacy Supabase session still exists, the Mac resumes Supabase sync; otherwise it stays local-only.
4. Import the exported JSON if Firebase contained changes missing from Supabase.

Do not run both providers at once. Firebase takes precedence whenever its authenticated session is configured.
