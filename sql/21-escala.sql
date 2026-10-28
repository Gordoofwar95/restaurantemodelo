-- =====================================================================
-- 21 · ESCALA DE TRABALHO DA EQUIPE (18/10/2026)
-- Escala semanal de todos os funcionários: turnos (trabalho, folga, férias, falta, atestado), padrão semanal por pessoa, copiar semana,
-- aplicar o padrão em várias semanas, total de horas por semana e "Minha escala" para cada pessoa ver o seu horário.
-- Cada funcionário pode ser ligado ao seu acesso (login). O Admin importa os acessos já existentes com um botão.
-- Falta e atestado só o Admin vê (os demais veem "Ausente"). Turno removido fica guardado como cancelado (histórico).
-- Aditivo: 2 tabelas, 1 coluna, 9 funções (2 recriadas). Pode rodar de novo sem erro. Rode DEPOIS do 20.
-- =====================================================================
alter table public.funcionarios add column if not exists usuario_id uuid;
create unique index if not exists funcionarios_usuario_uq on public.funcionarios (usuario_id) where usuario_id is not null;

create table if not exists public.escala_turnos (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id),
  data date not null,
  tipo text not null default 'Trabalho' check (tipo in ('Trabalho', 'Folga', 'Férias', 'Falta', 'Atestado')),
  inicio time,
  fim time,
  funcao text,
  observacao text,
  cancelado boolean not null default false,
  criado_em timestamptz not null default now(),
  check (tipo <> 'Trabalho' or (inicio is not null and fim is not null and inicio <> fim))
);
create index if not exists escala_turnos_data_idx on public.escala_turnos (data, funcionario_id);
create table if not exists public.escala_padrao (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id),
  dia_semana int not null check (dia_semana between 0 and 6),
  tipo text not null default 'Trabalho' check (tipo in ('Trabalho', 'Folga')),
  inicio time,
  fim time,
  funcao text,
  unique (funcionario_id, dia_semana),
  check (tipo = 'Folga' or (inicio is not null and fim is not null and inicio <> fim))
);
alter table public.escala_turnos enable row level security;
alter table public.escala_padrao enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'escala_turnos' and policyname = 'escala_turnos_ler_admin') then
    create policy escala_turnos_ler_admin on public.escala_turnos for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'escala_padrao' and policyname = 'escala_padrao_ler_admin') then
    create policy escala_padrao_ler_admin on public.escala_padrao for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
end $$;
revoke all on public.escala_turnos, public.escala_padrao from anon, authenticated;
grant select on public.escala_turnos, public.escala_padrao to authenticated;
grant all on public.escala_turnos, public.escala_padrao to service_role;

-- funções do 20 recriadas com a ligação ao acesso (login)
create or replace function public.api_equipe_folha(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_mes text := coalesce(nullif(p->>'mes', ''), to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM')); v_f jsonb; v_p jsonb; v_prev numeric; v_pago numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_mes !~ '^\d{4}-\d{2}$' then return _falha('Mês inválido.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'usuarioId', f.usuario_id, 'nome', f.nome, 'cargo', f.cargo, 'telefone', f.telefone, 'admissao', f.admissao, 'salario', f.salario, 'diaPagamento', f.dia_pagamento,
      'encargosPct', f.encargos_pct, 'provisao', f.provisao, 'ativo', f.ativo, 'desligadoEm', f.desligado_em, 'observacao', f.observacao,
      'custoMensal', round(f.salario * (1 + f.encargos_pct / 100.0) + case when f.provisao then f.salario / 12.0 * (1 + 4.0 / 3) else 0 end, 2),
      'pagoSalario', coalesce(s.pago, 0), 'saldo', greatest(round(f.salario - coalesce(s.pago, 0), 2), 0)
    ) order by f.ativo desc, f.nome), '[]'::jsonb) into v_f
    from funcionarios f
    left join lateral (select sum(valor) pago from funcionario_pagamentos x where x.funcionario_id = f.id and x.competencia = v_mes and x.status = 'Paga' and x.tipo in ('Salário', 'Adiantamento', 'Vale')) s on true;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'funcionarioId', x.funcionario_id, 'nome', f.nome, 'cargo', f.cargo, 'competencia', x.competencia, 'tipo', x.tipo,
      'valor', x.valor, 'encargos', x.encargos, 'pagoEm', x.pago_em, 'observacao', x.observacao, 'status', x.status, 'motivo', x.motivo_cancelamento) order by x.pago_em desc), '[]'::jsonb) into v_p
    from funcionario_pagamentos x join funcionarios f on f.id = x.funcionario_id where x.competencia = v_mes;
  select coalesce(sum(salario), 0) into v_prev from funcionarios where ativo;
  select coalesce(sum(valor), 0) into v_pago from funcionario_pagamentos where competencia = v_mes and status = 'Paga';
  return jsonb_build_object('ok', true, 'mes', v_mes, 'funcionarios', v_f, 'pagamentos', v_p, 'previsto', v_prev, 'pago', v_pago);
