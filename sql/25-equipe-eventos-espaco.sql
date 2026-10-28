-- =====================================================================
-- 25 · PESO DA MÃO DE OBRA, RESERVA DE 13º/FÉRIAS, AVISO DE EVENTO A RECEBER E HISTÓRICO DO BANCO (18/10/2026)
--  1) api_equipe_peso_mao_obra: folha paga (+ encargos) de cada mês contra o faturamento do mês (vendas confirmadas + eventos), últimos 6 meses.
--  2) api_equipe_reserva: quanto já deveria estar reservado para 13º e férias de cada pessoa (estimativa; não lança nada no financeiro).
--  3) Aviso ao dono (celular e e-mail) quando um evento já passou e ainda tem valor a receber (dentro de alertas_sistema_cron).
--  4) Histórico do tamanho do banco (um registro por dia) com previsão de quando chega a 95% do plano.
-- Aditivo. Pode rodar de novo sem erro. Rode DEPOIS do 24.
-- =====================================================================

-- 1) peso da mão de obra
create or replace function public.api_equipe_peso_mao_obra(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_mes text := coalesce(nullif(p->>'mes', ''), to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM')); v_ini date; v_l jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_mes !~ '^\d{4}-\d{2}$' then return _falha('Mês inválido.'); end if;
  v_ini := (v_mes || '-01')::date;
  select coalesce(jsonb_agg(x order by x->>'mes'), '[]'::jsonb) into v_l from (
    select jsonb_build_object('mes', m.mes, 'folha', m.folha, 'encargos', m.enc, 'faturamento', m.fat,
             'percentual', case when m.fat > 0 then round((m.folha + m.enc) / m.fat * 100, 1) end) x
      from (
        select to_char(d, 'YYYY-MM') mes,
          coalesce((select sum(valor) from funcionario_pagamentos fp where fp.competencia = to_char(d, 'YYYY-MM') and fp.status = 'Paga'), 0) folha,
          coalesce((select sum(encargos) from funcionario_pagamentos fp where fp.competencia = to_char(d, 'YYYY-MM') and fp.status = 'Paga'), 0) enc,
          coalesce((select sum(v.valor_total) from vendas v where v.status = 'Confirmada' and to_char(v.data_hora at time zone 'America/Sao_Paulo', 'YYYY-MM') = to_char(d, 'YYYY-MM')), 0)
          + coalesce((select sum(a.valor_total) from vendas_resumo_arquivo a where a.status = 'Confirmada' and to_char(a.data_hora at time zone 'America/Sao_Paulo', 'YYYY-MM') = to_char(d, 'YYYY-MM')), 0)
          + coalesce((select sum(e.valor_contratado) from eventos e where e.status <> 'Cancelado' and to_char(e.data, 'YYYY-MM') = to_char(d, 'YYYY-MM')), 0) fat
        from generate_series(v_ini - interval '5 months', v_ini, interval '1 month') d) m) s;
  return jsonb_build_object('ok', true, 'mes', v_mes, 'meses', v_l);
end $$;

-- 2) reserva de 13º e férias (estimativa)
create or replace function public.api_equipe_reserva(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_l jsonb; v_t13 numeric := 0; v_tf numeric := 0;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'nome', q.nome, 'cargo', q.cargo, 'salario', q.salario, 'provisao', q.provisao, 'admissao', q.admissao,
      'mesesAno', q.meses_ano, 'decimoTerceiro', q.d13, 'mesesCiclo', q.ciclo, 'ferias', q.fer, 'periodosCompletos', q.periodos) order by q.nome), '[]'::jsonb),
    coalesce(sum(q.d13), 0), coalesce(sum(q.fer), 0) into v_l, v_t13, v_tf
  from (
    select f.*, m.meses_ano, round(f.salario / 12.0 * m.meses_ano, 2) d13,
           case when f.admissao is null then null else m.total % 12 end ciclo,
           case when f.admissao is null then null else round(f.salario / 12.0 * 4.0 / 3 * (m.total % 12), 2) end fer,
           case when f.admissao is null then null else m.total / 12 end periodos
      from funcionarios f
      cross join lateral (select
          least(12, greatest(0, (extract(year from v_hoje)::int * 12 + extract(month from v_hoje)::int)
             - (extract(year from greatest(coalesce(f.admissao, date_trunc('year', v_hoje)::date), date_trunc('year', v_hoje)::date))::int * 12
                + extract(month from greatest(coalesce(f.admissao, date_trunc('year', v_hoje)::date), date_trunc('year', v_hoje)::date))::int) + 1)) meses_ano,
          case when f.admissao is null then 0 else (extract(year from age(v_hoje, f.admissao))::int * 12 + extract(month from age(v_hoje, f.admissao))::int) end total) m
     where f.ativo and f.salario > 0) q;
  return jsonb_build_object('ok', true, 'pessoas', v_l, 'total13', v_t13, 'totalFerias', v_tf, 'total', v_t13 + v_tf);
