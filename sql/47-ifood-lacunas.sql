-- 47 · iFood: varredura na volta do Supabase (queda/contingência)
-- Se a consulta ao iFood ficar parada por mais de 3 minutos e voltar, grava a "lacuna", varre os pedidos do iFood feitos
-- dentro dela (o iFood guarda os eventos não lidos e entrega tudo na volta) e avisa Admin e Operador.
create table if not exists public.ifood_lacunas (
  id bigserial primary key,
  inicio timestamptz not null,
  fim timestamptz not null,
  pedidos int not null default 0,
  cancelados int not null default 0,
  detalhe jsonb not null default '[]'::jsonb,
  visto_em timestamptz,
  criado_em timestamptz not null default now()
);
alter table public.ifood_lacunas enable row level security;
revoke all on table public.ifood_lacunas from public, anon, authenticated;
grant all on table public.ifood_lacunas to service_role;

-- Conta os pedidos do iFood cujo horário de criação (no iFood) caiu dentro da lacuna.
create or replace function public._ifood_lacuna_varrer(p_id bigint) returns void
  language plpgsql security definer set search_path to 'public' as $$
declare l ifood_lacunas%rowtype; v_n int; v_c int; v_det jsonb;
begin
  select * into l from ifood_lacunas where id = p_id; if l.id is null then return; end if;
  select count(*)::int,
         count(*) filter (where lower(coalesce(estado,'')) like '%cancel%')::int,
         coalesce(jsonb_agg(jsonb_build_object('numero', numero_ifood, 'estado', estado, 'em', p.em) order by p.em), '[]'::jsonb)
    into v_n, v_c, v_det
    from (select numero_ifood, estado, coalesce((bruto->>'createdAt')::timestamptz, criado_em) em
            from ifood_pedidos where not coalesce(simulado, false)) p
   where p.em >= l.inicio and p.em <= l.fim + interval '1 minute';
  update ifood_lacunas set pedidos = v_n, cancelados = v_c, detalhe = v_det where id = p_id;
end $$;

create or replace function public.ifood_marcar_consulta(p_ok boolean, p_erro text DEFAULT NULL::text, p_token_ok boolean DEFAULT NULL::boolean)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare v_ant timestamptz; v_id bigint;
begin
  select ultima_consulta_ok into v_ant from ifood_estado where id;
  update ifood_estado set ultima_consulta = now(),
    ultima_consulta_ok = case when p_ok then now() else ultima_consulta_ok end,
    token_ok = coalesce(p_token_ok, token_ok),
    ultimo_erro = case when p_ok then null else left(p_erro, 300) end,
    ultimo_erro_em = case when p_ok then ultimo_erro_em else now() end, atualizado_em = now() where id;
  if not p_ok and p_erro is not null then perform public._integ_log('ifood', 'erro', p_erro); end if;
  -- lacuna só conta se a última consulta boa foi DEPOIS de o iFood ser ligado (ligar de novo após desligar não é queda)
  if p_ok and v_ant is not null and now() - v_ant > interval '3 minutes' and now() - v_ant < interval '3 days'
     and v_ant >= coalesce((select ligado_em from integracoes_config where provedor = 'ifood'), '-infinity'::timestamptz) then
    insert into ifood_lacunas(inicio, fim) values (v_ant, now()) returning id into v_id;
    perform _ifood_lacuna_varrer(v_id);
    begin
      perform _alertas_push('iFood: sistema ficou fora do ar',
        'De ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'HH24:MI') || ' às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || ' o iFood não conseguiu entregar pedidos. Confira no portal do iFood.',
        'ifood-lacuna', array['Admin', 'Operador']);
    exception when others then null; end;
  end if;
end $$;

create or replace function public.api_ifood_lacunas(p jsonb default '{}'::jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if coalesce((p->>'marcarVisto')::boolean, false) then
    update ifood_lacunas set visto_em = now() where visto_em is null;
  end if;
  return jsonb_build_object('ok', true, 'lacunas', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'inicio', inicio, 'fim', fim, 'pedidos', pedidos, 'cancelados', cancelados, 'detalhe', detalhe) order by inicio desc)
      from (select * from ifood_lacunas where visto_em is null order by inicio desc limit 10) x), '[]'::jsonb));
end $$;

revoke all on function public._ifood_lacuna_varrer(bigint), public.api_ifood_lacunas(jsonb) from public, anon;
grant execute on function public.api_ifood_lacunas(jsonb) to authenticated, service_role;
grant execute on function public._ifood_lacuna_varrer(bigint) to service_role;