end $$;

create or replace function public.api_salvar_funcionario(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_nome text := btrim(coalesce(p->>'nome', '')); v_sal numeric := round(_num(p->>'salario'), 2);
        v_dia int := coalesce(nullif(p->>'diaPagamento', '')::int, 5); v_enc numeric := _num(p->>'encargosPct', 0); v_ativo boolean := coalesce((p->>'ativo')::boolean, true); v_usr uuid := nullif(p->>'usuarioId', '')::uuid;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_nome = '' then return _falha('Informe o nome do funcionário.'); end if;
  if v_sal < 0 or v_sal > 999999 then return _falha('Salário inválido.'); end if;
  if v_dia < 1 or v_dia > 31 then return _falha('O dia de pagamento precisa ficar entre 1 e 31.'); end if;
  if v_enc < 0 or v_enc > 100 then return _falha('Encargos entre 0 e 100%.'); end if;
  if v_usr is not null and exists (select 1 from funcionarios where usuario_id = v_usr and id is distinct from v_id) then return _falha('Esse acesso já está ligado a outro funcionário.'); end if;
  if v_id is null then
    insert into funcionarios (nome, cargo, telefone, admissao, salario, dia_pagamento, encargos_pct, provisao, ativo, observacao, usuario_id)
    values (left(v_nome, 80), left(nullif(btrim(coalesce(p->>'cargo', '')), ''), 60), left(nullif(btrim(coalesce(p->>'telefone', '')), ''), 30), nullif(p->>'admissao', '')::date,
            v_sal, v_dia, v_enc, coalesce((p->>'provisao')::boolean, false), true, left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 300), v_usr);
    perform _auditar('Funcionário cadastrado', left(v_nome, 80) || ' | salário R$ ' || _dinheiro(v_sal));
    return jsonb_build_object('ok', true, 'message', 'Funcionário cadastrado.');
  end if;
  update funcionarios set nome = left(v_nome, 80), cargo = left(nullif(btrim(coalesce(p->>'cargo', '')), ''), 60), telefone = left(nullif(btrim(coalesce(p->>'telefone', '')), ''), 30),
         admissao = nullif(p->>'admissao', '')::date, salario = v_sal, dia_pagamento = v_dia, encargos_pct = v_enc, provisao = coalesce((p->>'provisao')::boolean, false),
         ativo = v_ativo, desligado_em = case when v_ativo then null else coalesce(nullif(p->>'desligadoEm', '')::date, current_date) end,
         observacao = left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 300), usuario_id = v_usr
   where id = v_id;
  if not found then return _falha('Funcionário não encontrado.'); end if;
  perform _auditar('Funcionário alterado', left(v_nome, 80) || ' | salário R$ ' || _dinheiro(v_sal) || case when v_ativo then '' else ' | desligado' end);
  return jsonb_build_object('ok', true, 'message', 'Funcionário salvo.');
end $$;

-- Segunda-feira da semana de uma data
create or replace function public._escala_segunda(d date) returns date language sql immutable as $$ select d - ((extract(isodow from d)::int) - 1) $$;

