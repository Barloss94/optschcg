-- Jackpot schema and accounting integration. Already applied to the connected database.
create table public.cashgame_jackpot_settings (
 id integer primary key check(id=1), start_date date not null, end_date date,
 check(end_date is null or end_date>=start_date)
);
insert into public.cashgame_jackpot_settings values(1,(now() at time zone 'Europe/Amsterdam')::date,null);
create table public.cashgame_jackpot_rules (
 id uuid primary key default gen_random_uuid(), hand_name text not null check(length(btrim(hand_name)) between 1 and 100),
 requirements text not null default '' check(length(requirements)<=2000), payout_type text not null check(payout_type in ('fixed','percentage')),
 payout_value numeric(12,2) not null check(payout_value>0), active boolean not null default true,
 check(payout_type<>'percentage' or payout_value<=100)
);
create table public.cashgame_jackpot_payouts (
 id uuid primary key, session_id text not null, session_date date not null, session_code text not null,
 winner_id text not null, winner_name text not null, rule_snapshot jsonb not null,
 amount_cents bigint not null check(amount_cents>0), balance_before bigint not null,
 allocations jsonb not null, note text not null default '', created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(), cancelled_at timestamptz, cancellation_reason text
);
alter table public.cashgame_jackpot_settings enable row level security;
alter table public.cashgame_jackpot_rules enable row level security;
alter table public.cashgame_jackpot_payouts enable row level security;
revoke all on public.cashgame_jackpot_settings,public.cashgame_jackpot_rules,public.cashgame_jackpot_payouts from anon,authenticated;
grant select,update on public.cashgame_jackpot_settings to authenticated;
grant select,insert,update on public.cashgame_jackpot_rules to authenticated;
grant select on public.cashgame_jackpot_payouts to authenticated;
create policy jackpot_settings_hosts on public.cashgame_jackpot_settings to authenticated using((select public.is_cashgame_manager())) with check((select public.is_cashgame_manager()));
create policy jackpot_rules_hosts on public.cashgame_jackpot_rules to authenticated using((select public.is_cashgame_manager())) with check((select public.is_cashgame_manager()));
create policy jackpot_payouts_hosts on public.cashgame_jackpot_payouts for select to authenticated using((select public.is_cashgame_manager()));

create or replace function cashgame_private.jackpot_timestamp(p_text text) returns timestamp language plpgsql immutable set search_path='' as $$
begin return nullif(p_text,'')::timestamp; exception when others then return null; end $$;
grant usage on schema cashgame_private to authenticated;
grant execute on function cashgame_private.jackpot_timestamp(text) to authenticated;
create function public.cashgame_jackpot_contributions() returns table(session_id text,session_date date,code text,host_id text,amount_cents bigint)
language sql stable security invoker set search_path='' as $$
 with base as (
 select s.*,coalesce((select sum(round(r.tips*100)) from public.cashgame_results r where r.session_id=s.id),0) tips,
 ceil(extract(epoch from(cashgame_private.jackpot_timestamp(s.ended_at)-cashgame_private.jackpot_timestamp(s.manual_start)))/60) minutes
 from public.cashgame_sessions s cross join public.cashgame_jackpot_settings cfg
 where cfg.id=1 and s.session_date>=cfg.start_date and (cfg.end_date is null or s.session_date<=cfg.end_date) and btrim(s.host_player_id)<>''
 ), amounts as (
 select id,session_date,code,host_player_id,floor(greatest(0,tips-round((13+3*ceil(greatest(0,minutes-180)/20))*20.99/115*100))*0.20)::bigint amount
 from base where minutes>=0
 ) select id,session_date,code,host_player_id,amount from amounts where amount>0;
$$;
revoke all on function public.cashgame_jackpot_contributions() from public,anon;
grant execute on function public.cashgame_jackpot_contributions() to authenticated;

create function cashgame_private.jackpot_holdings() returns table(host_id text,available bigint) language sql stable security invoker set search_path='' as $$
 with movements as (
 select c.host_id,c.amount_cents amount from public.cashgame_jackpot_contributions() c
 union all select a->>'host_id',-(a->>'amount_cents')::bigint from public.cashgame_jackpot_payouts p cross join lateral jsonb_array_elements(p.allocations) a where p.cancelled_at is null
 ) select m.host_id,sum(amount)::bigint from movements m group by m.host_id;