end $$;

-- 3) aviso de evento já realizado com valor a receber (ajusta alertas_sistema_cron sem reescrevê-la)
do $$
declare v text;
begin
  select pg_get_functiondef('public.alertas_sistema_cron()'::regprocedure) into v;
  if v not like '%sis:evento_receber%' then
    v := replace(v, $q$select max(data_hora) into v_t from backups where status = 'ok';$q$,
      $q$for r in select e.id, e.nome, e.data, e.valor_a_receber from eventos e where e.status in ('Confirmado', 'Em andamento', 'Concluído') and e.valor_a_receber > 0.004 and e.data < (now() at time zone 'America/Sao_Paulo')::date loop
    ativos := array_append(ativos, ('sis:evento_receber:' || r.id)::text);
    perform _alertas_sistema_avisar('sis:evento_receber:' || r.id, 'Evento com valor a receber: ' || r.nome, 'O evento "' || r.nome || '" de ' || to_char(r.data, 'DD/MM') || ' já passou e ainda faltam R$ ' || _dinheiro(r.valor_a_receber) || ' a receber. Administrador → Vendas e cardápio → Eventos → Recebimentos.', interval '1 day');
  end loop;
  select max(data_hora) into v_t from backups where status = 'ok';$q$);
    execute v;
  end if;
end $$;

-- 4) histórico do tamanho do banco
create table if not exists public.espaco_historico (
  dia date primary key,
  db_bytes bigint not null,
  vendas_ativas integer
);
alter table public.espaco_historico enable row level security;
revoke all on public.espaco_historico from anon, authenticated;
grant all on public.espaco_historico to service_role;
create or replace function public._espaco_snapshot() returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  insert into espaco_historico (dia, db_bytes, vendas_ativas) values ((now() at time zone 'America/Sao_Paulo')::date, pg_database_size(current_database()), (select count(*) from vendas))
  on conflict (dia) do update set db_bytes = excluded.db_bytes, vendas_ativas = excluded.vendas_ativas;
end $$;
revoke all on function public._espaco_snapshot() from public, anon, authenticated;
select public._espaco_snapshot();
select cron.schedule('espaco-snapshot-dia', '5 7 * * *', 'select public._espaco_snapshot()');

create or replace function public.api_espaco_historico(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_lim numeric := _limite_banco_mb(); v_atual numeric := pg_database_size(current_database()) / 1048576.0; v_n int; v_slope numeric; v_meses jsonb; v_dias jsonb; v_prev numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  perform _espaco_snapshot();
  select coalesce(jsonb_agg(jsonb_build_object('mes', mes, 'mb', mb) order by mes), '[]'::jsonb) into v_meses
    from (select to_char(dia, 'YYYY-MM') mes, round(max(db_bytes) / 1048576.0, 1) mb from espaco_historico where dia >= date_trunc('month', current_date) - interval '11 months' group by 1) m;
  select coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'mb', round(db_bytes / 1048576.0, 1)) order by dia), '[]'::jsonb) into v_dias from espaco_historico where dia >= current_date - 29;
  select count(*), regr_slope(db_bytes::double precision, extract(epoch from dia::timestamp)::double precision) * 86400 / 1048576.0 into v_n, v_slope from espaco_historico where dia >= current_date - 44;
  if v_n >= 5 and v_slope is not null and v_slope > 0.0001 then v_prev := greatest(0, (v_lim * 0.95 - v_atual) / v_slope); end if;
  return jsonb_build_object('ok', true, 'limiteMb', v_lim, 'atualMb', round(v_atual, 1), 'meses', v_meses, 'dias', v_dias, 'pontos', v_n,
    'crescimentoMbDia', case when v_n >= 5 then round(v_slope, 3) end, 'diasAte95', case when v_prev is not null then floor(v_prev) end);
end $$;
revoke all on function public.api_espaco_historico(jsonb) from public;
grant execute on function public.api_espaco_historico(jsonb) to authenticated, service_role;
do $$ declare f text; begin
  foreach f in array array['api_equipe_peso_mao_obra(jsonb)', 'api_equipe_reserva(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
