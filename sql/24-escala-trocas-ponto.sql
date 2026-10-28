-- =====================================================================
-- 24 · ESCALA: TROCA DE TURNO, AVISOS NO CELULAR E PONTO (18/10/2026)
--  1) Troca de turno: a pessoa pede para passar um turno a um colega; o colega aceita (ou recusa); o dono aprova (ou recusa).
--     Só aí o turno muda de pessoa. O dono também pode aprovar direto, sem esperar o colega.
--  2) Avisos no celular: "sua escala mudou" (turno salvo/removido nos próximos 14 dias) e botão "Avisar a equipe" (resumo da semana).
--  3) Ponto: cada pessoa bate entrada e saída pelo celular (Início); o dono vê horas feitas x escaladas, horas extras (acima de 44 h na semana)
--     e corrige/lança registros esquecidos. Registro cancelado fica guardado. Aviso ao dono quando alguém esquece de bater a saída.
-- Aditivo: 2 tabelas, 11 funções (2 ajustadas). Pode rodar de novo sem erro. Rode DEPOIS do 21.
-- =====================================================================

-- ---------- tabelas ----------
create table if not exists public.escala_trocas (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references public.escala_turnos(id),
  de_funcionario_id uuid not null references public.funcionarios(id),
  para_funcionario_id uuid not null references public.funcionarios(id),
  status text not null default 'Aguardando colega' check (status in ('Aguardando colega', 'Aguardando dono', 'Aprovada', 'Recusada', 'Cancelada')),
  motivo text,
  resposta text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists escala_trocas_status_idx on public.escala_trocas (status, criado_em desc);
create table if not exists public.ponto_registros (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id),
  entrada timestamptz not null,
  saida timestamptz,
  origem text not null default 'app',
  observacao text,
  cancelado boolean not null default false,
  criado_em timestamptz not null default now(),
  check (saida is null or saida > entrada)
);
create index if not exists ponto_registros_func_idx on public.ponto_registros (funcionario_id, entrada desc);
alter table public.escala_trocas enable row level security;
alter table public.ponto_registros enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'escala_trocas' and policyname = 'escala_trocas_ler_admin') then
    create policy escala_trocas_ler_admin on public.escala_trocas for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ponto_registros' and policyname = 'ponto_registros_ler_admin') then
    create policy ponto_registros_ler_admin on public.ponto_registros for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
end $$;
revoke all on public.escala_trocas, public.ponto_registros from anon, authenticated;
grant select on public.escala_trocas, public.ponto_registros to authenticated;
grant all on public.escala_trocas, public.ponto_registros to service_role;

-- ---------- ajudantes ----------
create or replace function public._func_do_usuario() returns uuid language sql stable security definer set search_path to 'public' as $$
  select id from funcionarios where usuario_id = auth.uid() and ativo limit 1
