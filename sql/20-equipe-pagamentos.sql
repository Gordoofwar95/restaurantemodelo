-- =====================================================================
-- 20 · EQUIPE E PAGAMENTOS (folha simples) (18/10/2026)
-- Ficha do funcionário (nome, cargo, salário, dia de pagamento, % de encargos que o contador informar, provisão de 13º/férias),
-- botão "Pagar" que lança a despesa em "Salários" (e, se quiser, os encargos como conta a pagar), histórico por mês, cancelamento
-- (com senha do Admin) e aviso ao Admin quando o pagamento do mês passou do dia e ainda não foi registrado.
-- Só o Admin vê e mexe. Aditivo: 2 tabelas, 5 funções, 1 agendamento. Pode rodar de novo sem erro.
-- =====================================================================
create table if not exists public.funcionarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cargo text,
  telefone text,
  admissao date,
  salario numeric(10,2) not null default 0 check (salario >= 0),
  dia_pagamento int not null default 5 check (dia_pagamento between 1 and 31),
  encargos_pct numeric(5,2) not null default 0 check (encargos_pct between 0 and 100),
  provisao boolean not null default false,
  ativo boolean not null default true,
  desligado_em date,
  observacao text,
  criado_em timestamptz not null default now()
);
create table if not exists public.funcionario_pagamentos (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id),
  competencia text not null check (competencia ~ '^\d{4}-\d{2}$'),
  tipo text not null default 'Salário',
  valor numeric(10,2) not null check (valor > 0),
  encargos numeric(10,2) not null default 0,
  despesa_id uuid,
  despesa_encargos_id uuid,
  pago_em timestamptz not null default now(),
  observacao text,
  status text not null default 'Paga',
  motivo_cancelamento text,
  criado_em timestamptz not null default now()
);
create index if not exists funcionario_pagamentos_comp_idx on public.funcionario_pagamentos (competencia, funcionario_id);

alter table public.funcionarios enable row level security;
alter table public.funcionario_pagamentos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'funcionarios' and policyname = 'funcionarios_ler_admin') then
    create policy funcionarios_ler_admin on public.funcionarios for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'funcionario_pagamentos' and policyname = 'funcionario_pagamentos_ler_admin') then
    create policy funcionario_pagamentos_ler_admin on public.funcionario_pagamentos for select to authenticated using (public.tem_nivel(variadic array['Admin'::public.nivel_acesso]));
  end if;
end $$;
revoke all on public.funcionarios, public.funcionario_pagamentos from anon, authenticated;
grant select on public.funcionarios, public.funcionario_pagamentos to authenticated;
grant all on public.funcionarios, public.funcionario_pagamentos to service_role;

