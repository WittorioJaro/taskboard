# Agent access and Today planning

The agent signs in with its own Firebase Email/Password account. Your Mac and
phone keep using your owner account. No new password is needed when upgrading
an existing agent from read-only access to read/write access.

## Grants

Publish `web/firebase/database.rules.json` using a trusted Console/Admin session.
Then set the relevant Boolean grant in Realtime Database:

| Grant | Path | Access |
| --- | --- | --- |
| Reader | `agentReaders/OWNER_UID/AGENT_UID = true` | Read only `taskboardSnapshots/OWNER_UID/payload` |
| Writer | `agentWriters/OWNER_UID/AGENT_UID = true` | Read/write `taskboardSnapshots/OWNER_UID`, including `payload` and `updatedAt` |

A writer can create boards/tasks, edit tasks, plan Today, and complete tasks in
this owner's snapshot. It cannot access an ungranted owner's snapshot, manage
access grants, or delete the whole snapshot envelope. Because a writer can edit
the whole payload, this is a trusted collaborator role, not an append-only role.
Removing the writer grant revokes subsequent writes. Remove the reader grant as
well to revoke all access. Previously downloaded data cannot be recalled.

Only trusted Console/Admin sessions manage grants. Client accounts cannot grant
themselves access. Verify an unchanged conditional write with the agent's own
account and check that ungranted-owner reads/writes are denied before relying on
it. Keep the rules backup and agent credentials out of the repository.

## Agent command tool

Copy `scripts/taskboard-agent.py` to the agent's machine. It uses Python 3 and the
system CA store (`certifi` is also supported if installed). Give it a private
JSON configuration file, readable only by the service user:

```json
{
  "databaseURL": "https://YOUR-DATABASE.firebasedatabase.app",
  "apiKey": "YOUR_FIREBASE_WEB_API_KEY",
  "ownerUID": "OWNER_UID",
  "email": "AGENT_EMAIL",
  "password": "AGENT_PASSWORD"
}
```

Use the agent's existing secret manager or private credentials file. Do not put
passwords, tokens, or configuration contents in prompts, commits, command
arguments, or logs. Do not give the agent an Admin SDK service-account key or
your personal refresh token. The Web API key identifies the Firebase project;
Authentication and Security Rules authorize access.

```bash
export TASKBOARD_AGENT_CONFIG=/private/path/taskboard-agent.json
python3 taskboard-agent.py read
python3 taskboard-agent.py add-board 'New project'
python3 taskboard-agent.py add-task --board 'Project name' --title 'New task' --due 2026-11-04
python3 taskboard-agent.py deadlines
python3 taskboard-agent.py deadline TASK_UUID_1 2026-11-04
python3 taskboard-agent.py deadline TASK_UUID_1 none
python3 taskboard-agent.py --date 2026-10-31 plan TASK_UUID_1 TASK_UUID_2 TASK_UUID_3
python3 taskboard-agent.py today
python3 taskboard-agent.py unplan TASK_UUID_1
python3 taskboard-agent.py complete TASK_UUID_2
```

`plan` takes task IDs in priority order and replaces the selection for that date.
An empty list clears that date's selection. It rejects completed or duplicate
tasks. Other dates are left intact. Date defaults to today in `Europe/Warsaw`;
use `--timezone` if needed. Commands authenticate as the agent account and use
Firebase ETags to retry against fresh data if another writer changes it.

A useful instruction for the agent:

> Read all my boards and review `deadlines` first. Weigh overdue tasks, tasks due
> today, and approaching deadlines when picking a realistic set of priorities
> for today. Rank the selection. Never invent or change deadlines unless asked.
> Keep each task in its original project board. Use the taskboard-agent `plan`
> command with the selected task IDs in priority order. Create new tasks in their
> project board first, then include their IDs in the plan. Do not move or copy
> tasks into Today. Explain your selection briefly.

The CLI does not schedule runs itself. A recurring run belongs in the agent's
own scheduler; see the example below.

## Today model

Each task keeps its original board and UUID. Its optional fields are:

```json
{ "plannedFor": "2026-10-31", "todayOrder": 0 }
```

Today displays the tasks selected for the local calendar date, ordered by
`todayOrder`, with their source project labels. It uses the original task for
renaming, lane changes, completion, attachments, and T3 Code project dispatch.
The sun button on Mac and phone adds/removes a project task from Today. Drag
open Todo tasks on the Mac Today board to change their priority order.

Tasks already stored directly in the Today board remain personal captures and
stay visible until completed. New captures entered in Today work the same way.
Dated selections disappear from Today after that day; unfinished tasks remain
in their project backlog and can be selected again. Personal captures' priority
order also applies only to the date for which they were ranked.

Use the current Mac and phone clients before introducing dated plans. An older
Mac app can discard fields it does not understand when saving. The phone PWA
must be deployed separately after building the updated web client.

