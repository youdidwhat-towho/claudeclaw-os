# Add Migration

ClaudeClaw schema migrations are idempotent runtime checks, not file-based version bumps.

## Where to add

Open `src/db.ts` and find `runMigrations()` (currently around line 407). It runs on every boot,
right after `createSchema()`. Add a new block at the bottom that:

1. Sniffs the current state via `PRAGMA table_info(<table>)` (or row count, or any
   idempotent test).
2. Skips if the migration is already applied.
3. Executes the change inside a single `database.exec(...)` call.
4. Logs the migration with `logger.info('Migration: <description>')` so the boot
   trail shows what ran on each agent process.

## Pattern

```ts
// Brief comment naming the audit finding ID if applicable, the rationale, and
// any data-loss risk so a future reader can audit the choice.
const cols = database.prepare(`PRAGMA table_info(<table>)`).all() as Array<{ name: string; type: string }>;
const targetCol = cols.find((c) => c.name === '<column>');
if (targetCol && /* condition */) {
  database.exec(`
    -- migration SQL here
  `);
  logger.info('Migration: <what changed and why>');
}
```

For column adds, use the existing `ALTER TABLE … ADD COLUMN` pattern (search the
file for examples).

For type changes on an empty/low-volume table, use `DROP TABLE` + recreate. Check
row count first if you want to refuse the drop on a populated table.

For destructive migrations on populated tables, use the `<table>_new` rename
dance (see the `mission_tasks` block in `runMigrations` for an example).

## What this skill used to do

Before 2026-04-26, this skill wrote to `migrations/version.json` and a
`migrations/<version>/<filename>.ts` registry that was never executed by the
running code. That subsystem was removed (M-1 audit fix). All schema mutations
now live in `runMigrations()` and run on every boot.

## Verify

After adding a migration:
1. `npm run build` — TypeScript clean.
2. Bounce one daemon (`launchctl kickstart -k gui/$UID/com.claudeclaw.main`).
3. Tail the log and confirm your `Migration:` line appears once.
4. Run `scripts/audit-agent-health.sh` to confirm no post-migration errors.
