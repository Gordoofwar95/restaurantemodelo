-- =====================================================================
-- RESTAURANTE DEMO · Fase 3.1 — Entrada de compras (nota fiscal / cupom) · 18/10/2026
-- Evolui o módulo de Compras. Tudo ADITIVO: colunas novas com padrão, tabelas novas, funções substituídas
-- mantendo o mesmo nome e os mesmos parâmetros antigos (o app antigo continua funcionando).
-- Regras (decididas pelo dono): custo = ÚLTIMO custo pela data da nota, por unidade base; nº da nota e
-- anexo opcional; origem do dinheiro (caixa / conta / cartão / dinheiro do dono / a pagar); vários
-- pagamentos por nota; estorno completo; histórico de custos; embalagem lembrada por fornecedor;
-- despesa na categoria certa; despesa de compra só se mexe pela compra.
-- =====================================================================

-- ---------- 1. estrutura ----------
alter table public.compras
  add column if not exists numero_nota text not null default '',
  add column if not exists frete numeric(12,2) not null default 0,
  add column if not exists desconto numeric(12,2) not null default 0,
  add column if not exists anexo_path text,
  add column if not exists anexo_nome text,
  add column if not exists editada_de uuid,
  add column if not exists substituida_por uuid,
  add column if not exists estornada_em timestamptz,
  add column if not exists estornada_por uuid,
  add column if not exists estorno_motivo text,
  add column if not exists atualizada_em timestamptz;

-- (sem trocar as restrições antigas: "Estornada" = status Cancelada + estornada_em preenchido; "Parcial" = calculado na listagem)

alter table public.compra_itens
  add column if not exists categoria text,
  add column if not exists descricao_nota text,
  add column if not exists fator numeric,
  add column if not exists embalagem text,
  add column if not exists qtd_base numeric,
  add column if not exists valor_rateado numeric(12,2),
  add column if not exists custo_base numeric;

alter table public.despesas
  add column if not exists compra_id uuid,              -- sem FK de propósito (evita ciclo compras <-> despesas na restauração do backup)
  add column if not exists origem_pagamento text;
create index if not exists despesas_compra_idx on public.despesas (compra_id) where compra_id is not null;

create table if not exists public.compra_pagamentos (
  id uuid primary key default gen_random_uuid(),
  compra_id uuid not null,
  valor numeric(12,2) not null check (valor > 0),
  origem text not null check (origem = any (array['caixa','conta','cartao','dono','apagar'])),
  vencimento date,
  criado_em timestamptz not null default now()
);
create index if not exists compra_pagamentos_compra_idx on public.compra_pagamentos (compra_id);

create table if not exists public.compra_custos (
  id uuid primary key default gen_random_uuid(),
  ingrediente_id uuid not null,
  compra_id uuid,
  compra_item_id uuid,
  data_nota date not null,
  custo_unitario numeric not null,
  custo_anterior numeric,
  aplicado boolean not null default false,            -- virou o custo atual do ingrediente quando foi lançada
  ativo boolean not null default true,                -- false = a nota foi estornada
  criado_em timestamptz not null default now(),
  criado_por uuid
);
create index if not exists compra_custos_ing_idx on public.compra_custos (ingrediente_id, data_nota desc, criado_em desc);
create index if not exists compra_custos_compra_idx on public.compra_custos (compra_id);

create table if not exists public.compra_vinculos (
  fornecedor_id uuid not null,
  chave text not null,
  ingrediente_id uuid not null,
  unidade text not null,
  fator numeric,
  embalagem text,
  atualizado_em timestamptz not null default now(),
  primary key (fornecedor_id, chave)
);
create index if not exists compra_vinculos_ing_idx on public.compra_vinculos (ingrediente_id);

alter table public.compra_pagamentos enable row level security;
alter table public.compra_custos enable row level security;
alter table public.compra_vinculos enable row level security;
create policy compra_pagamentos_ler on public.compra_pagamentos for select to authenticated using (tem_nivel('Admin'));
create policy compra_custos_ler on public.compra_custos for select to authenticated using (tem_nivel('Admin'));
create policy compra_vinculos_ler on public.compra_vinculos for select to authenticated using (tem_nivel('Admin'));

-- histórico inicial: o custo atual de cada ingrediente vira a primeira linha (data de hoje), para o estorno saber voltar
insert into public.compra_custos (ingrediente_id, data_nota, custo_unitario, custo_anterior, aplicado, ativo, criado_em)
select e.id, (now() at time zone 'America/Sao_Paulo')::date - 3650, e.custo_unitario, null, true, true, now() - interval '10 years'
from public.estoque e
where coalesce(e.custo_unitario, 0) > 0 and not exists (select 1 from public.compra_custos h where h.ingrediente_id = e.id);