-- Semana: Admin vê tudo; os demais perfis veem só horários de quem trabalha (sem falta/atestado e sem salário)
create or replace function public.api_escala_semana(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_ini date; v_fim date; v_adm boolean := tem_nivel('Admin'); v_f jsonb; v_t jsonb; v_p jsonb := '[]'::jsonb;
begin
  if auth_nivel() is null then return _negado(); end if;
  v_ini := _escala_segunda(coalesce(nullif(p->>'inicio', '')::date, (now() at time zone 'America/Sao_Paulo')::date));
  v_fim := v_ini + 6;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'cargo', f.cargo, 'ativo', f.ativo, 'usuarioId', case when v_adm then f.usuario_id end) order by f.nome), '[]'::jsonb) into v_f
    from funcionarios f where f.ativo or (v_adm and exists (select 1 from escala_turnos t where t.funcionario_id = f.id and t.data between v_ini and v_fim and not t.cancelado));
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'funcionarioId', t.funcionario_id, 'data', t.data,
           'tipo', case when v_adm or t.tipo in ('Trabalho', 'Folga', 'Férias') then t.tipo else 'Ausente' end,
           'inicio', to_char(t.inicio, 'HH24:MI'), 'fim', to_char(t.fim, 'HH24:MI'), 'funcao', t.funcao,
           'observacao', case when v_adm then t.observacao end) order by t.data, t.inicio), '[]'::jsonb) into v_t
    from escala_turnos t where t.data between v_ini and v_fim and not t.cancelado;
  if v_adm then
    select coalesce(jsonb_agg(jsonb_build_object('funcionarioId', funcionario_id, 'dia', dia_semana, 'tipo', tipo, 'inicio', to_char(inicio, 'HH24:MI'), 'fim', to_char(fim, 'HH24:MI'), 'funcao', funcao)), '[]'::jsonb) into v_p from escala_padrao;
  end if;
  return jsonb_build_object('ok', true, 'inicio', v_ini, 'fim', v_fim, 'funcionarios', v_f, 'turnos', v_t, 'padrao', v_p, 'admin', v_adm);
end $$;

-- Criar / editar / cancelar um turno
create or replace function public.api_salvar_turno(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_f uuid := _uuid(p->>'funcionarioId'); v_data date := nullif(p->>'data', '')::date; v_tipo text := coalesce(nullif(p->>'tipo', ''), 'Trabalho');
        v_ini time := nullif(p->>'inicio', '')::time; v_fim time := nullif(p->>'fim', '')::time; v_nome text; v_ocupa text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select nome into v_nome from funcionarios where id = v_f;
  if v_nome is null then return _falha('Funcionário não encontrado.'); end if;
  if v_data is null then return _falha('Informe a data.'); end if;
  if coalesce(p->>'cancelar', '') = 'true' then
    update escala_turnos set cancelado = true where id = v_id and not cancelado;
    if not found then return _falha('Turno não encontrado.'); end if;
    perform _auditar('Escala: turno removido', v_nome || ' | ' || v_data);
    return jsonb_build_object('ok', true, 'message', 'Turno removido.');
  end if;
  if v_tipo <> all (array['Trabalho', 'Folga', 'Férias', 'Falta', 'Atestado']) then return _falha('Tipo inválido.'); end if;
  if v_tipo = 'Trabalho' then
    if v_ini is null or v_fim is null or v_ini = v_fim then return _falha('Informe o horário de entrada e de saída (diferentes).'); end if;
    if exists (select 1 from escala_turnos t where t.funcionario_id = v_f and t.data = v_data and t.tipo = 'Trabalho' and not t.cancelado and t.id is distinct from v_id
               and tsrange(v_data + t.inicio, v_data + t.fim + case when t.fim <= t.inicio then interval '1 day' else interval '0' end)
                && tsrange(v_data + v_ini, v_data + v_fim + case when v_fim <= v_ini then interval '1 day' else interval '0' end)) then
      return _falha(v_nome || ' já tem um turno que se sobrepõe a esse horário no dia ' || to_char(v_data, 'DD/MM') || '.');
    end if;
    select string_agg(distinct t.tipo, ', ') into v_ocupa from escala_turnos t where t.funcionario_id = v_f and t.data = v_data and t.tipo in ('Folga', 'Férias', 'Atestado') and not t.cancelado and t.id is distinct from v_id;
    if v_ocupa is not null and coalesce(p->>'confirmado', '') <> 'true' then
      return jsonb_build_object('ok', false, 'confirmar', true, 'message', v_nome || ' está marcado como ' || lower(v_ocupa) || ' em ' || to_char(v_data, 'DD/MM') || '. Escalar para trabalhar mesmo assim?');
    end if;
  else v_ini := null; v_fim := null; end if;
  if v_id is null then
    insert into escala_turnos (funcionario_id, data, tipo, inicio, fim, funcao, observacao)
    values (v_f, v_data, v_tipo, v_ini, v_fim, left(nullif(btrim(coalesce(p->>'funcao', '')), ''), 40), left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 200));
  else
    update escala_turnos set funcionario_id = v_f, data = v_data, tipo = v_tipo, inicio = v_ini, fim = v_fim, funcao = left(nullif(btrim(coalesce(p->>'funcao', '')), ''), 40), observacao = left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 200)
     where id = v_id and not cancelado;
    if not found then return _falha('Turno não encontrado.'); end if;
  end if;
  perform _auditar('Escala: turno salvo', v_nome || ' | ' || v_data || ' | ' || v_tipo || coalesce(' ' || to_char(v_ini, 'HH24:MI') || '-' || to_char(v_fim, 'HH24:MI'), ''));
  return jsonb_build_object('ok', true, 'message', 'Escala salva.');