$$;
revoke all on function cashgame_private.jackpot_holdings() from public,anon;
grant execute on function cashgame_private.jackpot_holdings() to authenticated;

create function cashgame_private.record_jackpot(p_id uuid,p_rule uuid,p_session text,p_winner text,p_note text,p_expected_amount bigint,p_expected_balance bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare rule public.cashgame_jackpot_rules; game public.cashgame_sessions; balance bigint; amount bigint; left_amount bigint; take_amount bigint; holder record; allocations jsonb:='[]'; winner text;
begin
 if auth.uid() is null or not public.is_cashgame_manager() then raise exception 'Geen toegang'; end if;
 perform pg_advisory_xact_lock(769423);
 if exists(select 1 from public.cashgame_jackpot_payouts where id=p_id) then return p_id; end if;
 select * into rule from public.cashgame_jackpot_rules where id=p_rule and active;
 if not found then raise exception 'Deze handregel is niet actief'; end if;
 select * into game from public.cashgame_sessions where id=p_session;
 if not found or not exists(select 1 from public.cashgame_jackpot_settings cfg where game.session_date>=cfg.start_date and (cfg.end_date is null or game.session_date<=cfg.end_date)) or game.session_date>(now() at time zone 'Europe/Amsterdam')::date then raise exception 'Kies een gespeelde sessie binnen de jackpotperiode'; end if;
 select min(first_name) into winner from public.cashgame_results where session_id=p_session and player_id=p_winner;
 if winner is null then raise exception 'Kies een deelnemer uit deze sessie'; end if;
 if length(coalesce(p_note,''))>2000 then raise exception 'Toelichting is te lang'; end if;
 select coalesce(sum(available),0) into balance from cashgame_private.jackpot_holdings();
 amount:=case when rule.payout_type='fixed' then round(rule.payout_value*100) else floor(balance*rule.payout_value/100) end;
 if amount<=0 or amount>balance then raise exception 'Onvoldoende jackpot voor deze uitbetaling'; end if;
 if balance<>p_expected_balance or amount<>p_expected_amount then raise exception 'De jackpot of handregel is gewijzigd. Vernieuw en controleer de uitbetaling opnieuw'; end if;
 left_amount:=amount;
 for holder in select * from cashgame_private.jackpot_holdings() where available>0 order by available desc,host_id collate "C" loop
  take_amount:=least(left_amount,holder.available);
  if take_amount>0 then allocations:=allocations||jsonb_build_array(jsonb_build_object('host_id',holder.host_id,'amount_cents',take_amount));left_amount:=left_amount-take_amount;end if;
  exit when left_amount=0;
 end loop;
 insert into public.cashgame_jackpot_payouts(id,session_id,session_date,session_code,winner_id,winner_name,rule_snapshot,amount_cents,balance_before,allocations,note,created_by)
 values(p_id,p_session,game.session_date,game.code,p_winner,winner,to_jsonb(rule),amount,balance,allocations,coalesce(p_note,''),auth.uid());
 return p_id;
end $$;
revoke all on function cashgame_private.record_jackpot(uuid,uuid,text,text,text,bigint,bigint) from public,anon;
grant execute on function cashgame_private.record_jackpot(uuid,uuid,text,text,text,bigint,bigint) to authenticated;
create function public.record_cashgame_jackpot(p_id uuid,p_rule uuid,p_session text,p_winner text,p_note text,p_expected_amount bigint,p_expected_balance bigint) returns uuid language sql security invoker set search_path='' as $$ select cashgame_private.record_jackpot(p_id,p_rule,p_session,p_winner,p_note,p_expected_amount,p_expected_balance) $$;
revoke all on function public.record_cashgame_jackpot(uuid,uuid,text,text,text,bigint,bigint) from public,anon;
grant execute on function public.record_cashgame_jackpot(uuid,uuid,text,text,text,bigint,bigint) to authenticated;
create function cashgame_private.cancel_jackpot(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_cashgame_manager() then raise exception 'Geen toegang'; end if;
 if length(btrim(coalesce(p_reason,'')))<3 or length(p_reason)>2000 then raise exception 'Vul de reden voor correctie in'; end if;
 perform pg_advisory_xact_lock(769423);
 update public.cashgame_jackpot_payouts set cancelled_at=now(),cancellation_reason=p_reason where id=p_id and cancelled_at is null;
end $$;
revoke all on function cashgame_private.cancel_jackpot(uuid,text) from public,anon;
grant execute on function cashgame_private.cancel_jackpot(uuid,text) to authenticated;
create function public.cancel_cashgame_jackpot(p_id uuid,p_reason text) returns void language sql security invoker set search_path='' as $$ select cashgame_private.cancel_jackpot(p_id,p_reason) $$;
revoke all on function public.cancel_cashgame_jackpot(uuid,text) from public,anon;
grant execute on function public.cancel_cashgame_jackpot(uuid,text) to authenticated;

create function cashgame_private.jackpot_lock() returns trigger language plpgsql security invoker set search_path='' as $$ begin perform pg_advisory_xact_lock(769423);return null;end $$;
create function cashgame_private.jackpot_guard() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from cashgame_private.jackpot_holdings() where available<0) then raise exception 'Deze wijziging zou al uitgekeerde jackpotpunten wegnemen. Corrigeer eerst de betreffende uitbetaling'; end if;
 if exists(select 1 from public.cashgame_jackpot_contributions() c join public.cashgame_sessions s on s.id=c.session_id where coalesce((select sum(a.percentage) from public.cashgame_rakeback_sessions l join public.cashgame_rakeback_actions a on a.id=l.action_id where l.session_id=s.id),0)>80) then raise exception 'Jackpot en bonusacties mogen samen maximaal 100 procent reserveren'; end if;
 return null;
end $$;
do $$ declare t text;begin
 foreach t in array array['cashgame_sessions','cashgame_results','cashgame_jackpot_settings','cashgame_jackpot_rules','cashgame_rakeback_actions','cashgame_rakeback_sessions'] loop
 execute format('create trigger jackpot_lock before insert or update or delete on public.%I for each statement execute function cashgame_private.jackpot_lock()',t);
 execute format('create trigger jackpot_guard after insert or update or delete on public.%I for each statement execute function cashgame_private.jackpot_guard()',t);
 end loop;
end $$;
notify pgrst,'reload schema';

CREATE OR REPLACE FUNCTION cashgame_private.month_snapshot(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare output jsonb;
begin
with sessions as(
 select s.*, coalesce((select sum(round(r.tips*100)) from public.cashgame_results r where r.session_id=s.id),0) tips,
 case when s.manual_start<>'' and s.ended_at<>'' then ceil(extract(epoch from(cashgame_private.jackpot_timestamp(s.ended_at)-cashgame_private.jackpot_timestamp(s.manual_start)))/60) end minutes
 from public.cashgame_sessions s where s.session_date>=p_month and s.session_date<(p_month+interval '1 month')
), fees as(
 select s.*,case when minutes>=0 then round((13+3*ceil(greatest(0,minutes-180)/20))*20.99/115*100) end fee from sessions s
), excluded as(
 select * from fees where (btrim(host_player_id)<>'' and btrim(partner_player_id)='' and btrim(third_player_id)='') or (fee is not null and tips=fee)
), reserved as(
 select s.*,coalesce((select sum(floor(greatest(0,s.tips-s.fee)*a.percentage/100)) from public.cashgame_rakeback_sessions l join public.cashgame_rakeback_actions a on a.id=l.action_id where l.session_id=s.id),0) reserve,coalesce((select c.amount_cents from public.cashgame_jackpot_contributions() c where c.session_id=s.id),0) jackpot
 from fees s where not exists(select 1 from excluded e where e.id=s.id)
), valid as(
 select s.*,tips-fee-reserve-jackpot remainder,case when third_player_id='' then 2 else 3 end n
 from reserved s where host_player_id<>'' and partner_player_id<>'' and fee is not null and tips<>fee and reserve+jackpot<=greatest(0,tips-fee)
), amounts as(
 select host_player_id id,tips received,fee+reserve+jackpot+floor(remainder/n) entitled from valid
 union all select partner_player_id,0,case when n=2 then remainder-floor(remainder/2) else floor(remainder/3)+case when (remainder-3*floor(remainder/3))>0 then 1 else 0 end end from valid
 union all select third_player_id,0,floor(remainder/3)+case when (remainder-3*floor(remainder/3))>1 then 1 else 0 end from valid where n=3
), resolved as(
 select a.*,coalesce('group:'||l.group_id,a.id) key from amounts a left join public.cashgame_player_links l on l.player_id=a.id
), totals as(
 select key,min(id) id,sum(received) received,sum(entitled) entitled from resolved group by key
), people as(
 select t.*,coalesce((select jsonb_agg(l.player_id order by l.player_id) from public.cashgame_player_links l where 'group:'||l.group_id=t.key),jsonb_build_array(t.id)) ids,
 coalesce((select min(nullif(l.first_name,'')) from public.cashgame_player_links l where 'group:'||l.group_id=t.key),(select min(nullif(r.first_name,'')) from public.cashgame_results r where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=r.player_id),r.player_id)=t.key),'') first_name,
 (select count(distinct b.user_id) from public.cashgame_login_links b where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=b.player_id),b.player_id)=t.key) logins,
 (select min(b.user_id::text) from public.cashgame_login_links b where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=b.player_id),b.player_id)=t.key) user_id
 from totals t
)
select jsonb_build_object('month',p_month,'count',(select count(*) from valid),'excluded',(select count(*) from excluded),'pending',(select count(*) from sessions)-(select count(*) from excluded)-(select count(*) from valid),'total',(select coalesce(sum(tips),0) from valid),'balances',coalesce((select jsonb_agg(jsonb_build_object('key',key,'name',id,'ids',ids,'firstName',first_name,'received',received,'entitled',entitled,'balance',entitled-received,'logins',logins,'user_id',user_id) order by key) from people),'[]'::jsonb)) into output;
if exists(select 1 from public.cashgame_jackpot_contributions() c where c.session_date>=p_month and c.session_date<p_month+interval '1 month') then
 output:=output||jsonb_build_object('jackpotReserved',(select sum(c.amount_cents) from public.cashgame_jackpot_contributions() c where c.session_date>=p_month and c.session_date<p_month+interval '1 month'));