-- ---------- 2. funções auxiliares ----------
create or replace function public._compra_chave(t text) returns text language sql immutable set search_path to 'public' as $$
  select left(regexp_replace(lower(translate(coalesce(t, ''), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')), '[^a-z0-9]+', ' ', 'g'), 80)
$$;
create or replace function public._compra_nota_norm(t text) returns text language sql immutable set search_path to 'public' as $$
  select ltrim(regexp_replace(coalesce(t, ''), '\D', '', 'g'), '0')
$$;

-- origem das linhas de pagamento (aceita o formato antigo: pagamento + saiuDoCaixa + vencimento)
create or replace function public._compra_pags(p jsonb, p_total numeric) returns jsonb language plpgsql stable set search_path to 'public' as $$
declare v jsonb := '[]'::jsonb; x jsonb; v_o text;
begin
  if jsonb_typeof(p->'pagamentos') = 'array' and jsonb_array_length(p->'pagamentos') > 0 then
    for x in select value from jsonb_array_elements(p->'pagamentos') loop
      v_o := lower(btrim(coalesce(x->>'origem', '')));
      v_o := case v_o when 'cartão' then 'cartao' when 'a pagar' then 'apagar' when 'a_pagar' then 'apagar' else v_o end;
      v := v || jsonb_build_object('valor', round(_num(x->>'valor'), 2), 'origem', v_o, 'vencimento', x->>'vencimento');
    end loop;
    return v;
  end if;
  if p->>'pagamento' = 'A pagar' then
    return jsonb_build_array(jsonb_build_object('valor', p_total, 'origem', 'apagar', 'vencimento', p->>'vencimento'));
  end if;
  return jsonb_build_array(jsonb_build_object('valor', p_total, 'origem', case when coalesce(p->>'saiuDoCaixa', '') in ('true','t') then 'caixa' else 'conta' end));
end $$;

-- valida as linhas de pagamento contra o total da nota
create or replace function public._compra_pags_validar(p_pags jsonb, p_total numeric) returns text language plpgsql stable set search_path to 'public' as $$
declare x jsonb; v_soma numeric := 0; v_caixa uuid;
begin
  if jsonb_typeof(p_pags) <> 'array' or jsonb_array_length(p_pags) = 0 then return 'Informe como a compra foi paga.'; end if;
  if jsonb_array_length(p_pags) > 10 then return 'No máximo 10 pagamentos por nota.'; end if;
  for x in select value from jsonb_array_elements(p_pags) loop
    if not (x->>'origem' = any (array['caixa','conta','cartao','dono','apagar'])) then return 'Origem do pagamento inválida.'; end if;
    if _num(x->>'valor') <= 0 then return 'Cada pagamento precisa de valor maior que zero.'; end if;
    if x->>'origem' = 'apagar' and _data_iso(x->>'vencimento') is null then return 'Informe o vencimento do que vai ser pago depois.'; end if;
    if x->>'origem' = 'caixa' then
      select id into v_caixa from caixa_sessoes where status = 'Aberto' limit 1;
      if v_caixa is null then return 'Para dizer que o dinheiro saiu do caixa, o caixa precisa estar aberto. Se foi pago com o caixa de outro dia, escolha outra origem e explique na observação.'; end if;
      if _caixa_vencido(v_caixa) then return _caixa_msg_vencido(); end if;
    end if;
    v_soma := v_soma + round(_num(x->>'valor'), 2);
  end loop;
  if round(v_soma, 2) <> round(p_total, 2) then
    return 'A soma dos pagamentos (R$ ' || _dinheiro(v_soma) || ') precisa ser igual ao total da nota (R$ ' || _dinheiro(p_total) || ').';
  end if;
  return null;
end $$;

-- recebe a compra: estoque, último custo + histórico, despesas por categoria e por pagamento
create or replace function public._compra_receber2(p_id uuid, p_pags jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c compras%rowtype; i record; e estoque%rowtype; v_q numeric; v_forn text; v_soma numeric; v_frete numeric; v_desc numeric; v_total numeric;
        v_acum numeric := 0; v_n int; v_k int := 0; v_rat numeric; v_custo numeric; v_mais_nova boolean; v_cat text; v_grupos jsonb := '{}'::jsonb;
        x jsonb; g record; v_parte numeric; v_resto numeric; v_maior text; v_desp uuid; v_primeira uuid; v_status text; v_pg text; v_tem_pago boolean := false; v_tem_apagar boolean := false;
        v_nota text; v_ids uuid[] := '{}'; v_prej jsonb;
begin
  if not tem_nivel('Admin') then raise exception '%', 'Seu perfil não tem permissão para esta ação.'; end if;
  select * into c from compras where id = p_id for update;
  if not found then raise exception '%', 'Compra não encontrada.'; end if;
  if c.status <> 'Pedido' then raise exception '%', 'Esta compra já foi ' || lower(c.status) || '.'; end if;
  select nome into v_forn from fornecedores where id = c.fornecedor_id;
  select coalesce(sum(valor_total), 0), count(*) into v_soma, v_n from compra_itens where compra_id = c.id;
  v_frete := coalesce(c.frete, 0); v_desc := coalesce(c.desconto, 0);
  v_total := round(v_soma + v_frete - v_desc, 2);
  if v_total < 0 then raise exception '%', 'O desconto não pode ser maior que a soma dos itens com o frete.'; end if;
  v_nota := case when coalesce(c.numero_nota, '') <> '' then ' (nota ' || c.numero_nota || ')' else '' end;

  -- itens: rateio de frete e desconto proporcional ao valor (o último item leva os centavos que sobram)
  for i in select * from compra_itens where compra_id = c.id order by id loop
    v_k := v_k + 1;
    if v_k = v_n then v_rat := round(v_total - v_acum, 2);
    elsif v_soma > 0 then v_rat := round(i.valor_total + (v_frete - v_desc) * i.valor_total / v_soma, 2);
    else v_rat := round((v_frete - v_desc) / v_n, 2); end if;
    v_acum := v_acum + v_rat;
    if i.ingrediente_id is not null then
      select * into e from estoque where id = i.ingrediente_id for update;
      if not found then raise exception '%', 'Ingrediente de "' || i.descricao || '" não existe mais no estoque.'; end if;
      v_q := _converter_unidade(i.quantidade, i.unidade, e.unidade::text);
      if v_q is null or v_q <= 0 then raise exception '%', 'A unidade "' || i.unidade || '" de ' || e.ingrediente || ' não combina com a do estoque (' || e.unidade || ').'; end if;
      v_custo := round(v_rat / v_q, 6);
      -- ÚLTIMO CUSTO pela data da nota: só troca o custo se não houver nota MAIS NOVA já lançada (empate: vale a lançada agora)
      v_mais_nova := exists (select 1 from compra_custos h where h.ingrediente_id = e.id and h.ativo and h.aplicado and h.data_nota > c.data);
      insert into compra_custos (ingrediente_id, compra_id, compra_item_id, data_nota, custo_unitario, custo_anterior, aplicado, criado_por)
      values (e.id, c.id, i.id, c.data, v_custo, e.custo_unitario, not v_mais_nova, auth.uid());
      update estoque set quantidade = e.quantidade + v_q, custo_unitario = case when v_mais_nova then custo_unitario else v_custo end where id = e.id;
      insert into movimentacoes_estoque (ingrediente_id, tipo, quantidade, qtd_antes, qtd_depois, motivo_referencia, usuario_id)
      values (e.id, 'Entrada', v_q, e.quantidade, e.quantidade + v_q, 'Compra de ' || v_forn || v_nota || ' (R$ ' || _dinheiro(v_rat) || ')', auth.uid());
      update compra_itens set qtd_base = v_q, valor_rateado = v_rat, custo_base = v_custo, categoria = coalesce(categoria, 'Insumos') where id = i.id;
      v_ids := v_ids || e.id;
      v_cat := 'Insumos';
    else
      v_cat := _categoria_despesa(coalesce(i.categoria, 'Insumos'));
      update compra_itens set valor_rateado = v_rat, categoria = v_cat where id = i.id;
    end if;
    v_grupos := jsonb_set(v_grupos, array[v_cat], to_jsonb(coalesce((v_grupos->>v_cat)::numeric, 0) + v_rat));
  end loop;

  -- despesas: cada pagamento é repartido entre as categorias da nota (o DRE fica certo mesmo em nota mista)
  if v_total > 0 then
    select key into v_maior from jsonb_each_text(v_grupos) order by value::numeric desc, key limit 1;
    for x in select value from jsonb_array_elements(p_pags) loop
      v_resto := round((x->>'valor')::numeric, 2);
      for g in select key as cat, value::numeric as val from jsonb_each_text(v_grupos) order by (key = v_maior), key loop
        if g.cat = v_maior then v_parte := v_resto;
        else v_parte := round((x->>'valor')::numeric * g.val / v_total, 2); v_resto := v_resto - v_parte; end if;
        if v_parte <= 0 then continue; end if;
        insert into despesas (data_hora, descricao, valor, observacao, status, categoria, vencimento, situacao, competencia, saiu_do_caixa, compra_id, origem_pagamento)
        values (case when x->>'origem' = 'apagar' then _meio_dia(_data_iso(x->>'vencimento')) else now() end,
                'Compra: ' || v_forn || v_nota, v_parte,
                'Compra ' || to_char(c.data, 'DD/MM/YYYY') || case when coalesce(c.observacao, '') <> '' then ' - ' || c.observacao else '' end,
                (case when x->>'origem' = 'apagar' then 'A pagar' else 'Paga' end)::status_despesa, g.cat,
                case when x->>'origem' = 'apagar' then _data_iso(x->>'vencimento') end,
                case when x->>'origem' = 'apagar' then 'A pagar' else 'Paga' end,
                case when x->>'origem' = 'apagar' then to_char(_data_iso(x->>'vencimento'), 'YYYY-MM') end,
                (x->>'origem') = 'caixa', c.id, case when x->>'origem' = 'apagar' then null else x->>'origem' end)
        returning id into v_desp;
        if v_primeira is null then v_primeira := v_desp; end if;
      end loop;
      insert into compra_pagamentos (compra_id, valor, origem, vencimento) values (c.id, round((x->>'valor')::numeric, 2), x->>'origem', _data_iso(x->>'vencimento'));
      if x->>'origem' = 'apagar' then v_tem_apagar := true; else v_tem_pago := true; end if;
    end loop;
  end if;
  v_pg := case when v_tem_apagar then 'A pagar' else 'Pago' end;   -- "Parcial" é mostrado pela listagem (compra_pagamentos)
  update compras set status = 'Recebida', recebida_em = now(), total = v_total, pagamento = v_pg,
         vencimento = (select min(_data_iso(value->>'vencimento')) from jsonb_array_elements(p_pags) where value->>'origem' = 'apagar'),
         despesa_id = v_primeira, atualizada_em = now() where id = c.id;

  -- produtos e combos que passaram a dar prejuízo (preço abaixo do custo novo)
  select coalesce(jsonb_agg(distinct jsonb_build_object('produto', pr.nome, 'forma', fp.nome, 'preco', pp.preco, 'custo', pp.custo)), '[]'::jsonb) into v_prej
  from produto_precos pp join produtos pr on pr.id = pp.produto_id join formas_pagamento fp on fp.id = pp.forma_pagamento_id
  where pr.ativo and pp.custo > pp.preco and pp.produto_id in (select produto_id from produto_ingredientes where ingrediente_id = any (v_ids));
  return jsonb_build_object('total', v_total, 'prejuizo', v_prej);
end $$;

-- compatibilidade: a assinatura antiga continua existindo e passa pelo fluxo novo
create or replace function public._compra_receber(p_id uuid, p_pagamento text, p_venc date, p_saiu boolean) returns text language plpgsql security definer set search_path to 'public' as $$
declare v_t numeric;
begin
  if not tem_nivel('Admin') then raise exception '%', 'Seu perfil não tem permissão para esta ação.'; end if;
  select coalesce(sum(valor_total), 0) + coalesce(max(c.frete), 0) - coalesce(max(c.desconto), 0) into v_t from compras c left join compra_itens i on i.compra_id = c.id where c.id = p_id;
  perform _compra_receber2(p_id, _compra_pags(jsonb_build_object('pagamento', p_pagamento, 'vencimento', p_venc, 'saiuDoCaixa', p_saiu), round(v_t, 2)));
  return null;
end $$;

-- ---------- 3. registrar compra ----------
create or replace function public.api_registrar_compra(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_req text := nullif(p->>'requisicaoId', ''); v_r jsonb; v_forn uuid; v_fnome text; x jsonb; v_n int := 0; v_soma numeric := 0; v_id uuid := gen_random_uuid();
        v_status text := case when p->>'status' = 'Pedido' then 'Pedido' else 'Recebida' end;
        v_data date := coalesce(_data_iso(p->>'data'), (now() at time zone 'America/Sao_Paulo')::date);
        v_org text := case when p->>'origem' = 'ia' then 'ia' else 'manual' end; v_ing uuid; v_ie estoque%rowtype; v_val numeric; v_qtd numeric; v_un text; v_desc text;
        v_nota text := left(btrim(coalesce(p->>'numeroNota', '')), 60); v_obs text := left(btrim(coalesce(p->>'observacao', '')), 300);
        v_frete numeric := round(_num(p->>'frete'), 2); v_descnota numeric := round(_num(p->>'desconto'), 2); v_total numeric; v_pags jsonb; v_erro text;
        v_anexo text := nullif(left(btrim(coalesce(p->>'anexoPath', '')), 300), ''); v_editada uuid := _uuid(p->>'editadaDe');
        v_conf boolean := coalesce(p->>'confirmar', '') in ('true','t'); v_dup jsonb; v_var jsonb := '[]'::jsonb; v_q numeric; v_cu numeric; v_res jsonb; v_cat text; v_dn text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_req is not null then perform pg_advisory_xact_lock(hashtext(v_req)); v_r := _idem_ler(v_req); if v_r is not null then return v_r; end if; end if;
  if v_data > (now() at time zone 'America/Sao_Paulo')::date + 1 then return _falha('A data da nota não pode ser no futuro.'); end if;
  if v_frete < 0 or v_descnota < 0 then return _falha('Frete e desconto não podem ser negativos.'); end if;
  v_forn := _uuid(p->>'fornecedorId');
  if v_forn is null and btrim(coalesce(p->>'fornecedorNome', '')) <> '' then
    select id into v_forn from fornecedores where lower(btrim(nome)) = lower(btrim(p->>'fornecedorNome'));
    if v_forn is null then return _falha('Fornecedor "' || btrim(p->>'fornecedorNome') || '" não está cadastrado. Cadastre-o primeiro.'); end if;
  end if;
  select nome into v_fnome from fornecedores where id = v_forn and ativo;
  if v_fnome is null then return _falha('Escolha um fornecedor ativo.'); end if;
  if jsonb_typeof(p->'itens') <> 'array' or jsonb_array_length(p->'itens') = 0 then return _falha('Informe ao menos um item da compra.'); end if;
  if jsonb_array_length(p->'itens') > 40 then return _falha('No máximo 40 itens por nota.'); end if;
  -- rastro mínimo sem anexo: nº da nota ou observação (proposta da assistente: o registro diz quem confirmou)
  if v_anexo is null and v_nota = '' and v_obs = '' then
    if v_org = 'ia' then v_obs := 'Lançada pela assistente, confirmada por ' || coalesce(_login_de(auth.uid()), 'Admin');
    else return _falha('Sem foto da nota: informe o número da nota ou uma observação (para ficar o rastro).'); end if;
  end if;
  if v_editada is not null and not exists (select 1 from compras where id = v_editada and estornada_em is not null) then
    return _falha('A nota que está sendo corrigida precisa estar estornada antes.');
  end if;

  -- 1) só confere (nada é gravado se algo estiver errado)
  for x in select value from jsonb_array_elements(p->'itens') loop
    v_qtd := _num(x->>'quantidade'); v_val := round(_num(x->>'valorTotal'), 2); v_un := lower(btrim(coalesce(x->>'unidade', '')));
    v_ing := _uuid(x->>'ingredienteId'); v_desc := btrim(coalesce(x->>'descricao', x->>'ingrediente', ''));
    if v_ing is null and btrim(coalesce(x->>'ingrediente', '')) <> '' then select id into v_ing from estoque where lower(btrim(ingrediente)) = lower(btrim(x->>'ingrediente')) limit 1; end if;
    if v_ing is not null then
      select * into v_ie from estoque where id = v_ing;
      if not found then return _falha('Ingrediente não encontrado no estoque.'); end if;
      if v_un = '' then v_un := v_ie.unidade::text; end if;
      if _converter_unidade(1, v_un, v_ie.unidade::text) is null then return _falha('A unidade "' || v_un || '" não combina com a do estoque de ' || v_ie.ingrediente || ' (' || v_ie.unidade || ').'); end if;
      if v_qtd > 0 and v_val > 0 and coalesce(v_ie.custo_unitario, 0) > 0 then
        v_q := _converter_unidade(v_qtd, v_un, v_ie.unidade::text); v_cu := v_val / v_q;
        if abs(v_cu - v_ie.custo_unitario) / v_ie.custo_unitario > 0.30 then
          v_var := v_var || jsonb_build_object('ingrediente', v_ie.ingrediente, 'unidade', v_ie.unidade, 'anterior', round(v_ie.custo_unitario, 4), 'novo', round(v_cu, 4),
                   'pct', round((v_cu - v_ie.custo_unitario) / v_ie.custo_unitario * 100));
        end if;
      end if;
    elsif v_desc = '' then return _falha('Cada item precisa de um nome ou de um ingrediente do estoque.');
    elsif btrim(coalesce(x->>'ingrediente', '')) <> '' and btrim(coalesce(x->>'descricao', '')) = '' then
      return _falha('Ingrediente "' || btrim(x->>'ingrediente') || '" não está no estoque. Cadastre-o em Estoque antes, ou informe só a descrição do item.');
    end if;
    if v_qtd <= 0 then return _falha('Informe a quantidade de "' || coalesce(nullif(v_desc, ''), v_ie.ingrediente) || '" maior que zero.'); end if;
    if v_val <= 0 then return _falha('Informe o valor de "' || coalesce(nullif(v_desc, ''), v_ie.ingrediente) || '" (maior que zero).'); end if;
    if v_val > 9999999 then return _falha('Valor alto demais em "' || coalesce(nullif(v_desc, ''), v_ie.ingrediente) || '".'); end if;
    v_soma := v_soma + v_val; v_ie := null;
  end loop;
  v_total := round(v_soma + v_frete - v_descnota, 2);
  if v_total <= 0 then return _falha('O total da nota precisa ser maior que zero (confira o desconto).'); end if;
  if p ? 'totalNota' and nullif(btrim(coalesce(p->>'totalNota', '')), '') is not null and round(_num(p->>'totalNota'), 2) <> v_total then
    return _falha('A soma dos itens + frete − desconto dá R$ ' || _dinheiro(v_total) || ', mas o total da nota informado é R$ ' || _dinheiro(_num(p->>'totalNota')) || '. Confira antes de salvar.');
  end if;
  if v_status = 'Recebida' then
    v_pags := _compra_pags(p, v_total);
    v_erro := _compra_pags_validar(v_pags, v_total);
    if v_erro is not null then return _falha(v_erro); end if;
  end if;
  -- nota repetida e custo muito diferente: pede confirmação antes de gravar
  if _compra_nota_norm(v_nota) <> '' then
    select jsonb_build_object('data', to_char(c.data, 'DD/MM/YYYY'), 'total', c.total) into v_dup from compras c
     where c.fornecedor_id = v_forn and _compra_nota_norm(c.numero_nota) = _compra_nota_norm(v_nota) and c.status in ('Pedido','Recebida') limit 1;
  end if;
  if not v_conf and (v_dup is not null or jsonb_array_length(v_var) > 0) then
    return jsonb_build_object('ok', false, 'precisaConfirmar', true, 'duplicada', v_dup, 'variacoes', v_var,
      'message', concat_ws(' ', case when v_dup is not null then 'Já existe a nota ' || v_nota || ' deste fornecedor (' || (v_dup->>'data') || ', R$ ' || _dinheiro((v_dup->>'total')::numeric) || ').' end,
                                case when jsonb_array_length(v_var) > 0 then 'Há custo muito diferente do anterior (mais de 30%): confira se não houve erro de digitação.' end));
  end if;

  -- 2) grava
  insert into compras (id, fornecedor_id, data, status, pagamento, observacao, origem, requisicao_id, criado_por, numero_nota, frete, desconto, anexo_path, anexo_nome, editada_de, atualizada_em)
  values (v_id, v_forn, v_data, 'Pedido', case when p->>'pagamento' = 'A pagar' then 'A pagar' else 'Pago' end, v_obs, v_org, v_req, auth.uid(), v_nota, v_frete, v_descnota, v_anexo,
          nullif(left(btrim(coalesce(p->>'anexoNome', '')), 120), ''), v_editada, now());
  for x in select value from jsonb_array_elements(p->'itens') loop
    v_qtd := _num(x->>'quantidade'); v_val := round(_num(x->>'valorTotal'), 2); v_un := lower(btrim(coalesce(x->>'unidade', '')));
    v_ing := _uuid(x->>'ingredienteId'); v_desc := btrim(coalesce(x->>'descricao', x->>'ingrediente', '')); v_dn := left(btrim(coalesce(x->>'descricaoNota', '')), 80);
    if v_ing is null and btrim(coalesce(x->>'ingrediente', '')) <> '' then select id into v_ing from estoque where lower(btrim(ingrediente)) = lower(btrim(x->>'ingrediente')) limit 1; end if;
    if v_ing is not null then select * into v_ie from estoque where id = v_ing; if v_un = '' then v_un := v_ie.unidade::text; end if; if v_desc = '' then v_desc := v_ie.ingrediente; end if; v_cat := null;
    else v_cat := _categoria_despesa(coalesce(nullif(x->>'categoria', ''), 'Insumos')); end if;
    if v_un = '' then v_un := 'un'; end if;
    insert into compra_itens (compra_id, ingrediente_id, descricao, quantidade, unidade, valor_total, categoria, descricao_nota, fator, embalagem)
    values (v_id, v_ing, left(v_desc, 80), v_qtd, left(v_un, 10), v_val, v_cat, nullif(v_dn, ''), nullif(_num(x->>'fator'), 0), nullif(left(btrim(coalesce(x->>'embalagem', '')), 40), ''));
    -- lembra o vínculo "como vem na nota deste fornecedor" -> ingrediente / unidade / embalagem
    if v_ing is not null and _compra_chave(coalesce(nullif(v_dn, ''), v_desc)) <> '' then
      insert into compra_vinculos (fornecedor_id, chave, ingrediente_id, unidade, fator, embalagem, atualizado_em)
      values (v_forn, _compra_chave(coalesce(nullif(v_dn, ''), v_desc)), v_ing, v_un, nullif(_num(x->>'fator'), 0), nullif(left(btrim(coalesce(x->>'embalagem', '')), 40), ''), now())
      on conflict (fornecedor_id, chave) do update set ingrediente_id = excluded.ingrediente_id, unidade = excluded.unidade, fator = excluded.fator, embalagem = excluded.embalagem, atualizado_em = now();
    end if;
    v_n := v_n + 1; v_ie := null;
  end loop;
  update compras set total = v_total where id = v_id;
  if v_editada is not null then update compras set substituida_por = v_id where id = v_editada; end if;
  if v_status = 'Recebida' then v_res := _compra_receber2(v_id, v_pags); end if;
  perform _auditar(case when v_editada is not null then 'Compra corrigida (relançada)' else 'Compra registrada' end,
    v_fnome || case when v_nota <> '' then ' | nota ' || v_nota else '' end || ' | R$ ' || _dinheiro(v_total) || ' | ' || v_n || ' item(ns) | ' || v_status || ' | ' || v_org
    || case when v_anexo is null then ' | sem comprovante' else '' end);
  v_r := jsonb_build_object('ok', true, 'id', v_id, 'prejuizo', coalesce(v_res->'prejuizo', '[]'::jsonb),
    'message', case when v_status = 'Recebida' then 'Nota registrada: estoque, custos e despesas atualizados. Total R$ ' || _dinheiro(v_total) || '.' else 'Pedido de compra registrado: R$ ' || _dinheiro(v_total) || '.' end);
  if v_req is not null then perform _idem_gravar(v_req, 'registrarCompra', v_r); end if;
  return v_r;
exception when others then
  if sqlstate = 'P0001' then return _falha(sqlerrm); end if;
  raise;
end $$;

-- ---------- 4. receber pedido de compra (com a origem do dinheiro) ----------
create or replace function public.api_receber_compra(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'id'); c compras%rowtype; v_t numeric; v_pags jsonb; v_erro text; v_res jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from compras where id = v_id;
  if not found then return _falha('Compra não encontrada.'); end if;
  if c.status <> 'Pedido' then return _falha('Esta compra já foi ' || lower(c.status) || '.'); end if;
  select round(coalesce(sum(valor_total), 0) + c.frete - c.desconto, 2) into v_t from compra_itens where compra_id = v_id;
  v_pags := _compra_pags(p, v_t);
  v_erro := _compra_pags_validar(v_pags, v_t);
  if v_erro is not null then return _falha(v_erro); end if;
  v_res := _compra_receber2(v_id, v_pags);
  perform _auditar('Compra recebida', 'R$ ' || _dinheiro(v_t));
  return jsonb_build_object('ok', true, 'prejuizo', coalesce(v_res->'prejuizo', '[]'::jsonb), 'message', 'Compra recebida: estoque, custos e despesas atualizados.');
exception when others then
  if sqlstate = 'P0001' then return _falha(sqlerrm); end if;
  raise;
end $$;

-- ---------- 5. estorno de nota recebida ----------
create or replace function public.api_estornar_compra(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'id'); c compras%rowtype; v_m text := left(btrim(coalesce(p->>'motivo', '')), 200); i record; e estoque%rowtype; h record; v_prev numeric;
        v_neg jsonb := '[]'::jsonb; v_conf boolean := coalesce(p->>'confirmarNegativo', '') in ('true','t'); v_novo numeric; v_fech int := 0; v_forn text; d record; v_aut text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  if v_m = '' then return _falha('Informe o motivo do estorno.'); end if;
  select * into c from compras where id = v_id for update;
  if not found then return _falha('Compra não encontrada.'); end if;
  if c.estornada_em is not null then return _falha('Esta compra já está estornada.'); end if;
  if c.status = 'Pedido' then return _falha('Este é só um pedido: use "Cancelar pedido".'); end if;
  if c.status <> 'Recebida' then return _falha('Esta compra já está ' || lower(c.status) || '.'); end if;
  select nome into v_forn from fornecedores where id = c.fornecedor_id;
  -- 1) estoque: avisa se algum ingrediente ficaria negativo (já foi consumido)
  for i in select ci.*, coalesce(ci.qtd_base, _converter_unidade(ci.quantidade, ci.unidade, es.unidade::text)) q, es.ingrediente nome, es.quantidade atual, es.unidade un
           from compra_itens ci join estoque es on es.id = ci.ingrediente_id where ci.compra_id = c.id loop
    if i.atual - i.q < -0.0000001 then v_neg := v_neg || jsonb_build_object('ingrediente', i.nome, 'atual', i.atual, 'tirar', round(i.q, 3), 'fica', round(i.atual - i.q, 3), 'unidade', i.un); end if;
  end loop;
  if jsonb_array_length(v_neg) > 0 and not v_conf then
    return jsonb_build_object('ok', false, 'precisaConfirmar', true, 'negativos', v_neg,
      'message', 'Parte desta compra já foi usada: o estorno vai deixar ' || jsonb_array_length(v_neg) || ' ingrediente(s) com estoque negativo. Confirme para estornar mesmo assim.');
  end if;
  for i in select ci.*, coalesce(ci.qtd_base, _converter_unidade(ci.quantidade, ci.unidade, es.unidade::text)) q from compra_itens ci join estoque es on es.id = ci.ingrediente_id where ci.compra_id = c.id order by ci.ingrediente_id loop
    select * into e from estoque where id = i.ingrediente_id for update;
    v_novo := round(e.quantidade - i.q, 3);
    update estoque set quantidade = v_novo where id = e.id;
    insert into movimentacoes_estoque (ingrediente_id, tipo, quantidade, qtd_antes, qtd_depois, motivo_referencia, usuario_id)
    values (e.id, 'Ajuste', -i.q, e.quantidade, v_novo, 'Estorno de compra: ' || v_forn || case when c.numero_nota <> '' then ' (nota ' || c.numero_nota || ')' else '' end || ' — ' || v_m, auth.uid());
    if v_novo < 0 then perform _auditar('Estoque negativo', e.ingrediente || ': ' || v_novo || ' (estorno de compra, confirmado)'); end if;
  end loop;
  -- 2) custo: só volta ao anterior se esta nota era a fonte do custo atual
  for h in select * from compra_custos where compra_id = c.id and ativo loop
    update compra_custos set ativo = false where id = h.id;
    if h.aplicado and not exists (select 1 from compra_custos x where x.ingrediente_id = h.ingrediente_id and x.ativo and x.aplicado and x.id <> h.id
                                   and (x.data_nota, x.criado_em) > (h.data_nota, h.criado_em)) then
      select x.custo_unitario into v_prev from compra_custos x where x.ingrediente_id = h.ingrediente_id and x.ativo and x.id <> h.id
       order by x.data_nota desc, x.criado_em desc limit 1;
      update estoque set custo_unitario = coalesce(v_prev, h.custo_anterior, 0) where id = h.ingrediente_id;
    end if;
  end loop;
  -- 3) dinheiro: cancela as despesas da nota (o que saiu do caixa aberto volta para a gaveta; caixa já fechado não é mexido)
  for d in select * from despesas where compra_id = c.id and status <> 'Cancelada' loop
    if d.status = 'Paga' and d.saiu_do_caixa and not exists (select 1 from caixa_sessoes s where s.status = 'Aberto' and d.data_hora >= s.abertura) then v_fech := v_fech + 1; end if;
    update despesas set status = 'Cancelada', situacao = 'Cancelada', motivo_cancelamento = 'Estorno da compra: ' || v_m where id = d.id;
  end loop;
  update compras set status = 'Cancelada', motivo_cancelamento = 'Estornada: ' || v_m, estornada_em = now(), estornada_por = auth.uid(), estorno_motivo = v_m, atualizada_em = now() where id = c.id;
  perform _auditar('Compra estornada', v_forn || case when c.numero_nota <> '' then ' | nota ' || c.numero_nota else '' end || ' | R$ ' || _dinheiro(c.total) || ' | ' || v_m
    || case when jsonb_array_length(v_neg) > 0 then ' | estoque negativo confirmado' else '' end);
  return jsonb_build_object('ok', true, 'message', 'Compra estornada: estoque, custo e despesas desfeitos.'
    || case when v_fech > 0 then ' Atenção: parte do dinheiro saiu de um caixa que já foi fechado; aquele fechamento não foi alterado — se o valor voltou para a gaveta, lance a entrada pelo caixa de hoje.' else '' end);
end $$;

-- ---------- 6. editar só o que não tem efeito (nº, observação, anexo) ----------
create or replace function public.api_editar_compra_info(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'id'); c compras%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from compras where id = v_id for update;
  if not found then return _falha('Compra não encontrada.'); end if;
  update compras set
    numero_nota = case when p ? 'numeroNota' then left(btrim(coalesce(p->>'numeroNota', '')), 60) else numero_nota end,
    observacao = case when p ? 'observacao' then left(btrim(coalesce(p->>'observacao', '')), 300) else observacao end,
    anexo_path = case when p ? 'anexoPath' then nullif(left(btrim(coalesce(p->>'anexoPath', '')), 300), '') else anexo_path end,
    anexo_nome = case when p ? 'anexoNome' then nullif(left(btrim(coalesce(p->>'anexoNome', '')), 120), '') else anexo_nome end,
    atualizada_em = now()
  where id = v_id;
  perform _auditar('Compra: dados da nota editados', coalesce(nullif(p->>'numeroNota', ''), c.numero_nota) || case when p ? 'anexoPath' then ' | comprovante ' || case when coalesce(p->>'anexoPath', '') = '' then 'removido' else 'anexado' end else '' end);
  return jsonb_build_object('ok', true, 'message', 'Dados da nota atualizados.');
end $$;

-- ---------- 7. cancelar pedido (sem mudança de regra; mensagem nova para a recebida) ----------
create or replace function public.api_cancelar_compra(p jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'id'); c compras%rowtype; v_m text := left(btrim(coalesce(p->>'motivo', '')), 150);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from compras where id = v_id for update;
  if not found then return _falha('Compra não encontrada.'); end if;
  if c.status <> 'Pedido' then return _falha(case when c.status = 'Recebida' then 'Compra já recebida: use "Estornar nota" (desfaz estoque, custo e despesas).' else 'Esta compra já está ' || lower(c.status) || '.' end); end if;
  if v_m = '' then return _falha('Informe o motivo do cancelamento.'); end if;
  update compras set status = 'Cancelada', motivo_cancelamento = v_m, atualizada_em = now() where id = c.id;
  perform _auditar('Compra cancelada', v_m);
  return jsonb_build_object('ok', true, 'message', 'Pedido de compra cancelado.');
end $$;

-- ---------- 8. listar ----------
create or replace function public.api_listar_compras(p jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'fornecedores', coalesce((select jsonb_agg(to_jsonb(f) order by lower(f.nome)) from fornecedores f), '[]'::jsonb),
    'vinculos', coalesce((select jsonb_agg(jsonb_build_object('fornecedorId', v.fornecedor_id, 'chave', v.chave, 'ingredienteId', v.ingrediente_id, 'unidade', v.unidade, 'fator', v.fator, 'embalagem', v.embalagem)) from compra_vinculos v), '[]'::jsonb),
    'custos', coalesce((select jsonb_agg(jsonb_build_object('ingredienteId', h.ingrediente_id, 'ingrediente', e.ingrediente, 'unidade', e.unidade, 'data', h.data_nota, 'custo', h.custo_unitario,
        'anterior', h.custo_anterior, 'aplicado', h.aplicado, 'ativo', h.ativo, 'compraId', h.compra_id, 'fornecedor', f.nome, 'nota', c.numero_nota, 'lancadoEm', h.criado_em) order by h.data_nota desc, h.criado_em desc)
        from (select * from compra_custos where compra_id is not null order by data_nota desc, criado_em desc limit 300) h join estoque e on e.id = h.ingrediente_id
        left join compras c on c.id = h.compra_id left join fornecedores f on f.id = c.fornecedor_id), '[]'::jsonb),
    'compras', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'fornecedorId', c.fornecedor_id, 'fornecedor', f.nome, 'data', c.data, 'status', case when c.estornada_em is not null then 'Estornada' else c.status end,
        'pagamento', case when exists (select 1 from compra_pagamentos g where g.compra_id = c.id and g.origem = 'apagar') and exists (select 1 from compra_pagamentos g where g.compra_id = c.id and g.origem <> 'apagar') then 'Parcial' else c.pagamento end,
        'vencimento', c.vencimento, 'total', c.total, 'observacao', c.observacao, 'origem', c.origem, 'motivoCancelamento', c.motivo_cancelamento,
        'numeroNota', c.numero_nota, 'frete', c.frete, 'desconto', c.desconto, 'anexoPath', c.anexo_path, 'anexoNome', c.anexo_nome, 'semComprovante', c.anexo_path is null,
        'editadaDe', c.editada_de, 'substituidaPor', c.substituida_por, 'estornadaEm', c.estornada_em, 'estornoMotivo', c.estorno_motivo,
        'pagamentos', coalesce((select jsonb_agg(jsonb_build_object('valor', g.valor, 'origem', g.origem, 'vencimento', g.vencimento) order by g.criado_em) from compra_pagamentos g where g.compra_id = c.id), '[]'::jsonb),
        'despesas', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'valor', d.valor, 'status', d.status, 'categoria', d.categoria, 'vencimento', d.vencimento, 'origem', d.origem_pagamento, 'saiuDoCaixa', d.saiu_do_caixa) order by d.data_hora) from despesas d where d.compra_id = c.id), '[]'::jsonb),
        'itens', coalesce((select jsonb_agg(jsonb_build_object('descricao', i.descricao, 'descricaoNota', i.descricao_nota, 'quantidade', i.quantidade, 'unidade', i.unidade, 'valorTotal', i.valor_total,
            'ingredienteId', i.ingrediente_id, 'categoria', i.categoria, 'fator', i.fator, 'embalagem', i.embalagem, 'valorRateado', i.valor_rateado, 'custoBase', i.custo_base) order by i.id) from compra_itens i where i.compra_id = c.id), '[]'::jsonb))
        order by c.data desc, c.criado_em desc) from (select * from compras order by data desc, criado_em desc limit 300) c join fornecedores f on f.id = c.fornecedor_id), '[]'::jsonb));