-- 1) Tela: funcionários + pagamentos do mês + resumo
create or replace function public.api_equipe_folha(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_mes text := coalesce(nullif(p->>'mes', ''), to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM')); v_f jsonb; v_p jsonb; v_prev numeric; v_pago numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_mes !~ '^\d{4}-\d{2}$' then return _falha('Mês inválido.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'nome', f.nome, 'cargo', f.cargo, 'telefone', f.telefone, 'admissao', f.admissao, 'salario', f.salario, 'diaPagamento', f.dia_pagamento,
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

-- 2) Criar / editar funcionário
create or replace function public.api_salvar_funcionario(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_nome text := btrim(coalesce(p->>'nome', '')); v_sal numeric := round(_num(p->>'salario'), 2);
        v_dia int := coalesce(nullif(p->>'diaPagamento', '')::int, 5); v_enc numeric := _num(p->>'encargosPct', 0); v_ativo boolean := coalesce((p->>'ativo')::boolean, true);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_nome = '' then return _falha('Informe o nome do funcionário.'); end if;
  if v_sal < 0 or v_sal > 999999 then return _falha('Salário inválido.'); end if;
  if v_dia < 1 or v_dia > 31 then return _falha('O dia de pagamento precisa ficar entre 1 e 31.'); end if;
  if v_enc < 0 or v_enc > 100 then return _falha('Encargos entre 0 e 100%.'); end if;
  if v_id is null then
    insert into funcionarios (nome, cargo, telefone, admissao, salario, dia_pagamento, encargos_pct, provisao, ativo, observacao)
    values (left(v_nome, 80), left(nullif(btrim(coalesce(p->>'cargo', '')), ''), 60), left(nullif(btrim(coalesce(p->>'telefone', '')), ''), 30), nullif(p->>'admissao', '')::date,
            v_sal, v_dia, v_enc, coalesce((p->>'provisao')::boolean, false), true, left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 300));
    perform _auditar('Funcionário cadastrado', left(v_nome, 80) || ' | salário R$ ' || _dinheiro(v_sal));
    return jsonb_build_object('ok', true, 'message', 'Funcionário cadastrado.');
  end if;
  update funcionarios set nome = left(v_nome, 80), cargo = left(nullif(btrim(coalesce(p->>'cargo', '')), ''), 60), telefone = left(nullif(btrim(coalesce(p->>'telefone', '')), ''), 30),
         admissao = nullif(p->>'admissao', '')::date, salario = v_sal, dia_pagamento = v_dia, encargos_pct = v_enc, provisao = coalesce((p->>'provisao')::boolean, false),
         ativo = v_ativo, desligado_em = case when v_ativo then null else coalesce(nullif(p->>'desligadoEm', '')::date, current_date) end,
         observacao = left(nullif(btrim(coalesce(p->>'observacao', '')), ''), 300)
   where id = v_id;
  if not found then return _falha('Funcionário não encontrado.'); end if;
  perform _auditar('Funcionário alterado', left(v_nome, 80) || ' | salário R$ ' || _dinheiro(v_sal) || case when v_ativo then '' else ' | desligado' end);
  return jsonb_build_object('ok', true, 'message', 'Funcionário salvo.');
end $$;

-- 3) Pagar: lança a despesa em "Salários" (e os encargos como conta a pagar, se pedido)
create or replace function public.api_pagar_funcionario(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare f funcionarios%rowtype; v_req text := nullif(p->>'requisicaoId', ''); v_r jsonb; v_tipo text := coalesce(nullif(p->>'tipo', ''), 'Salário');
        v_comp text := coalesce(nullif(p->>'competencia', ''), to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM')); v_valor numeric := round(_num(p->>'valor'), 2);
        v_caixa boolean := coalesce(p->>'saiuDoCaixa', '') = 'true'; v_pago numeric; v_desp uuid; v_enc numeric := 0; v_desp_enc uuid; v_mm text; v_venc date; v_obs text := left(coalesce(p->>'observacao', ''), 300);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_req is not null then perform pg_advisory_xact_lock(hashtext(v_req)); v_r := _idem_ler(v_req); if v_r is not null then return v_r; end if; end if;
  select * into f from funcionarios where id = _uuid(p->>'funcionarioId') for update;
  if not found then return _falha('Funcionário não encontrado.'); end if;
  if v_tipo <> all (array['Salário', 'Adiantamento', 'Vale', 'Hora extra / diária', 'Comissão', '13º salário', 'Férias', 'Outro']) then return _falha('Tipo de pagamento inválido.'); end if;
  if v_comp !~ '^\d{4}-\d{2}$' then return _falha('Mês inválido.'); end if;
  if v_valor <= 0 then return _falha('Informe um valor maior que zero.'); end if;
  if v_valor > 999999 then return _falha('Valor alto demais.'); end if;
  if v_caixa and not exists (select 1 from caixa_sessoes where status = 'Aberto') then return _falha('Abra o caixa para registrar um pagamento que sai do caixa.'); end if;
  select coalesce(sum(valor), 0) into v_pago from funcionario_pagamentos where funcionario_id = f.id and competencia = v_comp and status = 'Paga' and tipo in ('Salário', 'Adiantamento', 'Vale');
  if v_tipo in ('Salário', 'Adiantamento', 'Vale') and f.salario > 0 and v_pago + v_valor > f.salario + 0.009 and coalesce(p->>'confirmado', '') <> 'true' then
    return jsonb_build_object('ok', false, 'confirmar', true, 'message', 'Em ' || right(v_comp, 2) || '/' || left(v_comp, 4) || ' já foram pagos R$ ' || _dinheiro(v_pago) || ' de R$ ' || _dinheiro(f.salario) || '. Com este pagamento passa do salário. Confirma?');
  end if;
  v_mm := right(v_comp, 2) || '/' || left(v_comp, 4);
  insert into despesas (data_hora, descricao, valor, observacao, status, categoria, situacao, competencia, saiu_do_caixa)
  values (now(), v_tipo || ' — ' || f.nome || ' (' || v_mm || ')', v_valor, v_obs, 'Paga', 'Salários', 'Paga', v_comp, v_caixa) returning id into v_desp;
  if coalesce(p->>'lancarEncargos', '') = 'true' and f.encargos_pct > 0 and v_tipo in ('Salário', '13º salário', 'Férias') then
    v_enc := round(v_valor * f.encargos_pct / 100.0, 2);
    v_venc := (date_trunc('month', to_date(v_comp || '-01', 'YYYY-MM-DD')) + interval '1 month' + interval '19 days')::date;   -- dia 20 do mês seguinte (ajuste na conta a pagar se for outro)
    insert into despesas (data_hora, descricao, valor, observacao, status, categoria, vencimento, situacao, competencia, saiu_do_caixa)
    values (_meio_dia(v_venc), 'Encargos — ' || f.nome || ' (' || v_mm || ')', v_enc, 'Encargos de ' || f.encargos_pct || '% sobre ' || v_tipo, 'A pagar', 'Impostos', v_venc, 'A pagar', v_comp, true) returning id into v_desp_enc;
  end if;
  insert into funcionario_pagamentos (funcionario_id, competencia, tipo, valor, encargos, despesa_id, despesa_encargos_id, observacao)
  values (f.id, v_comp, v_tipo, v_valor, v_enc, v_desp, v_desp_enc, nullif(v_obs, ''));
  perform _auditar('Pagamento de funcionário', v_tipo || ' — ' || f.nome || ' (' || v_mm || ') = R$ ' || _dinheiro(v_valor) || case when v_enc > 0 then ' | encargos R$ ' || _dinheiro(v_enc) || ' a pagar' else '' end || ' | ' || case when v_caixa then 'saiu do caixa' else 'fora do caixa' end);
  v_r := jsonb_build_object('ok', true, 'message', 'Pagamento registrado: R$ ' || _dinheiro(v_valor) || ' para ' || f.nome || case when v_enc > 0 then ' (encargos de R$ ' || _dinheiro(v_enc) || ' ficaram em Contas a pagar)' else '' end || '.');
  if v_req is not null then perform _idem_gravar(v_req, 'pagarFuncionario', v_r); end if;
  return v_r;
end $$;

-- 4) Cancelar um pagamento (pede a senha do Admin; cancela também a despesa e, se ainda não paga, a conta de encargos)
create or replace function public.api_cancelar_pagamento_funcionario(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare x funcionario_pagamentos%rowtype; v_motivo text := btrim(coalesce(p->>'motivo', '')); v_aut text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  if v_motivo = '' then return _falha('Informe o motivo do cancelamento.'); end if;
  select * into x from funcionario_pagamentos where id = _uuid(p->>'id') for update;
  if not found then return _falha('Pagamento não encontrado.'); end if;
  if x.status = 'Cancelada' then return _falha('Esse pagamento já está cancelado.'); end if;
  update funcionario_pagamentos set status = 'Cancelada', motivo_cancelamento = v_motivo where id = x.id;
  update despesas set status = 'Cancelada', motivo_cancelamento = v_motivo where id = x.despesa_id and status <> 'Cancelada';
  update despesas set status = 'Cancelada', motivo_cancelamento = v_motivo where id = x.despesa_encargos_id and status = 'A pagar';
  perform _auditar('Pagamento de funcionário cancelado', x.tipo || ' R$ ' || _dinheiro(x.valor) || ' (' || x.competencia || ') | ' || v_motivo);
  return jsonb_build_object('ok', true, 'message', 'Pagamento cancelado.' || case when x.despesa_encargos_id is not null and exists (select 1 from despesas where id = x.despesa_encargos_id and status = 'Paga') then ' Os encargos já estavam pagos: cancele-os à parte em Contas a pagar e despesas, se for o caso.' else '' end);
end $$;

-- 5) Aviso diário: pagamento do mês passou do dia combinado e ainda não foi registrado (repete 1x por dia até pagar)
create or replace function public.equipe_pendencias_cron() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare ativos text[] := '{}'; r record; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_comp text := to_char((now() at time zone 'America/Sao_Paulo'), 'YYYY-MM'); v_pago numeric; v_chave text;
begin
  for r in select * from funcionarios where ativo and salario > 0 and (admissao is null or admissao <= v_hoje)
             and least(dia_pagamento, extract(day from (date_trunc('month', v_hoje) + interval '1 month - 1 day'))::int) <= extract(day from v_hoje)::int loop
    select coalesce(sum(valor), 0) into v_pago from funcionario_pagamentos where funcionario_id = r.id and competencia = v_comp and status = 'Paga' and tipo in ('Salário', 'Adiantamento', 'Vale');
    if v_pago + 0.009 < r.salario then
      v_chave := 'sis:venc:func:' || r.id || ':' || v_comp;
      ativos := array_append(ativos, v_chave);
      perform _alertas_sistema_avisar(v_chave, 'Pagamento pendente: ' || r.nome,
        'O pagamento de ' || r.nome || ' (dia ' || r.dia_pagamento || ') ainda não foi registrado neste mês. Faltam R$ ' || _dinheiro(r.salario - v_pago) || '. Administrador → Loja e equipe → Equipe e pagamentos → Pagar.');
    end if;
  end loop;
  update alertas_envios set resolvido_em = now() where tipo = 'sistema' and resolvido_em is null and chave like 'sis:venc:func:%' and not (chave = any(ativos));
  return jsonb_build_object('ok', true, 'pendentes', to_jsonb(ativos));
end $$;
revoke all on function public.equipe_pendencias_cron() from public, anon, authenticated;
grant execute on function public.equipe_pendencias_cron() to service_role;

do $$ declare f text; begin
  foreach f in array array['api_equipe_folha(jsonb)', 'api_salvar_funcionario(jsonb)', 'api_pagar_funcionario(jsonb)', 'api_cancelar_pagamento_funcionario(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;

select cron.schedule('equipe-pendencias-dia', '30 12 * * *', 'select public.equipe_pendencias_cron()');