end if;
return output;
end $function$;

-- Evening host pays the prize; reimburse through the session month's settlement.
alter table public.cashgame_jackpot_payouts add column payer_id text not null,add column accounting_month date not null;
CREATE OR REPLACE FUNCTION cashgame_private.record_jackpot(p_id uuid, p_rule uuid, p_session text, p_winner text, p_note text, p_expected_amount bigint, p_expected_balance bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rule public.cashgame_jackpot_rules; game public.cashgame_sessions; balance bigint; amount bigint; left_amount bigint; take_amount bigint; holder record; allocations jsonb:='[]'; winner text;
begin
 if auth.uid() is null or not public.is_cashgame_manager() then raise exception 'Geen toegang'; end if;
 perform pg_advisory_xact_lock(769423);
 if exists(select 1 from public.cashgame_jackpot_payouts where id=p_id) then return p_id; end if;
 select * into rule from public.cashgame_jackpot_rules where id=p_rule and active;
 if not found then raise exception 'Deze handregel is niet actief'; end if;
 select * into game from public.cashgame_sessions where id=p_session;
 if not found or not exists(select 1 from public.cashgame_jackpot_settings cfg where game.session_date>=cfg.start_date and (cfg.end_date is null or game.session_date<=cfg.end_date)) or game.session_date>(now() at time zone 'Europe/Amsterdam')::date then raise exception 'Kies een gespeelde sessie binnen de jackpotperiode'; end if;
 if btrim(coalesce(game.host_player_id,''))='' then raise exception 'Kies eerst de host van deze sessie'; end if;
 if exists(select 1 from public.cashgame_month_settlements where month=date_trunc('month',game.session_date)::date and status='completed') then raise exception 'Deze sessiemaand is al bevestigd. Stel het maandoverzicht eerst opnieuw op om de jackpotuitbetaling te verwerken';end if;
 select min(first_name) into winner from public.cashgame_results where session_id=p_session and player_id=p_winner;
 if winner is null then raise exception 'Kies een deelnemer uit deze sessie'; end if;
 if length(coalesce(p_note,''))>2000 then raise exception 'Toelichting is te lang'; end if;
 select coalesce(sum(available),0) into balance from cashgame_private.jackpot_holdings();
 amount:=case when rule.payout_type='fixed' then round(rule.payout_value*100) else floor(balance*rule.payout_value/100) end;
 if amount<=0 or amount>balance then raise exception 'Onvoldoende jackpot voor deze uitbetaling'; end if;
 if balance<>p_expected_balance or amount<>p_expected_amount then raise exception 'De jackpot of handregel is gewijzigd. Vernieuw en controleer de uitbetaling opnieuw'; end if;
 left_amount:=amount;
 for holder in select * from cashgame_private.jackpot_holdings() where available>0 order by available desc,host_id collate "C" loop
  take_amount:=least(left_amount,holder.available);
  if take_amount>0 then allocations:=allocations||jsonb_build_array(jsonb_build_object('host_id',holder.host_id,'amount_cents',take_amount));left_amount:=left_amount-take_amount;end if;
  exit when left_amount=0;
 end loop;
 insert into public.cashgame_jackpot_payouts(id,session_id,session_date,session_code,winner_id,winner_name,rule_snapshot,amount_cents,balance_before,allocations,note,created_by,payer_id,accounting_month)
 values(p_id,p_session,game.session_date,game.code,p_winner,winner,to_jsonb(rule),amount,balance,allocations,coalesce(p_note,''),auth.uid(),game.host_player_id,date_trunc('month',game.session_date)::date);
 return p_id;
end $function$;
CREATE OR REPLACE FUNCTION cashgame_private.month_snapshot(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare output jsonb;
begin
with sessions as(
 select s.*, coalesce((select sum(round(r.tips*100)) from public.cashgame_results r where r.session_id=s.id),0) tips,
 case when s.manual_start<>'' and s.ended_at<>'' then ceil(extract(epoch from(cashgame_private.jackpot_timestamp(s.ended_at)-cashgame_private.jackpot_timestamp(s.manual_start)))/60) end minutes
 from public.cashgame_sessions s where s.session_date>=p_month and s.session_date<(p_month+interval '1 month')
), fees as(
 select s.*,case when minutes>=0 then round((13+3*ceil(greatest(0,minutes-180)/20))*20.99/115*100) end fee from sessions s
), excluded as(
 select * from fees where (btrim(host_player_id)<>'' and btrim(partner_player_id)='' and btrim(third_player_id)='') or (fee is not null and tips=fee)
), reserved as(
 select s.*,coalesce((select sum(floor(greatest(0,s.tips-s.fee)*a.percentage/100)) from public.cashgame_rakeback_sessions l join public.cashgame_rakeback_actions a on a.id=l.action_id where l.session_id=s.id),0) reserve,coalesce((select c.amount_cents from public.cashgame_jackpot_contributions() c where c.session_id=s.id),0) jackpot
 from fees s where not exists(select 1 from excluded e where e.id=s.id)
), valid as(
 select s.*,tips-fee-reserve-jackpot remainder,case when third_player_id='' then 2 else 3 end n
 from reserved s where host_player_id<>'' and partner_player_id<>'' and fee is not null and tips<>fee and reserve+jackpot<=greatest(0,tips-fee)
), jackpot_payments as(
 select * from public.cashgame_jackpot_payouts where accounting_month=p_month and cancelled_at is null
), amounts as(
 select host_player_id id,tips received,fee+reserve+jackpot+floor(remainder/n) entitled from valid
 union all select partner_player_id,0,case when n=2 then remainder-floor(remainder/2) else floor(remainder/3)+case when (remainder-3*floor(remainder/3))>0 then 1 else 0 end end from valid
 union all select third_player_id,0,floor(remainder/3)+case when (remainder-3*floor(remainder/3))>1 then 1 else 0 end from valid where n=3
 union all select p.payer_id,0,p.amount_cents from jackpot_payments p
 union all select a->>'host_id',0,-(a->>'amount_cents')::bigint from jackpot_payments p cross join lateral jsonb_array_elements(p.allocations) a
), resolved as(
 select a.*,coalesce('group:'||l.group_id,a.id) key from amounts a left join public.cashgame_player_links l on l.player_id=a.id
), totals as(
 select key,min(id) id,sum(received) received,sum(entitled) entitled from resolved group by key
), people as(
 select t.*,coalesce((select jsonb_agg(l.player_id order by l.player_id) from public.cashgame_player_links l where 'group:'||l.group_id=t.key),jsonb_build_array(t.id)) ids,
 coalesce((select min(nullif(l.first_name,'')) from public.cashgame_player_links l where 'group:'||l.group_id=t.key),(select min(nullif(r.first_name,'')) from public.cashgame_results r where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=r.player_id),r.player_id)=t.key),'') first_name,
 (select count(distinct b.user_id) from public.cashgame_login_links b where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=b.player_id),b.player_id)=t.key) logins,
 (select min(b.user_id::text) from public.cashgame_login_links b where coalesce((select 'group:'||l.group_id from public.cashgame_player_links l where l.player_id=b.player_id),b.player_id)=t.key) user_id
 from totals t
)
select jsonb_build_object('month',p_month,'count',(select count(*) from valid),'excluded',(select count(*) from excluded),'pending',(select count(*) from sessions)-(select count(*) from excluded)-(select count(*) from valid),'total',(select coalesce(sum(tips),0) from valid),'balances',coalesce((select jsonb_agg(jsonb_build_object('key',key,'name',id,'ids',ids,'firstName',first_name,'received',received,'entitled',entitled,'balance',entitled-received,'logins',logins,'user_id',user_id) order by key) from people),'[]'::jsonb)) into output;
if exists(select 1 from public.cashgame_jackpot_contributions() c where c.session_date>=p_month and c.session_date<p_month+interval '1 month') then
 output:=output||jsonb_build_object('jackpotReserved',(select sum(c.amount_cents) from public.cashgame_jackpot_contributions() c where c.session_date>=p_month and c.session_date<p_month+interval '1 month'));