end $$;

-- ---------- 9. despesa nascida de compra só se mexe pela compra (editar/cancelar bloqueados; pagar guarda a origem) ----------
CREATE OR REPLACE FUNCTION public.api_editar_despesa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d despesas%rowtype; v_desc text := btrim(coalesce(p->>'descricao', '')); v_valor numeric := round(_num(p->>'valor'), 2);
        v_cat text; v_venc date; v_venc_txt text := btrim(coalesce(p->>'vencimento', ''));
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_desc = '' then return _falha('Informe a descrição da despesa.'); end if;
  if v_valor <= 0 then return _falha('Informe um valor maior que zero.'); end if;
  if v_valor > 9999999 then return _falha('Valor alto demais.'); end if;
  select * into d from despesas where id = _uuid(p->>'id') for update;
  if not found then return _falha('Despesa não encontrada.'); end if;
  if _versao_conflita(p, 'despesas', d.id) then return _conflito('Este registro foi alterado por outra pessoa enquanto você editava. A tela foi atualizada — confira e edite de novo.'); end if;
  if d.status = 'Cancelada' then return _falha('Só é possível editar despesas confirmadas.'); end if;
  if d.categoria = 'Ajuste pós-venda' then return _falha('Esta despesa nasceu de um Ajuste pós-venda. Para desfazer, cancele o ajuste em Financeiro → Ajustes pós-venda.'); end if;
  if d.compra_id is not null then return _falha('Esta despesa nasceu de uma compra. Para corrigir, use Compras → Estornar nota (ou Corrigir nota), assim estoque, custo e dinheiro continuam batendo.'); end if;
  v_cat := case when p ? 'categoria' then _categoria_despesa(p->>'categoria') else d.categoria end;
  v_venc := d.vencimento;
  if v_venc_txt <> '' then
    v_venc := _data_iso(v_venc_txt);
    if v_venc is null then return _falha('Vencimento inválido.'); end if;
  end if;
  if d.status = 'A pagar' and v_venc is null then return _falha('Conta a pagar precisa de vencimento.'); end if;
  update despesas set descricao = v_desc, valor = v_valor, observacao = coalesce(p->>'observacao', ''), categoria = v_cat,
         vencimento = v_venc,
         data_hora = case when v_venc is distinct from d.vencimento and d.status = 'A pagar' then _meio_dia(v_venc) else data_hora end
   where id = d.id;
  perform _auditar('Despesa editada', v_desc || ' | valor R$ ' || _dinheiro(d.valor) || ' → R$ ' || _dinheiro(v_valor)
    || case when v_venc is distinct from d.vencimento then ' | vencimento ' || coalesce(d.vencimento::text, '—') || ' → ' || coalesce(v_venc::text, '—') else '' end);
  return jsonb_build_object('ok', true, 'message', 'Despesa atualizada.');
