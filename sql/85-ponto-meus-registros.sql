-- 85 — Ponto do funcionário: "Meus registros" por competência, pedido de correção e atestado (aprovação só do Admin).
-- Foto do atestado fica no banco (privado) e é apagada sozinha após 30 dias; o registro (dias/decisão) permanece.

insert into public.sistema (chave, valor) values ('PONTO_FECHAMENTO', '20'::jsonb) on conflict (chave) do nothing;

create table if not exists public.ponto_pedidos (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id),
  tipo text not null check (tipo in ('correcao','atestado')),
  data_ini date not null,
  data_fim date not null,
  batidas jsonb,
  motivo text,
  foto text,
  foto_expira_em timestamptz,
  status text not null default 'pendente' check (status in ('pendente','aprovado','recusado')),
  decidido_por text,
  decidido_em timestamptz,
  resposta text,
  criado_em timestamptz not null default now()
);
create index if not exists ponto_pedidos_func_idx on public.ponto_pedidos (funcionario_id, data_ini);
create index if not exists ponto_pedidos_status_idx on public.ponto_pedidos (status, criado_em);
alter table public.ponto_pedidos enable row level security;
revoke all on public.ponto_pedidos from public, anon, authenticated;
grant all on public.ponto_pedidos to service_role;

create or replace function public._ponto_fechamento() returns int language sql stable security definer set search_path to 'public' as $$
  select greatest(1, least(28, coalesce((select (valor #>> '{}')::int from sistema where chave = 'PONTO_FECHAMENTO' and jsonb_typeof(valor) = 'number'), 20)))
$$;
revoke all on function public._ponto_fechamento() from public, anon, authenticated;
grant execute on function public._ponto_fechamento() to service_role;

-- Fechamento: ler (qualquer logado) e alterar (Admin + senha)
create or replace function public.api_ponto_fechamento(p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if auth_nivel() is null then return _negado(); end if;
  return jsonb_build_object('ok', true, 'dia', _ponto_fechamento());
end $$;

create or replace function public.api_ponto_fechamento_salvar(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_dia int; v_err text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_err := _senha_acao(p->>'senha'); if v_err <> '' then return _falha(v_err); end if;
  begin v_dia := (p->>'dia')::int; exception when others then return _falha('Informe um dia de 1 a 28.'); end;
  if v_dia is null or v_dia < 1 or v_dia > 28 then return _falha('Informe um dia de 1 a 28.'); end if;
  insert into sistema (chave, valor, atualizado_em) values ('PONTO_FECHAMENTO', to_jsonb(v_dia), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform _auditar('Ponto: dia de fechamento', 'Dia ' || v_dia);
  return jsonb_build_object('ok', true, 'message', 'Fechamento do ponto: dia ' || v_dia || '.', 'dia', v_dia);
end $$;

-- Meus registros: competência = do dia (fechamento+1) do mês até o dia do fechamento do mês seguinte
create or replace function public.api_ponto_meus_registros(p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_eu uuid := _func_do_usuario(); v_f int := _ponto_fechamento();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_atual date; v_ref date; v_ini date; v_fim date; v_comps jsonb := '[]'::jsonb; v_dias jsonb; v_tot int; v_ped jsonb; i int;
  v_meses text[] := array['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null or exists (select 1 from funcionarios where id = v_eu and dono) then return jsonb_build_object('ok', true, 'vinculado', false); end if;
  v_atual := date_trunc('month', v_hoje)::date;
  if v_hoje <= (v_atual + (v_f - 1)) then v_atual := (v_atual - interval '1 month')::date; end if;
  for i in 0..5 loop
    v_ref := (v_atual - make_interval(months => i))::date;
    v_comps := v_comps || jsonb_build_array(jsonb_build_object('ref', to_char(v_ref, 'YYYY-MM'), 'nome', v_meses[extract(month from v_ref)::int] || ' de ' || extract(year from v_ref)::int,
      'ini', v_ref + v_f, 'fim', (v_ref + (v_f - 1) + interval '1 month')::date));
  end loop;
  begin v_ref := to_date(coalesce(nullif(p->>'ref', ''), to_char(v_atual, 'YYYY-MM')) || '-01', 'YYYY-MM-DD'); exception when others then v_ref := v_atual; end;
  if v_ref > v_atual or v_ref < (v_atual - interval '24 months') then v_ref := v_atual; end if;
  v_ini := v_ref + v_f;
  v_fim := (v_ref + (v_f - 1) + interval '1 month')::date;
  select coalesce(jsonb_agg(d order by (d->>'data') desc), '[]'::jsonb), coalesce(sum((d->>'min')::int), 0) into v_dias, v_tot from (
    select jsonb_build_object('data', g.d, 'marcas', coalesce(m.marcas, '[]'::jsonb), 'min', coalesce(m.minutos, 0),
      'aberto', coalesce(m.aberto, false),
      'atestado', exists (select 1 from ponto_pedidos x where x.funcionario_id = v_eu and x.tipo = 'atestado' and x.status = 'aprovado' and g.d between x.data_ini and x.data_fim),
      'pedido', exists (select 1 from ponto_pedidos x where x.funcionario_id = v_eu and x.status = 'pendente' and g.d between x.data_ini and x.data_fim)) d
    from generate_series(v_ini, least(v_fim, v_hoje), interval '1 day') gs(dd)
    cross join lateral (select gs.dd::date d) g
    left join lateral (
      select jsonb_agg(to_char(t at time zone 'America/Sao_Paulo', 'HH24:MI') order by t) filter (where t is not null) marcas,
             (select coalesce(round(sum(extract(epoch from saida - entrada)) / 60), 0)::int from ponto_registros r2 where r2.funcionario_id = v_eu and not r2.cancelado and r2.saida is not null and (r2.entrada at time zone 'America/Sao_Paulo')::date = g.d) minutos,
             bool_or(aberto_) aberto
      from (select unnest(array[r.entrada, r.saida]) t, (r.saida is null) aberto_ from ponto_registros r
            where r.funcionario_id = v_eu and not r.cancelado and (r.entrada at time zone 'America/Sao_Paulo')::date = g.d) u
    ) m on true
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'ini', x.data_ini, 'fim', x.data_fim, 'status', x.status, 'resposta', x.resposta, 'motivo', x.motivo, 'batidas', x.batidas, 'criado', x.criado_em) order by x.criado_em desc), '[]'::jsonb)
    into v_ped from (select * from ponto_pedidos where funcionario_id = v_eu order by criado_em desc limit 30) x;
  return jsonb_build_object('ok', true, 'vinculado', true, 'fechamento', v_f, 'competencias', v_comps, 'ref', to_char(v_ref, 'YYYY-MM'),
    'nome', v_meses[extract(month from v_ref)::int] || ' de ' || extract(year from v_ref)::int, 'ini', v_ini, 'fim', v_fim, 'hoje', v_hoje, 'dias', v_dias, 'totalMin', v_tot, 'pedidos', v_ped);
end $$;

-- (as funções api_ponto_pedido_criar / api_ponto_pedidos_lista / api_ponto_pedido_foto / api_ponto_pedido_decidir / _ponto_atestados_limpar
--  e o agendamento 'ponto-atestados-30-dias' foram aplicados no banco; para refazer, copie-as de: select pg_get_functiondef('public.<nome>'::regproc);)
-- Permissões: authenticated + service_role nas api_ponto_*; _ponto_* só service_role.
-- Agendamento: select cron.schedule('ponto-atestados-30-dias', '50 6 * * *', 'select public._ponto_atestados_limpar()');