end if;
if exists(select 1 from public.cashgame_jackpot_payouts p where p.accounting_month=p_month and p.cancelled_at is null) then
 output:=output||jsonb_build_object('jackpotPayouts',(select coalesce(jsonb_agg(jsonb_build_object('payer_id',p.payer_id,'amount_cents',p.amount_cents,'session_code',p.session_code,'allocations',p.allocations) order by p.created_at),'[]'::jsonb) from public.cashgame_jackpot_payouts p where p.accounting_month=p_month and p.cancelled_at is null),'jackpotPayoutCount',(select count(*) from public.cashgame_jackpot_payouts p where p.accounting_month=p_month and p.cancelled_at is null),'jackpotPayoutTotal',(select sum(amount_cents) from public.cashgame_jackpot_payouts p where p.accounting_month=p_month and p.cancelled_at is null));
end if;
return output;
end $function$;
CREATE OR REPLACE FUNCTION public.prepare_cashgame_month(p_month date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare snap jsonb; person jsonb;
begin
 if not public.is_cashgame_manager() or auth.uid() is null then raise exception 'Geen toegang'; end if;
 if p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',now() at time zone 'Europe/Amsterdam')::date then raise exception 'Alleen een verlopen maand kan worden afgerond'; end if;
 perform pg_advisory_xact_lock(769423);
 snap:=cashgame_private.month_snapshot(p_month);
 if (snap->>'pending')::int>0 or ((snap->>'count')::int=0 and coalesce((snap->>'jackpotPayoutCount')::int,0)=0) then raise exception 'Vul eerst alle sessies volledig in'; end if;
 if (select count(*) from jsonb_array_elements(snap->'balances'))<>(select count(distinct value->>'user_id') from jsonb_array_elements(snap->'balances')) then raise exception 'Iedere persoon moet een eigen loginaccount hebben'; end if;
 for person in select value from jsonb_array_elements(snap->'balances') loop
 if (person->>'logins')::int<>1 then raise exception 'Koppel precies één login aan elke persoon in de afrekening'; end if;
 end loop;
 insert into public.cashgame_month_settlements(month,snapshot) values(p_month,snap) on conflict(month) do update set snapshot=excluded.snapshot,status='pending',created_at=now(),completed_at=null;
 delete from public.cashgame_month_approvals where month=p_month;
 insert into public.cashgame_month_approvals(month,player_key,user_id) select p_month,value->>'key',(value->>'user_id')::uuid from jsonb_array_elements(snap->'balances');
end $function$;
create function cashgame_private.jackpot_closed_month_guard() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if old.cancelled_at is null and new.cancelled_at is not null and exists(select 1 from public.cashgame_month_settlements where month=old.accounting_month and status='completed') then raise exception 'Deze uitbetaling is al in een bevestigd maandoverzicht verwerkt. Stel dat overzicht eerst opnieuw op voor een correctie';end if;
 return new;
end $$;
create trigger jackpot_closed_month_guard before update on public.cashgame_jackpot_payouts for each row execute function cashgame_private.jackpot_closed_month_guard();
notify pgrst,'reload schema';