end $function$;

CREATE OR REPLACE FUNCTION public.api_cancelar_despesa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d despesas%rowtype; v_aut text; v_motivo text := btrim(coalesce(p->>'motivo', ''));
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  if v_motivo = '' then return _falha('Informe o motivo do cancelamento.'); end if;
  select * into d from despesas where id = _uuid(p->>'id') for update;
  if not found then return _falha('Despesa não encontrada.'); end if;
  if d.categoria = 'Ajuste pós-venda' then return _falha('Esta despesa nasceu de um Ajuste pós-venda. Para desfazer, cancele o ajuste em Financeiro → Ajustes pós-venda.'); end if;
  if d.compra_id is not null then return _falha('Esta despesa nasceu de uma compra. Para desfazer, use Compras → Estornar nota (assim estoque, custo e dinheiro continuam batendo).'); end if;
  if d.status = 'Cancelada' then return _falha('Esta despesa já está cancelada.'); end if;
  update despesas set status = 'Cancelada', motivo_cancelamento = v_motivo where id = d.id;
  perform _auditar('Despesa cancelada', d.descricao || ' = R$ ' || _dinheiro(d.valor) || ' | ' || v_motivo);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.api_pagar_despesa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d despesas%rowtype; v_req text := nullif(p->>'requisicaoId', ''); v_r jsonb; v_caixa boolean := (coalesce(p->>'saiuDoCaixa', '') = 'true'); v_valor numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_req is not null then perform pg_advisory_xact_lock(hashtext(v_req)); v_r := _idem_ler(v_req); if v_r is not null then return v_r; end if; end if;
  select * into d from despesas where id = _uuid(p->>'id') for update;
  if not found then return _falha('Despesa não encontrada.'); end if;
  if d.status = 'Cancelada' then return _falha('Essa despesa está cancelada.'); end if;
  if d.status <> 'A pagar' then return _falha('Essa despesa já foi paga.'); end if;
  if v_caixa and not exists (select 1 from caixa_sessoes where status = 'Aberto') then
    return _falha('Abra o caixa para registrar um pagamento que sai do caixa.');
  end if;
  v_valor := d.valor;
  if nullif(btrim(coalesce(p->>'valorPago', '')), '') is not null then
    v_valor := round(_num(p->>'valorPago'), 2);
    if v_valor <= 0 then return _falha('Informe um valor pago maior que zero.'); end if;
    if v_valor > 9999999 then return _falha('Valor alto demais.'); end if;
  end if;
  if v_caixa and _caixa_vencido(_caixa_aberto_id()) then return _falha(_caixa_msg_vencido()); end if;
  update despesas set data_hora = now(), valor = v_valor, status = 'Paga', situacao = 'Paga', saiu_do_caixa = v_caixa,
         origem_pagamento = case when v_caixa then 'caixa' when lower(coalesce(p->>'origem', '')) in ('conta','cartao','dono') then lower(p->>'origem') else 'conta' end where id = d.id;
  perform _auditar('Conta paga', d.descricao || ' | previsto R$ ' || _dinheiro(d.valor) || ' | pago R$ ' || _dinheiro(v_valor) || ' | ' || case when v_caixa then 'saiu do caixa' else 'fora do caixa' end);
  v_r := jsonb_build_object('ok', true, 'message', 'Pagamento registrado: R$ ' || _dinheiro(v_valor));
  if v_req is not null then perform _idem_gravar(v_req, 'pagarDespesa', v_r); end if;
  return v_r;
end $function$;

-- ---------- 10. comprovantes das notas: bucket PRIVADO "notas" (só Admin/Desenvolvedor envia e abre; nada é apagado: o contador pode pedir) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notas', 'notas', false, 3145728, array['image/webp','image/jpeg','image/png','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy notas_admin_ler on storage.objects for select to authenticated using (bucket_id = 'notas' and public.tem_nivel('Admin'));
create policy notas_admin_enviar on storage.objects for insert to authenticated with check (bucket_id = 'notas' and public.tem_nivel('Admin'));
