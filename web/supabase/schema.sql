create table if not exists public.taskboard_snapshots (
  owner_id uuid not null references auth.users(id) on delete cascade,
  id text not null default 'primary',
  payload jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);

create or replace function public.set_taskboard_snapshot_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = clock_timestamp();
  return new;
end;
$$;

drop trigger if exists taskboard_snapshot_updated_at on public.taskboard_snapshots;
create trigger taskboard_snapshot_updated_at
before insert or update on public.taskboard_snapshots
for each row execute function public.set_taskboard_snapshot_updated_at();

alter table public.taskboard_snapshots enable row level security;

create policy "Users can read their own taskboard"
on public.taskboard_snapshots for select
to authenticated
using ((select auth.uid()) = owner_id);

create policy "Users can create their own taskboard"
on public.taskboard_snapshots for insert
to authenticated
with check ((select auth.uid()) = owner_id);

create policy "Users can update their own taskboard"
on public.taskboard_snapshots for update
to authenticated
using ((select auth.uid()) = owner_id)
with check ((select auth.uid()) = owner_id);

alter publication supabase_realtime add table public.taskboard_snapshots;