## Deadlines

Tasks have an optional `dueDate` in `YYYY-MM-DD` format. It represents a calendar
date, with no time or UTC conversion. A task is due through that whole local day
and becomes overdue on the next day. Missing/null means no deadline. Existing
tasks stay undated until you or the agent explicitly set a date.

Click **Set deadline** or an existing deadline on a Mac task to open the calendar;
Save applies it and Remove clears it. The phone has the same deadline controls.
Dates show as Due today, Due tomorrow, or a date, with overdue work highlighted.
Deadline edits in Today update the original project task. Setting a deadline
does not automatically select the task for Today or change its priority order.

The agent's `read` and `today` output include raw `dueDate` fields. `deadlines`
returns only open tasks with valid deadlines, earliest first, together with
`boardID`, `project`, `daysUntilDue`, and `deadlineStatus` (`overdue`, `dueToday`,
or `upcoming`). It uses the same `--date` and `--timezone` settings as planning.
`deadline TASK_UUID YYYY-MM-DD` sets a date; `deadline TASK_UUID none` removes it.
`add-task --due YYYY-MM-DD` sets a deadline at creation. Invalid dates are rejected.

Deadlines merge independently of Today selection, task titles, and completion.
Kindle adds deadline cues to selected open tasks and preserves the date when
ticking or unticking the original task. Completion never clears the deadline.

## Kindle dashboard integration

An existing local "Daily Page" Kindle dashboard runs as a macOS login service
and reads these files:

```text
~/Library/Application Support/The Daily Page/server.py
~/Library/Application Support/The Daily Page/taskboard_today.py
~/Library/Application Support/taskboard/boards.json
```

The repository's `integrations/kindle/taskboard_today.py` supplies the selection
and completion logic. The server retains its existing image, tap, tokens, and
Kindle connection. Each row exposes `name` (the task, drawn large) and `label`
(project and deadline, drawn small above it); `title` keeps the older combined
`Project · Task title` text for dashboards that have not updated. A tap changes the
original task in its home board. Completed-today tasks can still be expanded and
unticked on Kindle. The Mac notices local edits and uploads them to Firebase.
Remote agent changes reach Kindle through Firebase → Mac → local file. The Mac
must be running and syncing for that remote path to work; local Kindle edits
still work while Firebase is offline.

Install/update an existing Daily Page dashboard with:

```bash
python3 scripts/install-kindle-integration.py
python3 "$HOME/Library/Application Support/The Daily Page/manage_service.py" --restart
```

The installer backs up `server.py` before changing its task source. It does not
change existing dashboard access tokens, Kindle scripts, or launch settings.
The Mac and Kindle hold the same `boards.json.lock` advisory lock while editing,
and replace `boards.json` atomically. Keep the lock sidecar in place.

## Concurrent writers

The Mac and phone merge changes against their last synced snapshot and use
conditional writes/transactions, so edits to different fields and additions from
different writers survive. Completion state, project links, and a task's plan
are each merged as a unit. A local edit wins a conflict on the same field. The
Mac stores its sync baseline with pending uploads so queued offline edits can
be retried after restarting. On an upgrade without a saved baseline, remote
additions are preserved and shared records prefer local fields; deletions
cannot reliably be inferred without that history.

External local tools must acquire `boards.json.lock`, re-read the latest
snapshot, preserve unknown fields, and save atomically. The Mac additionally
merges external changes before saving and polls every two seconds. Writers that
ignore the locking and transaction protocols can still overwrite newer data.

## Deploying the phone app

Deploy `web/` to any static host. With Vercel, link the project from the
repository root, set install to `cd web && npm ci`, build to
`cd web && npm run build`, output to `web/dist`, and add the five
`VITE_FIREBASE_*` variables from `web/.env.example` in Production. Then:

```bash
npx vercel@latest link --yes --project taskboard
npx vercel@latest --prod --yes --archive=tgz
```

`.vercelignore` limits the upload to the web client's inputs and excludes native
builds, dependencies, and private local environment files. Close and reopen the
phone's Home Screen app to load a deployed update.

## Example: a daily planning agent

A scheduled agent (any assistant with a cron-style routine) can run
`scripts/taskboard-agent.py` with its own writer grant each morning: read all
boards and deadlines, pick a realistic 3–5 open tasks, apply them as the ordered
Today plan, and send a short summary. Keep it from creating, completing,
deleting, or re-dating tasks unless you want it to. Store its credentials in the
agent's own secret manager, never in this repository.

## References

- [Firebase rule conditions and data-based access](https://firebase.google.com/docs/database/security/rules-conditions)
- [Firebase conditional REST writes and ETags](https://firebase.google.com/docs/database/rest/save-data)
- [Firebase database REST API](https://firebase.google.com/docs/reference/rest/database)