end $$;

-- Padrão semanal de uma pessoa (7 dias: trabalho com horário, ou folga)
create or replace function public.api_escala_padrao_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_f uuid := _uuid(p->>'funcionarioId'); d jsonb; v_dia int; v_tipo text; v_ini time; v_fim time; v_nome text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select nome into v_nome from funcionarios where id = v_f;
  if v_nome is null then return _falha('Funcionário não encontrado.'); end if;
  for d in select value from jsonb_array_elements(coalesce(p->'dias', '[]'::jsonb)) loop
    v_dia := (d->>'dia')::int; v_tipo := case when d->>'tipo' = 'Trabalho' then 'Trabalho' else 'Folga' end;
    v_ini := nullif(d->>'inicio', '')::time; v_fim := nullif(d->>'fim', '')::time;
    if v_dia is null or v_dia < 0 or v_dia > 6 then return _falha('Dia da semana inválido.'); end if;
    if v_tipo = 'Trabalho' and (v_ini is null or v_fim is null or v_ini = v_fim) then return _falha('Informe entrada e saída (diferentes) nos dias de trabalho.'); end if;
    if v_tipo = 'Folga' then v_ini := null; v_fim := null; end if;
    insert into escala_padrao (funcionario_id, dia_semana, tipo, inicio, fim, funcao) values (v_f, v_dia, v_tipo, v_ini, v_fim, left(nullif(btrim(coalesce(d->>'funcao', '')), ''), 40))
    on conflict (funcionario_id, dia_semana) do update set tipo = excluded.tipo, inicio = excluded.inicio, fim = excluded.fim, funcao = excluded.funcao;
  end loop;
  perform _auditar('Escala: padrão semanal salvo', v_nome);
  return jsonb_build_object('ok', true, 'message', 'Padrão semanal de ' || v_nome || ' salvo.');
end $$;