$$;
create or replace function public._push_func(p_func uuid, p_titulo text, p_texto text, p_tag text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_u uuid;
begin
  select usuario_id into v_u from funcionarios where id = p_func;
  if v_u is null then return; end if;
  perform _alertas_push(p_titulo, p_texto, p_tag, array['Admin', 'Operador', 'Cozinha', 'Garçom'], array[v_u]);
exception when others then null;
end $$;
create or replace function public._push_admins(p_titulo text, p_texto text, p_tag text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform _alertas_push(p_titulo, p_texto, p_tag, array['Admin']);
exception when others then null;
end $$;
create or replace function public._escala_dia_texto(p_func uuid, p_data date) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(string_agg(case when t.tipo = 'Trabalho' then to_char(t.inicio, 'HH24:MI') || '–' || to_char(t.fim, 'HH24:MI') when t.tipo in ('Falta', 'Atestado') then 'Ausente' else t.tipo end, ', ' order by t.inicio), 'sem turno')
    from escala_turnos t where t.funcionario_id = p_func and t.data = p_data and not t.cancelado
$$;
create or replace function public._escala_avisar_pessoa(p_func uuid, p_data date) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if p_data < v_hoje or p_data > v_hoje + 14 then return; end if;
  perform _push_func(p_func, '📅 Sua escala mudou', to_char(p_data, 'DD/MM') || ': ' || _escala_dia_texto(p_func, p_data), 'escala-' || p_func || '-' || p_data);
end $$;
revoke all on function public._func_do_usuario(), public._push_func(uuid, text, text, text), public._push_admins(text, text, text),
  public._escala_dia_texto(uuid, date), public._escala_avisar_pessoa(uuid, date) from public, anon, authenticated;

-- salvar/remover turno avisa a pessoa (ajusta as funções do 21 sem reescrevê-las)
do $$
declare v text;
begin
  select pg_get_functiondef('public.api_salvar_turno(jsonb)'::regprocedure) into v;
  if v not like '%_escala_avisar_pessoa%' then
    v := replace(v, $q$perform _auditar('Escala: turno removido', v_nome || ' | ' || v_data);$q$, $q$perform _auditar('Escala: turno removido', v_nome || ' | ' || v_data); perform _escala_avisar_pessoa(v_f, v_data);$q$);
    v := replace(v, $q$perform _auditar('Escala: turno salvo',$q$, $q$perform _escala_avisar_pessoa(v_f, v_data); perform _auditar('Escala: turno salvo',$q$);
    execute v;
  end if;
  select pg_get_functiondef('public.api_minha_escala(jsonb)'::regprocedure) into v;
  if v not like '%''id'', t.id%' then
    v := replace(v, $q$jsonb_build_object('data', t.data, 'tipo', case when t.tipo in ('Falta', 'Atestado')$q$, $q$jsonb_build_object('id', t.id, 'data', t.data, 'tipo', case when t.tipo in ('Falta', 'Atestado')$q$);
    execute v;
  end if;
end $$;

-- "Avisar a equipe": manda a cada pessoa (com acesso) o resumo da semana escolhida
create or replace function public.api_escala_avisar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_ini date; r record; v_txt text; v_n int := 0; d int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_ini := _escala_segunda(coalesce(nullif(p->>'inicio', '')::date, (now() at time zone 'America/Sao_Paulo')::date));
  for r in select f.id, f.nome from funcionarios f where f.ativo and f.usuario_id is not null
            and exists (select 1 from escala_turnos t where t.funcionario_id = f.id and t.data between v_ini and v_ini + 6 and not t.cancelado) loop
    v_txt := '';
    for d in 0..6 loop
      v_txt := v_txt || (array['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'])[d + 1] || ' ' || to_char(v_ini + d, 'DD/MM') || ' ' || _escala_dia_texto(r.id, v_ini + d) || E'\n';
    end loop;
    perform _push_func(r.id, '📅 Escala da semana', btrim(v_txt), 'escala-sem-' || r.id || '-' || v_ini);
    v_n := v_n + 1;
  end loop;
  perform _auditar('Escala: equipe avisada', v_ini || ' | ' || v_n || ' pessoa(s)');
  return jsonb_build_object('ok', true, 'avisados', v_n, 'message', case when v_n = 0 then 'Ninguém para avisar: só quem tem acesso ao sistema (e ativou os avisos no celular) recebe. Use "Importar acessos".' else 'Aviso enviado para ' || v_n || ' pessoa(s) com acesso ao sistema. Quem ainda não ativou os avisos no celular vê na tela Início.' end);
end $$;

-- ---------- troca de turno ----------
create or replace function public.api_troca_solicitar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); v_t escala_turnos%rowtype; v_para uuid := _uuid(p->>'paraFuncionarioId'); v_nome_eu text; v_nome_para text; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_id uuid;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return _falha('Seu acesso ainda não está ligado a um funcionário. Peça ao dono para usar "Importar acessos" na Escala.'); end if;
  select * into v_t from escala_turnos where id = _uuid(p->>'turnoId') and not cancelado;
  if v_t.id is null or v_t.funcionario_id <> v_eu then return _falha('Esse turno não é seu.'); end if;
  if v_t.tipo <> 'Trabalho' then return _falha('Só dá para trocar turno de trabalho.'); end if;
  if v_t.data < v_hoje then return _falha('Esse turno já passou.'); end if;
  select nome into v_nome_para from funcionarios where id = v_para and ativo;
  if v_nome_para is null or v_para = v_eu then return _falha('Escolha um colega.'); end if;
  if exists (select 1 from escala_trocas where turno_id = v_t.id and status in ('Aguardando colega', 'Aguardando dono')) then return _falha('Esse turno já tem um pedido de troca em andamento.'); end if;
  insert into escala_trocas (turno_id, de_funcionario_id, para_funcionario_id, motivo) values (v_t.id, v_eu, v_para, left(nullif(btrim(coalesce(p->>'motivo', '')), ''), 200)) returning id into v_id;
  select nome into v_nome_eu from funcionarios where id = v_eu;
  perform _push_func(v_para, '🔁 Pedido de troca de turno', v_nome_eu || ' pede para você assumir o turno de ' || to_char(v_t.data, 'DD/MM') || ' (' || to_char(v_t.inicio, 'HH24:MI') || '–' || to_char(v_t.fim, 'HH24:MI') || '). Abra o Início para responder.', 'troca-' || v_id);
  perform _auditar('Escala: troca solicitada', v_nome_eu || ' → ' || v_nome_para || ' | ' || v_t.data);
  return jsonb_build_object('ok', true, 'message', 'Pedido enviado para ' || v_nome_para || '. Se ele aceitar, o dono aprova e a escala muda.');
end $$;

create or replace function public.api_troca_responder(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); x escala_trocas%rowtype; v_acao text := p->>'acao'; v_t escala_turnos%rowtype; v_de text; v_para text;
begin
  if auth_nivel() is null then return _negado(); end if;
  select * into x from escala_trocas where id = _uuid(p->>'id') for update;
  if x.id is null then return _falha('Pedido não encontrado.'); end if;
  select * into v_t from escala_turnos where id = x.turno_id;
  select nome into v_de from funcionarios where id = x.de_funcionario_id; select nome into v_para from funcionarios where id = x.para_funcionario_id;
  if v_acao = 'cancelar' then
    if v_eu is distinct from x.de_funcionario_id or x.status not in ('Aguardando colega', 'Aguardando dono') then return _falha('Não dá para cancelar esse pedido.'); end if;
    update escala_trocas set status = 'Cancelada', atualizado_em = now() where id = x.id;
    return jsonb_build_object('ok', true, 'message', 'Pedido cancelado.');
  end if;
  if v_eu is distinct from x.para_funcionario_id or x.status <> 'Aguardando colega' then return _falha('Esse pedido não está esperando a sua resposta.'); end if;
  if v_acao = 'aceitar' then
    if exists (select 1 from escala_turnos t where t.funcionario_id = v_eu and t.data = v_t.data and t.tipo = 'Trabalho' and not t.cancelado
               and tsrange(t.data + t.inicio, t.data + t.fim + case when t.fim <= t.inicio then interval '1 day' else interval '0' end)
                && tsrange(v_t.data + v_t.inicio, v_t.data + v_t.fim + case when v_t.fim <= v_t.inicio then interval '1 day' else interval '0' end)) then
      return _falha('Você já tem um turno nesse horário em ' || to_char(v_t.data, 'DD/MM') || '.');
    end if;
    update escala_trocas set status = 'Aguardando dono', atualizado_em = now() where id = x.id;
    perform _push_admins('🔁 Troca de turno para aprovar', v_de || ' → ' || v_para || ' em ' || to_char(v_t.data, 'DD/MM') || ' (' || to_char(v_t.inicio, 'HH24:MI') || '–' || to_char(v_t.fim, 'HH24:MI') || '). Aprove em Loja e equipe → Escala.', 'troca-adm-' || x.id);
    perform _push_func(x.de_funcionario_id, '🔁 ' || v_para || ' aceitou a troca', 'Agora falta o dono aprovar.', 'troca-' || x.id);
    return jsonb_build_object('ok', true, 'message', 'Você aceitou. Agora o dono precisa aprovar.');
  elsif v_acao = 'recusar' then
    update escala_trocas set status = 'Recusada', resposta = 'Recusada pelo colega', atualizado_em = now() where id = x.id;
    perform _push_func(x.de_funcionario_id, '🔁 Troca recusada', v_para || ' não pôde assumir o turno de ' || to_char(v_t.data, 'DD/MM') || '.', 'troca-' || x.id);
    return jsonb_build_object('ok', true, 'message', 'Pedido recusado.');
  end if;
  return _falha('Ação inválida.');
end $$;

create or replace function public.api_troca_decidir(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare x escala_trocas%rowtype; v_t escala_turnos%rowtype; v_aprovar boolean := coalesce(p->>'aprovar', '') = 'true'; v_de text; v_para text; v_resp text := left(nullif(btrim(coalesce(p->>'motivo', '')), ''), 200);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into x from escala_trocas where id = _uuid(p->>'id') for update;
  if x.id is null or x.status not in ('Aguardando colega', 'Aguardando dono') then return _falha('Esse pedido não está mais em aberto.'); end if;
  select * into v_t from escala_turnos where id = x.turno_id;
  select nome into v_de from funcionarios where id = x.de_funcionario_id; select nome into v_para from funcionarios where id = x.para_funcionario_id;
  if not v_aprovar then
    update escala_trocas set status = 'Recusada', resposta = coalesce(v_resp, 'Recusada pelo dono'), atualizado_em = now() where id = x.id;
    perform _push_func(x.de_funcionario_id, '🔁 Troca não aprovada', 'O pedido de troca de ' || to_char(v_t.data, 'DD/MM') || ' não foi aprovado.', 'troca-' || x.id);
    perform _push_func(x.para_funcionario_id, '🔁 Troca não aprovada', 'O pedido de troca de ' || to_char(v_t.data, 'DD/MM') || ' não foi aprovado.', 'troca-' || x.id);
    return jsonb_build_object('ok', true, 'message', 'Troca recusada.');
  end if;
  if v_t.cancelado then return _falha('O turno foi removido da escala.'); end if;
  if exists (select 1 from escala_turnos t where t.funcionario_id = x.para_funcionario_id and t.data = v_t.data and t.tipo = 'Trabalho' and not t.cancelado and t.id <> v_t.id
             and tsrange(t.data + t.inicio, t.data + t.fim + case when t.fim <= t.inicio then interval '1 day' else interval '0' end)
              && tsrange(v_t.data + v_t.inicio, v_t.data + v_t.fim + case when v_t.fim <= v_t.inicio then interval '1 day' else interval '0' end)) then
    return _falha(v_para || ' já tem um turno nesse horário em ' || to_char(v_t.data, 'DD/MM') || '.');
  end if;
  update escala_turnos set funcionario_id = x.para_funcionario_id where id = v_t.id;
  update escala_trocas set status = 'Aprovada', resposta = v_resp, atualizado_em = now() where id = x.id;
  perform _push_func(x.de_funcionario_id, '✅ Troca aprovada', 'O turno de ' || to_char(v_t.data, 'DD/MM') || ' agora é de ' || v_para || '.', 'troca-' || x.id);
  perform _push_func(x.para_funcionario_id, '✅ Troca aprovada', 'Você assumiu o turno de ' || to_char(v_t.data, 'DD/MM') || ' (' || to_char(v_t.inicio, 'HH24:MI') || '–' || to_char(v_t.fim, 'HH24:MI') || ').', 'troca-' || x.id);
  perform _auditar('Escala: troca aprovada', v_de || ' → ' || v_para || ' | ' || v_t.data);
  return jsonb_build_object('ok', true, 'message', 'Troca aprovada: o turno passou para ' || v_para || '.');
end $$;

create or replace function public.api_trocas_lista(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); v_adm boolean := tem_nivel('Admin'); v_l jsonb;
begin
  if auth_nivel() is null then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'turnoId', x.turno_id, 'data', t.data, 'inicio', to_char(t.inicio, 'HH24:MI'), 'fim', to_char(t.fim, 'HH24:MI'),
      'de', fd.nome, 'para', fp.nome, 'deId', x.de_funcionario_id, 'paraId', x.para_funcionario_id, 'motivo', x.motivo, 'resposta', x.resposta,
      'euSolicitei', x.de_funcionario_id = v_eu, 'euSouColega', x.para_funcionario_id = v_eu) order by (x.status like 'Aguardando%') desc, x.criado_em desc), '[]'::jsonb) into v_l
    from escala_trocas x join escala_turnos t on t.id = x.turno_id join funcionarios fd on fd.id = x.de_funcionario_id join funcionarios fp on fp.id = x.para_funcionario_id
   where (v_adm or x.de_funcionario_id = v_eu or x.para_funcionario_id = v_eu) and (x.status like 'Aguardando%' or x.atualizado_em > now() - interval '7 days');
  return jsonb_build_object('ok', true, 'trocas', v_l, 'admin', v_adm, 'vinculado', v_eu is not null);
end $$;

-- ---------- ponto ----------
create or replace function public.api_ponto_estado(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_ini date; v_h numeric;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return jsonb_build_object('ok', true, 'vinculado', false); end if;
  v_ini := _escala_segunda(v_hoje);
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  select coalesce(round(sum(extract(epoch from coalesce(saida, now()) - entrada)) / 3600.0, 2), 0) into v_h from ponto_registros
   where funcionario_id = v_eu and not cancelado and (entrada at time zone 'America/Sao_Paulo')::date between v_ini and v_ini + 6;
  return jsonb_build_object('ok', true, 'vinculado', true, 'aberto', r.id is not null, 'entrada', r.entrada, 'horasSemana', v_h);
end $$;

create or replace function public.api_ponto_bater(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return _falha('Seu acesso ainda não está ligado a um funcionário. Peça ao dono para usar "Importar acessos" na Escala.'); end if;
  perform pg_advisory_xact_lock(hashtext('ponto:' || v_eu));
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  if r.id is not null and r.entrada > now() - interval '20 seconds' then return jsonb_build_object('ok', true, 'message', 'Já registrado agora há pouco.', 'aberto', true); end if;
  if r.id is not null and r.entrada > now() - interval '20 hours' then
    update ponto_registros set saida = now() where id = r.id;
    return jsonb_build_object('ok', true, 'aberto', false, 'message', 'Saída registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '. Trabalhou ' || to_char(round(extract(epoch from now() - r.entrada) / 3600.0, 2), 'FM990.00') || ' h neste turno.');
  end if;
  insert into ponto_registros (funcionario_id, entrada) values (v_eu, now());
  return jsonb_build_object('ok', true, 'aberto', true, 'message', 'Entrada registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '.' || case when r.id is not null then ' (A saída anterior ficou sem registro; o dono pode corrigir.)' else '' end);
end $$;

create or replace function public.api_ponto_relatorio(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_ini date := coalesce(nullif(p->>'inicio', '')::date, _escala_segunda((now() at time zone 'America/Sao_Paulo')::date)); v_fim date := coalesce(nullif(p->>'fim', '')::date, v_ini + 6); v_l jsonb; v_r jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_fim < v_ini or v_fim - v_ini > 62 then return _falha('Período inválido (máximo de 62 dias).'); end if;
  with reg as (
    select r.funcionario_id, r.id, r.entrada, r.saida, r.observacao, r.origem, (r.entrada at time zone 'America/Sao_Paulo')::date dia,
           extract(epoch from coalesce(r.saida, now()) - r.entrada) / 3600.0 h
      from ponto_registros r where not r.cancelado and (r.entrada at time zone 'America/Sao_Paulo')::date between v_ini and v_fim),
  sem as (select funcionario_id, _escala_segunda(dia) semana, sum(h) h from reg group by 1, 2),
  extra as (select funcionario_id, sum(greatest(h - 44, 0)) ex from sem group by 1),
  esc as (select t.funcionario_id, sum(extract(epoch from (t.data + t.fim + case when t.fim <= t.inicio then interval '1 day' else interval '0' end) - (t.data + t.inicio)) / 3600.0) h
            from escala_turnos t where t.tipo = 'Trabalho' and not t.cancelado and t.data between v_ini and v_fim group by 1),
  tot as (select funcionario_id, sum(h) h from reg group by 1)
  select coalesce(jsonb_agg(jsonb_build_object('funcionarioId', f.id, 'nome', f.nome, 'cargo', f.cargo,
      'horasFeitas', round(coalesce(tot.h, 0)::numeric, 2), 'horasEscaladas', round(coalesce(esc.h, 0)::numeric, 2),
      'diferenca', round((coalesce(tot.h, 0) - coalesce(esc.h, 0))::numeric, 2), 'horasExtras', round(coalesce(extra.ex, 0)::numeric, 2),
      'aberto', exists (select 1 from reg where reg.funcionario_id = f.id and reg.saida is null),
      'registros', coalesce((select jsonb_agg(jsonb_build_object('id', reg.id, 'dia', reg.dia, 'entrada', to_char(reg.entrada at time zone 'America/Sao_Paulo', 'HH24:MI'), 'saida', to_char(reg.saida at time zone 'America/Sao_Paulo', 'HH24:MI'),
          'horas', round(reg.h::numeric, 2), 'origem', reg.origem, 'observacao', reg.observacao) order by reg.entrada) from reg where reg.funcionario_id = f.id), '[]'::jsonb)
    ) order by f.nome), '[]'::jsonb) into v_l
    from funcionarios f left join tot on tot.funcionario_id = f.id left join esc on esc.funcionario_id = f.id left join extra on extra.funcionario_id = f.id
   where f.ativo or tot.h is not null;
  return jsonb_build_object('ok', true, 'inicio', v_ini, 'fim', v_fim, 'pessoas', v_l);
end $$;

-- lançar / corrigir / cancelar um registro (datas e horas no horário de Brasília)
create or replace function public.api_ponto_ajustar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_f uuid := _uuid(p->>'funcionarioId'); v_ent timestamptz; v_sai timestamptz; v_nome text; v_obs text := left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 200);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'cancelar', '') = 'true' then
    update ponto_registros set cancelado = true, observacao = coalesce(v_obs, observacao) where id = v_id and not cancelado returning funcionario_id into v_f;
    if v_f is null then return _falha('Registro não encontrado.'); end if;
    perform _auditar('Ponto: registro cancelado', (select nome from funcionarios where id = v_f));
    return jsonb_build_object('ok', true, 'message', 'Registro cancelado.');
  end if;
  begin
    v_ent := (p->>'entrada')::timestamp at time zone 'America/Sao_Paulo';
    v_sai := nullif(p->>'saida', '')::timestamp at time zone 'America/Sao_Paulo';
  exception when others then return _falha('Data ou hora inválida.'); end;
  if v_ent is null then return _falha('Informe a entrada.'); end if;
  if v_sai is not null and v_sai <= v_ent then return _falha('A saída precisa ser depois da entrada.'); end if;
  if v_sai is not null and v_sai - v_ent > interval '20 hours' then return _falha('Turno de mais de 20 horas: confira as datas.'); end if;
  if v_id is not null then select funcionario_id into v_f from ponto_registros where id = v_id; end if;
  select nome into v_nome from funcionarios where id = v_f;
  if v_nome is null then return _falha('Funcionário não encontrado.'); end if;
  if v_id is null then insert into ponto_registros (funcionario_id, entrada, saida, origem, observacao) values (v_f, v_ent, v_sai, 'dono', coalesce(v_obs, 'Lançado pelo dono'));
  else update ponto_registros set entrada = v_ent, saida = v_sai, origem = 'dono', observacao = coalesce(v_obs, observacao) where id = v_id and not cancelado;
    if not found then return _falha('Registro não encontrado.'); end if; end if;
  perform _auditar('Ponto: registro salvo', v_nome || ' | ' || v_ent || coalesce(' → ' || v_sai, ''));
  return jsonb_build_object('ok', true, 'message', 'Registro salvo.');
end $$;

-- aviso ao dono: saída esquecida (entrada aberta há mais de 14 horas)
create or replace function public.ponto_pendencias_cron() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare ativos text[] := '{}'; r record; v_chave text;
begin
  for r in select pr.id, f.nome, pr.entrada from ponto_registros pr join funcionarios f on f.id = pr.funcionario_id where pr.saida is null and not pr.cancelado and pr.entrada < now() - interval '14 hours' loop
    v_chave := 'sis:venc:ponto:' || r.id; ativos := array_append(ativos, v_chave);
    perform _alertas_sistema_avisar(v_chave, 'Ponto sem saída: ' || r.nome, r.nome || ' bateu a entrada em ' || to_char(r.entrada at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' e não bateu a saída. Corrija em Loja e equipe → Ponto.', interval '1 day');
  end loop;
  update alertas_envios set resolvido_em = now() where tipo = 'sistema' and resolvido_em is null and chave like 'sis:venc:ponto:%' and not (chave = any(ativos));
  return jsonb_build_object('ok', true, 'pendentes', to_jsonb(ativos));
end $$;
select cron.schedule('ponto-pendencias-dia', '0 13 * * *', 'select public.ponto_pendencias_cron()');

do $$ declare f text; begin
  foreach f in array array['api_escala_avisar(jsonb)', 'api_troca_solicitar(jsonb)', 'api_troca_responder(jsonb)', 'api_troca_decidir(jsonb)', 'api_trocas_lista(jsonb)',
      'api_ponto_estado(jsonb)', 'api_ponto_bater(jsonb)', 'api_ponto_relatorio(jsonb)', 'api_ponto_ajustar(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
  revoke all on function public.ponto_pendencias_cron() from public, anon, authenticated;
end $$;
