-- Uitleg per host en sessie, zonder de verdeelregels of saldi te wijzigen.
-- Bestaande maandafrekeningen bewaren hun bevestigingen.

CREATE OR REPLACE FUNCTION cashgame_private.month_breakdown(p_month date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
WITH sessions AS (
 SELECT s.id,s.code,s.session_date,s.host_player_id,s.partner_player_id,s.third_player_id,
 coalesce((SELECT sum(round(r.tips*100)) FROM public.cashgame_results r WHERE r.session_id=s.id),0)::bigint AS tips,
 CASE WHEN s.manual_start<>'' AND s.ended_at<>''
 THEN ceil(extract(epoch from(cashgame_private.jackpot_timestamp(s.ended_at)-cashgame_private.jackpot_timestamp(s.manual_start)))/60)
 END AS minutes
 FROM public.cashgame_sessions s
 WHERE s.session_date>=p_month AND s.session_date<p_month+interval '1 month'
), fees AS (
 SELECT s.*,CASE WHEN minutes>=0 THEN round((13+3*ceil(greatest(0,minutes-180)/20))*20.99/115*100)::bigint END AS fee
 FROM sessions s
), reserved AS (
 SELECT s.*,
 coalesce((SELECT sum(floor(greatest(0,s.tips-s.fee)*a.percentage/100)) FROM public.cashgame_rakeback_sessions l JOIN public.cashgame_rakeback_actions a ON a.id=l.action_id WHERE l.session_id=s.id),0)::bigint AS reserve,
 coalesce((SELECT c.amount_cents FROM public.cashgame_jackpot_contributions() c WHERE c.session_id=s.id),0)::bigint AS jackpot
 FROM fees s
), valid AS (
 SELECT s.*,(tips-fee-reserve-jackpot)::bigint AS remainder, CASE WHEN btrim(third_player_id)='' THEN 2 ELSE 3 END AS n
 FROM reserved s WHERE btrim(host_player_id)<>'' AND btrim(partner_player_id)<>'' AND fee IS NOT NULL AND tips<>fee AND reserve+jackpot<=greatest(0,tips-fee)
), parts AS (
 SELECT v.*,
 floor(remainder/n)::bigint AS host_share,
 (CASE WHEN n=2 THEN remainder-floor(remainder/2) ELSE floor(remainder/3)+CASE WHEN remainder-3*floor(remainder/3)>0 THEN 1 ELSE 0 END END)::bigint AS partner_share,
 (CASE WHEN n=3 THEN floor(remainder/3)+CASE WHEN remainder-3*floor(remainder/3)>1 THEN 1 ELSE 0 END ELSE 0 END)::bigint AS third_share
 FROM valid v
), item AS (
 SELECT host_player_id AS id,tips AS received,fee AS host_fee,host_share AS share,reserve AS bonus,jackpot FROM parts
 UNION ALL SELECT partner_player_id,0::bigint,0::bigint,partner_share,0::bigint,0::bigint FROM parts
 UNION ALL SELECT third_player_id,0::bigint,0::bigint,third_share,0::bigint,0::bigint FROM parts WHERE n=3
), grouped AS (
 SELECT coalesce('group:'||l.group_id,i.id) AS key,
 sum(i.received)::bigint AS received,
 sum(i.host_fee)::bigint AS host_fee,
 sum(i.share)::bigint AS share,
 sum(i.bonus)::bigint AS bonus,
 sum(i.jackpot)::bigint AS jackpot
 FROM item i LEFT JOIN public.cashgame_player_links l ON l.player_id=i.id
 GROUP BY coalesce('group:'||l.group_id,i.id)
)
SELECT jsonb_build_object(
 'summary',jsonb_build_object(
   'received',coalesce((SELECT sum(tips) FROM parts),0),
   'hostFee',coalesce((SELECT sum(fee) FROM parts),0),
   'bonus',coalesce((SELECT sum(reserve) FROM parts),0),
   'jackpot',coalesce((SELECT sum(jackpot) FROM parts),0),
   'rakeShare',coalesce((SELECT sum(remainder) FROM parts),0),
   'sessions',(SELECT count(*) FROM parts)
 ),
 'hosts',coalesce((SELECT jsonb_agg(jsonb_build_object('key',key,'received',received,'hostFee',host_fee,'share',share,'bonus',bonus,'jackpot',jackpot) ORDER BY key) FROM grouped),'[]'::jsonb),
 'sessions',coalesce((SELECT jsonb_agg(jsonb_build_object('date',session_date,'code',code,'host',host_player_id,'partner',partner_player_id,'third',third_player_id,'received',tips,'hostFee',fee,'bonus',reserve,'jackpot',jackpot,'remainder',remainder,'hostShare',host_share,'partnerShare',partner_share,'thirdShare',third_share) ORDER BY session_date,code) FROM parts),'[]'::jsonb)
);
$function$


REVOKE ALL ON FUNCTION cashgame_private.month_breakdown(date) FROM PUBLIC, anon, authenticated;

-- Nieuwe snapshots krijgen ook de uitsplitsing voor alle betrokken hosts.
DO $body$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('cashgame_private.month_snapshot(date)'::regprocedure) INTO definition;
 IF position('cashgame_private.month_breakdown(p_month)' in definition)=0 THEN
  IF position('return output;' in definition)=0 THEN RAISE EXCEPTION 'Maandfunctie kan niet veilig aangevuld worden'; END IF;
  definition := replace(definition,'return output;','output:=output||jsonb_build_object(''breakdown'',cashgame_private.month_breakdown(p_month));'||chr(10)||'return output;');
  EXECUTE definition;
 END IF;
END $body$;

-- Alleen oktober 2026 is veilig één-op-één te verrijken met de actuele sessies.
-- Geen bedragen, goedkeuringen of status worden gewijzigd.
UPDATE public.cashgame_month_settlements s
SET snapshot=s.snapshot||jsonb_build_object('breakdown',cashgame_private.month_breakdown(s.month))
WHERE s.month='2026-10-01'::date AND NOT (s.snapshot?'breakdown')
AND (s.snapshot->>'total')::bigint=(cashgame_private.month_breakdown(s.month)->'summary'->>'received')::bigint
AND (s.snapshot->>'count')::int=(cashgame_private.month_breakdown(s.month)->'summary'->>'sessions')::int;