-- Aplicar o padrão semanal em N semanas (só preenche os dias que ainda não têm nada para a pessoa)
create or replace function public.api_escala_aplicar_padrao(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_ini date := _escala_segunda(coalesce(nullif(p->>'inicio', '')::date, current_date)); v_sem int := greatest(1, least(coalesce(nullif(p->>'semanas', '')::int, 1), 12)); v_n int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  with dias as (select (v_ini + g)::date as dia from generate_series(0, v_sem * 7 - 1) g),
  novos as (
    insert into escala_turnos (funcionario_id, data, tipo, inicio, fim, funcao)
    select e.funcionario_id, d.dia, e.tipo, e.inicio, e.fim, e.funcao
      from dias d join escala_padrao e on e.dia_semana = extract(dow from d.dia)::int
      join funcionarios f on f.id = e.funcionario_id and f.ativo
     where not exists (select 1 from escala_turnos t where t.funcionario_id = e.funcionario_id and t.data = d.dia and not t.cancelado)
    returning 1)
  select count(*) into v_n from novos;
  perform _auditar('Escala: padrão aplicado', v_sem || ' semana(s) a partir de ' || v_ini || ' | ' || v_n || ' turno(s)');
  return jsonb_build_object('ok', true, 'message', v_n || ' turno(s) criados' || case when v_n = 0 then ' (nada novo: os dias já estavam preenchidos ou falta definir o padrão de cada pessoa).' else '.' end, 'criados', v_n);
end $$;

-- Copiar uma semana para outra (dias que ainda estão vazios; falta e atestado não são copiados)
create or replace function public.api_escala_copiar_semana(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_de date := _escala_segunda(nullif(p->>'de', '')::date); v_para date := _escala_segunda(nullif(p->>'para', '')::date); v_n int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_de is null or v_para is null or v_de = v_para then return _falha('Escolha duas semanas diferentes.'); end if;
  with novos as (
    insert into escala_turnos (funcionario_id, data, tipo, inicio, fim, funcao, observacao)
    select t.funcionario_id, t.data + (v_para - v_de), t.tipo, t.inicio, t.fim, t.funcao, t.observacao
      from escala_turnos t join funcionarios f on f.id = t.funcionario_id and f.ativo
     where t.data between v_de and v_de + 6 and not t.cancelado and t.tipo in ('Trabalho', 'Folga', 'Férias')
       and not exists (select 1 from escala_turnos x where x.funcionario_id = t.funcionario_id and x.data = t.data + (v_para - v_de) and not x.cancelado)
    returning 1)
  select count(*) into v_n from novos;
  perform _auditar('Escala: semana copiada', v_de || ' para ' || v_para || ' | ' || v_n || ' turno(s)');
  return jsonb_build_object('ok', true, 'message', v_n || ' turno(s) copiados.', 'criados', v_n);
end $$;

-- Importar os acessos (logins) ativos que ainda não são funcionários
create or replace function public.api_equipe_importar_acessos(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_n int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  with novos as (
    insert into funcionarios (nome, cargo, telefone, salario, dia_pagamento, usuario_id)
    select left(u.nome, 80), u.nivel::text, left(u.telefone, 30), 0, 5, u.id from usuarios u
     where u.ativo and u.nivel::text <> 'Desenvolvedor' and not exists (select 1 from funcionarios f where f.usuario_id = u.id)
    returning 1)
  select count(*) into v_n from novos;
  perform _auditar('Equipe: acessos importados como funcionários', v_n || ' pessoa(s)');
  return jsonb_build_object('ok', true, 'message', v_n || ' pessoa(s) importadas. Complete salário e dia de pagamento de cada uma, se quiser controlar os pagamentos.', 'criados', v_n);
end $$;

-- Minha escala: os próximos dias de quem está ligado a um funcionário
create or replace function public.api_minha_escala(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_f uuid; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_t jsonb;
begin
  if auth_nivel() is null then return _negado(); end if;
  select id into v_f from funcionarios where usuario_id = auth.uid() and ativo;
  if v_f is null then return jsonb_build_object('ok', true, 'vinculado', false, 'turnos', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('data', t.data, 'tipo', case when t.tipo in ('Falta', 'Atestado') then 'Ausente' else t.tipo end,
           'inicio', to_char(t.inicio, 'HH24:MI'), 'fim', to_char(t.fim, 'HH24:MI'), 'funcao', t.funcao) order by t.data, t.inicio), '[]'::jsonb) into v_t
    from escala_turnos t where t.funcionario_id = v_f and t.data between v_hoje and v_hoje + 13 and not t.cancelado;
  return jsonb_build_object('ok', true, 'vinculado', true, 'turnos', v_t);
end $$;

do $$ declare f text; begin
  foreach f in array array['api_escala_semana(jsonb)', 'api_salvar_turno(jsonb)', 'api_escala_padrao_salvar(jsonb)', 'api_escala_aplicar_padrao(jsonb)', 'api_escala_copiar_semana(jsonb)', 'api_equipe_importar_acessos(jsonb)', 'api_minha_escala(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
