-- YeepMate live multiplayer setup
-- Run this entire file in Supabase SQL Editor. It creates YeepMate-only tables and RPCs.

create extension if not exists pgcrypto;

create table if not exists public.yeepmate_queue (
  player_id text primary key,
  player_name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.yeepmate_matches (
  id uuid primary key default gen_random_uuid(),
  white_player_id text not null,
  black_player_id text not null,
  white_name text not null,
  black_name text not null,
  fen text not null,
  moves jsonb not null default '[]'::jsonb,
  turn_player_id text not null,
  status text not null default 'active' check (status in ('active','checkmate','draw','abandoned')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.yeepmate_queue enable row level security;
alter table public.yeepmate_matches enable row level security;

drop policy if exists "YeepMate match snapshots are readable" on public.yeepmate_matches;
create policy "YeepMate match snapshots are readable"
on public.yeepmate_matches for select to anon, authenticated using (true);

grant select on public.yeepmate_matches to anon, authenticated;
revoke all on public.yeepmate_queue from anon, authenticated;
revoke insert, update, delete on public.yeepmate_matches from anon, authenticated;

create or replace function public.yeepmate_join_queue(p_player_id text, p_player_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  waiting public.yeepmate_queue%rowtype;
  new_match public.yeepmate_matches%rowtype;
begin
  if length(coalesce(p_player_id,'')) < 8 or length(p_player_id) > 80 then
    raise exception 'Invalid player id';
  end if;
  if length(coalesce(p_player_name,'')) < 1 or length(p_player_name) > 24 then
    raise exception 'Invalid player name';
  end if;

  -- Serialize queue joins so two simultaneous players cannot miss each other.
  perform pg_advisory_xact_lock(hashtext('yeepmate_matchmaking_queue'));

  delete from public.yeepmate_queue
  where created_at < now() - interval '3 minutes';

  -- If this player was already matched, return the complete match details.
  select * into new_match
  from public.yeepmate_matches
  where status = 'active'
    and (white_player_id = p_player_id or black_player_id = p_player_id)
  order by created_at desc
  limit 1;

  if new_match.id is not null then
    if new_match.white_player_id = p_player_id then
      return jsonb_build_object(
        'state','matched',
        'match_id',new_match.id,
        'color','white',
        'opponent_id',new_match.black_player_id,
        'opponent_name',new_match.black_name,
        'white_player_id',new_match.white_player_id,
        'black_player_id',new_match.black_player_id
      );
    else
      return jsonb_build_object(
        'state','matched',
        'match_id',new_match.id,
        'color','black',
        'opponent_id',new_match.white_player_id,
        'opponent_name',new_match.white_name,
        'white_player_id',new_match.white_player_id,
        'black_player_id',new_match.black_player_id
      );
    end if;
  end if;

  -- Avoid duplicate queue entries for this player.
  delete from public.yeepmate_queue where player_id = p_player_id;

  select * into waiting
  from public.yeepmate_queue
  where player_id <> p_player_id
  order by created_at
  limit 1;

  if waiting.player_id is not null then
    delete from public.yeepmate_queue where player_id = waiting.player_id;

    insert into public.yeepmate_matches (
      white_player_id, black_player_id,
      white_name, black_name,
      fen, moves, turn_player_id
    )
    values (
      waiting.player_id, p_player_id,
      waiting.player_name, p_player_name,
      'start', '[]'::jsonb, waiting.player_id
    )
    returning * into new_match;

    return jsonb_build_object(
      'state','matched',
      'match_id',new_match.id,
      'color','black',
      'opponent_id',waiting.player_id,
      'opponent_name',waiting.player_name,
      'white_player_id',new_match.white_player_id,
      'black_player_id',new_match.black_player_id
    );
  end if;

  insert into public.yeepmate_queue(player_id, player_name)
  values (p_player_id, p_player_name);

  return jsonb_build_object('state','waiting');
end;
$$;

revoke all on function public.yeepmate_join_queue(text,text) from public;
grant execute on function public.yeepmate_join_queue(text,text) to anon, authenticated;

create or replace function public.yeepmate_leave_queue(p_player_id text)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  delete from public.yeepmate_queue where player_id = p_player_id;
  update public.yeepmate_matches set status = 'abandoned', updated_at = now()
  where status = 'active' and (white_player_id = p_player_id or black_player_id = p_player_id);
  return true;
end;
$$;

create or replace function public.yeepmate_get_match(p_match_id uuid, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare m public.yeepmate_matches%rowtype;
begin
  select * into m from public.yeepmate_matches where id = p_match_id;
  if m.id is null or (m.white_player_id <> p_player_id and m.black_player_id <> p_player_id) then raise exception 'Match not found'; end if;
  return to_jsonb(m);
end;
$$;

create or replace function public.yeepmate_submit_move(
  p_match_id uuid, p_player_id text, p_fen text, p_moves jsonb,
  p_next_player_id text, p_status text default 'active'
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare m public.yeepmate_matches%rowtype;
begin
  if p_status not in ('active','checkmate','draw') then raise exception 'Invalid match status'; end if;
  if length(coalesce(p_fen,'')) > 200 or jsonb_typeof(p_moves) <> 'array' or jsonb_array_length(p_moves) > 500 then raise exception 'Invalid move data'; end if;

  update public.yeepmate_matches
  set fen = p_fen, moves = p_moves, turn_player_id = p_next_player_id,
      status = p_status, updated_at = now()
  where id = p_match_id and status = 'active'
    and turn_player_id = p_player_id
    and p_next_player_id <> p_player_id
    and p_next_player_id in (white_player_id, black_player_id)
    and p_player_id in (white_player_id, black_player_id)
  returning * into m;

  if m.id is null then raise exception 'It is not your turn or the match has ended'; end if;
  return to_jsonb(m);
end;
$$;

revoke all on function public.yeepmate_join_queue(text,text) from public;
revoke all on function public.yeepmate_leave_queue(text) from public;
revoke all on function public.yeepmate_get_match(uuid,text) from public;
revoke all on function public.yeepmate_submit_move(uuid,text,text,jsonb,text,text) from public;
grant execute on function public.yeepmate_join_queue(text,text) to anon, authenticated;
grant execute on function public.yeepmate_leave_queue(text) to anon, authenticated;
grant execute on function public.yeepmate_get_match(uuid,text) to anon, authenticated;
grant execute on function public.yeepmate_submit_move(uuid,text,text,jsonb,text,text) to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.yeepmate_matches;
exception when duplicate_object then null;
end $$;
