-- 13 - Fechamento da auditoria de 18/10: fidelidade desfeita ao cancelar (F3-2), forma de pagamento da diferença na edição (F5-3),
-- hora original da contingência no histórico (F5-2) e histórico das alterações feitas direto no cadastro pelo Admin (F7-2).
-- Pode rodar de novo sem erro. Desfazer: voltar_atras/DESFAZER-13-fechamento-auditoria.sql (no pacote de auditoria).

-- ===== F3-2: vínculo entre venda e marca de fidelidade =====
create table if not exists public.fidelidade_marcas (
  venda_id uuid primary key references public.vendas(id) on delete cascade,
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  premios_resgatados int not null default 0,
  criado_em timestamptz not null default now(),
  desfeita boolean not null default false
);
alter table public.fidelidade_marcas add column if not exists desfeita boolean not null default false;
alter table public.fidelidade_marcas enable row level security;
revoke all on public.fidelidade_marcas from public, anon, authenticated;
grant all on public.fidelidade_marcas to service_role;

create or replace function public._carimbar_fidelidade(p_tel text, p_nome text, p_venda uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_cli uuid := _upsert_cliente(p_tel, p_nome); f fidelidade%rowtype; v_marcou boolean := false;
begin
  if v_cli is null then return; end if;
  -- a mesma venda nunca marca duas vezes
  if p_venda is not null and exists (select 1 from fidelidade_marcas where venda_id = p_venda) then return; end if;
  select * into f from fidelidade where cliente_id = v_cli for update;
  if found then
    if f.carimbos < 10 then
      update fidelidade set carimbos = f.carimbos + 1, atualizada_em = now() where cliente_id = v_cli;
      perform _auditar('Marca adicionada (fidelidade)', (f.carimbos + 1) || '/10', p_tel);
      v_marcou := true;
    end if;
  else
    insert into fidelidade (cliente_id, carimbos, atualizada_em) values (v_cli, 1, now());
    perform _auditar('Cliente novo no fidelidade', coalesce(p_nome, ''), p_tel);
    v_marcou := true;
  end if;
  if v_marcou and p_venda is not null then
    insert into fidelidade_marcas (venda_id, cliente_id, premios_resgatados)
    values (p_venda, v_cli, coalesce((select premios_resgatados from fidelidade where cliente_id = v_cli), 0)) on conflict do nothing;
  end if;
end $function$;
revoke all on function public._carimbar_fidelidade(text, text, uuid) from public, anon, authenticated;
grant execute on function public._carimbar_fidelidade(text, text, uuid) to service_role;

create or replace function public._carimbar_fidelidade(p_tel text, p_nome text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid;
begin
  -- chamadas sem o id da venda (fechamento de conta de mesa): usa a venda do mesmo cliente que foi paga nesta mesma transação
  select v.id into v_id from vendas v
   where v.status = 'Confirmada' and v.recebido_em = now()
     and regexp_replace(coalesce(v.telefone_cliente, ''), '\D', '', 'g') = regexp_replace(coalesce(p_tel, ''), '\D', '', 'g')
     and not exists (select 1 from fidelidade_marcas m where m.venda_id = v.id)
   order by v.numero_pedido limit 1;
  perform public._carimbar_fidelidade(p_tel, p_nome, v_id);
end $function$;
revoke all on function public._carimbar_fidelidade(text, text) from public, anon, authenticated;
grant execute on function public._carimbar_fidelidade(text, text) to service_role;

-- chamadores que passam o id da venda (o fechamento de mesa usa a versão de 2 parâmetros acima)
CREATE OR REPLACE FUNCTION public.api_iniciar_venda(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_nivel nivel_acesso := auth_nivel(); v_eu uuid := auth.uid(); v_login text;
  v_itens jsonb := p->'itens'; v_pags jsonb := p->'pagamentos'; v_tipo_in text := p->>'tipoEntrega';
  v_mesa_id uuid := _uuid(p->>'mesaId'); v_mesa mesas%rowtype; v_mesa_status text; v_mesa_garcom uuid;
  v_origem text := coalesce(nullif(p->>'origem', ''), 'Balcão'); v_status_pag text := p->>'statusPagamento';
  v_nome text := btrim(coalesce(p->>'clienteNome', '')); v_tel text := btrim(coalesce(p->>'clienteTelefone', ''));
  v_de jsonb := case when jsonb_typeof(p->'dadosEntrega') = 'object' then p->'dadosEntrega' else '{}'::jsonb end;
  v_desc jsonb := case when jsonb_typeof(p->'desconto') = 'object' then p->'desconto' else null end;
  v_req text := nullif(left(coalesce(p->>'requisicaoId', ''), 80), ''); v_ja uuid;
  it record; pg record; v_exige boolean; v_qtd numeric; v_v numeric; v_c numeric; v_nome_item text; v_extra numeric; v_n_ad int; v_n_ok int;
  v_orig numeric := 0; v_custo numeric := 0; v_total_item numeric; v_desc_val numeric := 0; v_desc_det text := ''; v_sol numeric; v_aut text;
  v_tipo venda_tipo; v_taxa numeric := 0; v_total numeric; v_soma numeric := 0; v_erro text; v_venda uuid := gen_random_uuid();
  v_pad numeric; v_t numeric; v_forma_row formas_pagamento%rowtype; v_resumo text; v_origem_final origem_venda; v_status_pedido_ini status_pedido;
  v_status_pag_final status_pagamento; v_numero int; v_msg_extra text := ''; v_caixa uuid; v_bloqueia boolean; r record; v_acr numeric := 0;
begin
  if v_nivel is null or v_nivel not in ('Admin','Operador','Garçom') then return _negado(); end if;
  if jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then return _falha('Adicione ao menos um item à venda.'); end if;
  if jsonb_typeof(v_pags) <> 'array' or jsonb_array_length(v_pags) = 0 then return _falha('Informe ao menos uma forma de pagamento.'); end if;
  if v_tipo_in = 'Mesa' and v_mesa_id is null then return _falha('Informe a mesa.'); end if;
  if v_origem like 'Contingência%' then return _falha('Vendas da contingência entram pelo botão "Trazer vendas pendentes da contingência" (Administrador).'); end if;
  if coalesce(p->'promocaoValidada'->>'ok', '') = 'true' then return _falha('Cupom não é aceito no Caixa. Use o desconto por porcentagem.'); end if;
  select login into v_login from usuarios where id = v_eu;
  select id into v_caixa from caixa_sessoes where status = 'Aberto' limit 1;
  if v_caixa is null then return _falha(case when v_nivel = 'Garçom' then 'O caixa está fechado — peça ao caixa para abrir.' else 'Abra o caixa antes de registrar uma venda.' end); end if;
  if _caixa_vencido(v_caixa) then return _falha(_caixa_msg_vencido()); end if;

  -- garçom: só mesa/entrega/retirada, sem desconto, sem receber pagamento; vale no servidor, não só na tela
  if v_nivel = 'Garçom' then
    if v_tipo_in not in ('Mesa','Entrega','Retirada') then return _falha('O garçom só lança pedidos de mesa, entrega ou retirada.'); end if;
    if v_tipo_in <> 'Mesa' and v_tel = '' then return _falha('Informe o cliente (nome e telefone) para pedidos por telefone.'); end if;
    if v_tipo_in = 'Mesa' then
      select * into v_mesa from mesas where id = v_mesa_id for update;
      if not found then return _falha('Mesa não encontrada.'); end if;
      if v_mesa.status not in ('Livre','Ocupada') then return _falha('A mesa ' || v_mesa.numero || ' está "' || v_mesa.status || '" — não aceita novos itens.'); end if;
      if v_mesa.status = 'Ocupada' and v_mesa.garcom_responsavel_id is not null and v_mesa.garcom_responsavel_id <> v_eu then
        return _falha('Esta mesa está sob responsabilidade de outro garçom.');
      end if;
    end if;
    v_origem := 'Garçom'; v_desc := null; v_status_pag := 'A Receber';
    if v_tipo_in = 'Mesa' then
      v_pags := jsonb_build_array(jsonb_build_object('forma', 'A Receber (Mesa)', 'valor', _num(v_pags->0->>'valor')));
    else
      v_pags := jsonb_build_array(jsonb_build_object('forma', btrim(coalesce(v_pags->0->>'forma', '')), 'valor', _num(v_pags->0->>'valor')));
    end if;
  elsif v_tipo_in = 'Mesa' then
    select * into v_mesa from mesas where id = v_mesa_id for update;
    if not found then return _falha('Mesa não encontrada.'); end if;
  end if;

  if v_tipo_in = 'Mesa' then v_mesa_status := v_mesa.status::text; v_mesa_garcom := v_mesa.garcom_responsavel_id; end if;

  -- idempotência: a mesma requisição (duplo toque, nova tentativa) nunca gera duas vendas
  if v_req is not null then
    perform pg_advisory_xact_lock(hashtext('venda:' || v_req));
    select id into v_ja from vendas where requisicao_id = v_req;
    if found then return jsonb_build_object('ok', true, 'duplicado', true, 'id', v_ja, 'message', 'Venda já registrada — requisição repetida ignorada.'); end if;
  end if;

  -- itens: quantidade, preço, custo e (para quem não é Admin) preço conferido com o cadastro
  v_exige := not (v_nivel = 'Admin' and v_origem <> 'Cardápio');
  for it in select value as e from jsonb_array_elements(v_itens) loop
    v_nome_item := coalesce(nullif(it.e->>'descricao', ''), 'item');
    v_qtd := _num(it.e->>'quantidade'); v_v := _num(it.e->>'valorUnitario', -1); v_c := _num(it.e->>'custoUnitario');
    if not (v_qtd > 0) or v_qtd > 200 or v_qtd <> floor(v_qtd) then return _falha('Quantidade inválida em "' || v_nome_item || '".'); end if;
    if v_v < 0 then return _falha('Preço inválido em "' || v_nome_item || '".'); end if;
    if v_c < 0 then return _falha('Custo inválido em "' || v_nome_item || '".'); end if;
    if v_exige then
      if (_uuid(it.e->>'produtoId') is null and _uuid(it.e->>'comboId') is null) or (_uuid(it.e->>'produtoId') is not null and _uuid(it.e->>'comboId') is not null) then
        return _falha('"' || v_nome_item || '" não é um item cadastrado de forma válida.');
      end if;
      select count(*), coalesce(sum(a.preco) filter (where a.ativo), 0), count(a.id) filter (where a.ativo and ((_uuid(it.e->>'produtoId') is not null and exists (select 1 from produto_adicionais pa where pa.produto_id = _uuid(it.e->>'produtoId') and pa.adicional_id = a.id)) or (_uuid(it.e->>'comboId') is not null and exists (select 1 from combo_itens ci join produto_adicionais pa on pa.produto_id = ci.produto_id where ci.combo_id = _uuid(it.e->>'comboId') and pa.adicional_id = a.id))))
        into v_n_ad, v_extra, v_n_ok
        from jsonb_array_elements_text(case when jsonb_typeof(it.e->'adicionaisIds') = 'array' then it.e->'adicionaisIds' else '[]'::jsonb end) x
        left join adicionais a on a.id = _uuid(x);
      if v_n_ad <> v_n_ok then return _falha('O adicional selecionado para "' || v_nome_item || '" não está disponível.'); end if;
      if _uuid(it.e->>'produtoId') is not null then
        if not exists (select 1 from produto_precos pp where pp.produto_id = _uuid(it.e->>'produtoId') and abs(pp.preco + v_extra - v_v) <= 0.011) then
          perform _auditar('Preço divergente bloqueado', v_nome_item || ' enviado a R$ ' || _dinheiro(v_v));
          return _falha('O preço de "' || v_nome_item || '" não confere com o cadastro.');
        end if;
        if not exists (select 1 from produto_precos pp where pp.produto_id = _uuid(it.e->>'produtoId') and abs(pp.preco + v_extra - v_v) <= 0.011 and abs(pp.custo - v_c) <= 0.011) then
          perform _auditar('Custo divergente bloqueado', v_nome_item || ' enviado com custo R$ ' || _dinheiro(v_c));
          return _falha('O custo de "' || v_nome_item || '" não confere com o cadastro.');
        end if;
      else
        if not exists (select 1 from combo_precos cp where cp.combo_id = _uuid(it.e->>'comboId') and abs(cp.preco + v_extra - v_v) <= 0.011) then
          perform _auditar('Preço divergente bloqueado', v_nome_item || ' enviado a R$ ' || _dinheiro(v_v));
          return _falha('O preço de "' || v_nome_item || '" não confere com o cadastro.');
        end if;
        if not exists (select 1 from combo_precos cp where cp.combo_id = _uuid(it.e->>'comboId') and abs(cp.preco + v_extra - v_v) <= 0.011 and abs(cp.custo - v_c) <= 0.011) then
          perform _auditar('Custo divergente bloqueado', v_nome_item || ' enviado com custo R$ ' || _dinheiro(v_c));
          return _falha('O custo de "' || v_nome_item || '" não confere com o cadastro.');
        end if;
      end if;
    end if;
    v_total_item := round(v_qtd * v_v, 2);
    v_orig := v_orig + v_total_item; v_custo := v_custo + v_qtd * v_c;
  end loop;
  v_orig := round(v_orig, 2); v_custo := round(v_custo, 2);

  -- estoque (só se a regra "bloquear venda sem estoque" estiver ligada)
  select coalesce((select (valor #>> '{}') = 'true' from sistema where chave = 'BLOQUEAR_ESTOQUE_NEGATIVO'), false) into v_bloqueia;
  if v_bloqueia then
    for r in select c.ingrediente_id, c.qtd, e.ingrediente, e.quantidade from _consumo(v_itens) c join estoque e on e.id = c.ingrediente_id loop
      if r.quantidade + 0.000000001 < r.qtd then
        if v_origem = 'Cardápio' then return _falha('Um dos itens do pedido acabou. Escolha outro item ou fale com o restaurante.'); end if;
        return _falha('Estoque insuficiente de "' || r.ingrediente || '" (tem ' || r.quantidade || ', a venda precisa de ' || round(r.qtd, 3) || ').');
      end if;
    end loop;
  end if;

  -- desconto manual (precisa da senha de Admin quando quem lança não é Admin)
  if v_desc is not null and v_desc->>'valor' is not null then
    v_sol := _num(v_desc->>'valor', -1);
    if v_sol <= 0 then return _falha('Valor de desconto inválido.'); end if;
    v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
    if v_aut is null then return _falha('Senha de administrador incorreta — desconto não aplicado.'); end if;
    if v_desc->>'tipo' = 'percentual' then
      if v_sol > 100 then return _falha('O desconto percentual não pode ser maior que 100%.'); end if;
      v_desc_val := round(v_orig * (v_sol / 100), 2);
      v_desc_det := v_sol || '% (R$ ' || _dinheiro(v_desc_val) || ')';
    elsif coalesce(v_desc->>'tipo', 'fixo') = 'fixo' then
      if v_sol > v_orig then return _falha('O desconto fixo não pode ser maior que o valor da venda.'); end if;
      v_desc_val := round(v_sol, 2);
      v_desc_det := 'R$ ' || _dinheiro(v_desc_val) || ' fixo';
    else
      return _falha('Tipo de desconto inválido.');
    end if;
    if v_desc_val <= 0 or v_desc_val >= v_orig then return _falha('O desconto não pode deixar a venda com valor zero ou negativo.'); end if;
  end if;

  -- tipo, taxa de entrega e total
  v_tipo := case v_tipo_in when 'Entrega' then 'Entrega' when 'Mesa' then 'Mesa' else 'Retirada' end::venda_tipo;
  if v_tipo = 'Entrega' and btrim(coalesce(v_de->>'endereco', '')) = '' then return _falha('Informe o endereço da entrega.'); end if;
  if v_tipo = 'Entrega' and coalesce(v_de->>'freteGratis', '') <> 'true' then
    select coalesce(_num(valor #>> '{}'), 0) into v_pad from sistema where chave = 'TaxaEntregaPadrao';
    v_taxa := coalesce(v_pad, 0);
    if v_nivel in ('Admin','Operador') and nullif(btrim(coalesce(v_de->>'taxa', '')), '') is not null then
      v_t := _num(v_de->>'taxa', -1);
      if v_t >= 0 and v_t <= 500 then v_taxa := round(v_t, 2); end if;
    end if;
  end if;
  v_total := round(v_orig - v_desc_val + v_taxa, 2);
  if v_total < 0.01 then return _falha('O total da venda precisa ser maior que zero.'); end if;
  if v_nivel = 'Garçom' and v_tipo_in <> 'Mesa' then
    v_pags := jsonb_build_array(jsonb_build_object('forma', v_pags->0->>'forma', 'valor', v_total));
  end if;

  -- pagamentos
  if exists (select 1 from jsonb_array_elements(v_pags) e where e->>'forma' = 'A Receber (Mesa)') then
    if jsonb_array_length(v_pags) <> 1 then return _falha('Forma de pagamento inválida para esta operação.'); end if;
    v_status_pag := 'A Receber';
  end if;
  for pg in select value as e from jsonb_array_elements(v_pags) loop
    if btrim(coalesce(pg.e->>'forma', '')) = '' then return _falha('Forma de pagamento não informada.'); end if;
    if not (_num(pg.e->>'valor', 0) > 0) then return _falha('Cada pagamento deve ter um valor maior que zero.'); end if;
    if btrim(pg.e->>'forma') = 'A Receber (Mesa)' then
      if v_nivel not in ('Admin','Operador','Garçom') or v_tipo_in <> 'Mesa' then return _falha('Forma de pagamento inválida para esta operação.'); end if;
      continue;
    end if;
    select * into v_forma_row from formas_pagamento where lower(nome) = lower(btrim(pg.e->>'forma')) limit 1;
    if not found then return _falha('Forma de pagamento não cadastrada: ' || btrim(pg.e->>'forma')); end if;
    if not v_forma_row.ativa then return _falha('A forma de pagamento está inativa: ' || btrim(pg.e->>'forma')); end if;
  end loop;
  select round(coalesce(sum(_num(e->>'valor')), 0), 2) into v_soma from jsonb_array_elements(v_pags) e;
  if abs(v_soma - v_total) > 0.02 then
    return _falha('A soma dos pagamentos (R$ ' || _dinheiro(v_soma) || ') não bate com o total da venda (R$ ' || _dinheiro(v_total) || ').');
  end if;

  -- acréscimo por forma de pagamento: os valores enviados são a parte do pedido paga em cada forma (sem acréscimo)
  for pg in select value as e from jsonb_array_elements(v_pags) loop
    if btrim(pg.e->>'forma') = 'A Receber (Mesa)' then continue; end if;
    v_acr := v_acr + _acrescimo_pagamento(pg.e->>'forma', round(_num(pg.e->>'valor') * (case when v_total > 0 then (v_total - v_taxa) / v_total else 1 end), 2));
  end loop;
  v_total := round(v_total + v_acr, 2);

  -- grava tudo
  v_status_pag_final := case when v_status_pag = 'A Receber' then 'A Receber' else 'Pago' end::status_pagamento;
  v_origem_final := (case when v_origem in ('Cardápio','Garçom') then v_origem else 'Balcão' end)::origem_venda;
  v_status_pedido_ini := (case when v_origem_final = 'Cardápio' then 'Recebido' else 'Em preparo' end)::status_pedido;
  select string_agg(btrim(e->>'forma'), ' + ') into v_resumo from jsonb_array_elements(v_pags) e;

  insert into vendas (id, cliente_nome, telefone_cliente, forma_pagamento, valor_total, custo_total, status, tipo, status_pedido,
                      endereco, complemento, referencia, observacoes_entrega, status_pagamento, recebido_em, valor_original, valor_desconto,
                      desconto_detalhe, origem, mesa_id, taxa_entrega, registrado_por, caixa_id, requisicao_id, acrescimo_forma)
  values (v_venda, v_nome, v_tel, v_resumo, v_total, v_custo, 'Confirmada', v_tipo, v_status_pedido_ini,
          case when v_tipo = 'Entrega' then coalesce(v_de->>'endereco', '') else '' end,
          case when v_tipo = 'Entrega' then coalesce(v_de->>'complemento', '') else '' end,
          case when v_tipo = 'Entrega' then coalesce(v_de->>'referencia', '') else '' end,
          coalesce(v_de->>'observacoes', ''), v_status_pag_final, case when v_status_pag_final = 'Pago' then now() else null end,
          v_orig, v_desc_val, v_desc_det, v_origem_final, case when v_tipo = 'Mesa' then v_mesa_id else null end, v_taxa, v_eu, v_caixa, v_req, v_acr)
  returning numero_pedido into v_numero;

  insert into itens_venda (venda_id, produto_id, combo_id, descricao, quantidade, valor_unitario, custo_unitario, valor_total_item, adicionais_ids)
  select v_venda, _uuid(e->>'produtoId'), _uuid(e->>'comboId'), e->>'descricao', _num(e->>'quantidade', 1)::int,
         _num(e->>'valorUnitario'), _num(e->>'custoUnitario'), round(_num(e->>'quantidade', 1) * _num(e->>'valorUnitario'), 2),
         coalesce((select array_agg(_uuid(x)) filter (where _uuid(x) is not null)
                   from jsonb_array_elements_text(case when jsonb_typeof(e->'adicionaisIds') = 'array' then e->'adicionaisIds' else '[]'::jsonb end) x), '{}')
  from jsonb_array_elements(v_itens) e;

  insert into pagamentos_venda (venda_id, forma_pagamento, valor, taxa_aplicada, acrescimo)
  select v_venda, btrim(e->>'forma'), _num(e->>'valor') + _acrescimo_pagamento(e->>'forma', _num(e->>'valor')),
         coalesce((select round((_num(e->>'valor') + _acrescimo_pagamento(e->>'forma', _num(e->>'valor'))) * f.taxa_percentual / 100 + f.taxa_fixa, 2) from formas_pagamento f where f.nome = btrim(e->>'forma')), 0),
         _acrescimo_pagamento(e->>'forma', _num(e->>'valor'))
  from jsonb_array_elements(v_pags) e;

  if v_tipo = 'Mesa' and v_mesa_status = 'Livre' then
    update mesas set status = 'Ocupada', garcom_responsavel_id = case when v_nivel = 'Garçom' then v_eu else garcom_responsavel_id end where id = v_mesa_id;
  elsif v_tipo = 'Mesa' and v_nivel = 'Garçom' and v_mesa_garcom is null then
    update mesas set garcom_responsavel_id = v_eu where id = v_mesa_id;
  end if;

  perform _ajustar_estoque(v_itens, 1, v_venda);

  if v_desc_val > 0 then
    perform _auditar('Desconto aplicado na venda', 'Autorizado por ' || coalesce(nullif(current_setting('app.autorizador', true), ''), v_login) || ' | Valor original: R$ ' || _dinheiro(v_orig)
      || ' → Desconto: ' || v_desc_det || ' → Valor final: R$ ' || _dinheiro(v_total), v_tel);
  end if;
  if v_tel <> '' then
    perform _upsert_cliente(v_tel, v_nome);
    if v_origem_final = 'Balcão' and v_status_pag_final = 'Pago' then
      perform _carimbar_fidelidade(v_tel, v_nome, v_venda);
      v_msg_extra := ' Marca de fidelidade adicionada para ' || v_nome || '.';
    end if;
  end if;
  perform _auditar('Venda registrada', 'Total R$ ' || _dinheiro(v_total) || ' via ' || v_resumo || ' (' || v_tipo || ', ' || v_status_pag_final || ')', v_tel);

  return jsonb_build_object('ok', true, 'message', 'Venda registrada: R$ ' || _dinheiro(v_total) || '.' || v_msg_extra,
                            'id', v_venda, 'numero', v_numero, 'valorTotal', v_total);
end $function$;

CREATE OR REPLACE FUNCTION public.api_confirmar_recebimento_pedido(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; v vendas; pg record; forma formas_pagamento; v_base numeric; v_soma numeric; v_acr numeric := 0; v_acr_p numeric; v_resumo text; v_troca boolean; v_i int; v_val numeric; v_taxa numeric; v_pid uuid;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  select * into t from _pedido_trava(p); v := t.v;
  if t.erro is not null then return case when v.status = 'Cancelada' then _falha('Este pedido foi cancelado — não dá para receber o pagamento.') else t.erro end; end if;
  if v.status_pagamento = 'Pago' then return jsonb_build_object('ok', true, 'duplicado', true, 'message', 'Este pedido já estava com o pagamento confirmado.'); end if;
  v_troca := jsonb_typeof(p->'pagamentos') = 'array' and jsonb_array_length(p->'pagamentos') > 0;
  if v_troca then
    if jsonb_array_length(p->'pagamentos') > 4 then return _falha('No máximo 4 formas de pagamento.'); end if;
    for pg in select value as e from jsonb_array_elements(p->'pagamentos') loop
      if btrim(coalesce(pg.e->>'forma','')) in ('', 'A Receber (Mesa)') then return _falha('Forma de pagamento inválida.'); end if;
      if not (_num(pg.e->>'valor', 0) > 0) then return _falha('Cada pagamento deve ter um valor maior que zero.'); end if;
      select * into forma from formas_pagamento where lower(nome) = lower(btrim(pg.e->>'forma')) limit 1;
      if not found then return _falha('Forma de pagamento não cadastrada: ' || btrim(pg.e->>'forma')); end if;
      if not forma.ativa then return _falha('A forma de pagamento está inativa: ' || btrim(pg.e->>'forma')); end if;
    end loop;
    v_base := round(v.valor_total - coalesce(v.acrescimo_forma, 0), 2);
    select round(coalesce(sum(_num(e->>'valor')), 0), 2) into v_soma from jsonb_array_elements(p->'pagamentos') e;
    if abs(v_soma - v_base) > 0.02 then return _falha('A soma dos pagamentos (R$ ' || _dinheiro(v_soma) || ') não bate com o valor do pedido (R$ ' || _dinheiro(v_base) || ').'); end if;
    -- reaproveita as linhas que já existem (sem apagar nada): linha i do pedido recebe o pagamento i;
    -- pagamento a mais vira linha nova; linha antiga que sobrar fica com valor zero na 1ª forma informada (não muda nenhuma soma).
    v_i := 0;
    for pg in select value as e, ordinality as n from jsonb_array_elements(p->'pagamentos') with ordinality loop
      v_acr_p := round(_acrescimo_pagamento(btrim(pg.e->>'forma'), _num(pg.e->>'valor')), 2);
      v_acr := v_acr + v_acr_p; v_i := pg.n;
      v_val := round(_num(pg.e->>'valor'), 2) + v_acr_p;
      v_taxa := coalesce((select round(v_val * f.taxa_percentual / 100 + f.taxa_fixa, 2) from formas_pagamento f where lower(f.nome) = lower(btrim(pg.e->>'forma'))), 0);
      select id into v_pid from pagamentos_venda where venda_id = v.id order by id offset (pg.n - 1) limit 1;
      if v_pid is not null then
        update pagamentos_venda set forma_pagamento = btrim(pg.e->>'forma'), valor = v_val, taxa_aplicada = v_taxa, acrescimo = v_acr_p where id = v_pid;
      else
        insert into pagamentos_venda (venda_id, forma_pagamento, valor, taxa_aplicada, acrescimo) values (v.id, btrim(pg.e->>'forma'), v_val, v_taxa, v_acr_p);
      end if;
      v_pid := null;
    end loop;
    update pagamentos_venda set valor = 0, taxa_aplicada = 0, acrescimo = 0, forma_pagamento = (select btrim(e->>'forma') from jsonb_array_elements(p->'pagamentos') e limit 1)
     where venda_id = v.id and id in (select id from pagamentos_venda where venda_id = v.id order by id offset v_i);
    select string_agg(btrim(e->>'forma'), ' + ') into v_resumo from jsonb_array_elements(p->'pagamentos') e;
    update vendas set status_pagamento = 'Pago', recebido_em = now(), forma_pagamento = v_resumo, valor_total = v_base + v_acr, acrescimo_forma = v_acr where id = v.id;
  else
    update vendas set status_pagamento = 'Pago', recebido_em = now() where id = v.id;
  end if;
  if nullif(v.telefone_cliente,'') is not null then perform _carimbar_fidelidade(v.telefone_cliente, v.cliente_nome, v.id); end if;
  perform _auditar('Pagamento confirmado', '#' || v.numero_pedido || case when v_troca and v_resumo is distinct from v.forma_pagamento then ' — forma: ' || coalesce(v.forma_pagamento,'?') || ' → ' || v_resumo else '' end, v.telefone_cliente);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public._mp_criar_venda(p_reserva uuid, p_pag uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r pedidos_reserva%rowtype; f formas_pagamento%rowtype; v_caixa uuid; v_venda uuid := gen_random_uuid(); v_numero int; v_cli uuid;
        v_cod text; rec record; v_tipo venda_tipo; v_de jsonb; v_nome text; v_cc uuid;
begin
  select * into r from pedidos_reserva where id = p_reserva for update;
  if not found then raise exception 'Reserva não encontrada.'; end if;
  select * into f from formas_pagamento where id = r.forma_pagamento_id;
  v_nome := coalesce(f.nome, 'Pagamento online');
  select id into v_caixa from caixa_sessoes where status = 'Aberto' limit 1;
  if v_caixa is null then raise exception 'Caixa fechado.'; end if;
  v_tipo := (case when r.tipo_entrega = 'Entrega' then 'Entrega' else 'Retirada' end)::venda_tipo;
  v_de := coalesce(r.dados_entrega, '{}'::jsonb);
  v_cod := coalesce(r.cupom->>'codigo', '');

  insert into vendas (id, cliente_nome, telefone_cliente, forma_pagamento, valor_total, custo_total, status, tipo, status_pedido,
                      endereco, complemento, referencia, observacoes_entrega, status_pagamento, recebido_em, valor_original, valor_desconto,
                      desconto_detalhe, origem, mesa_id, taxa_entrega, caixa_id, requisicao_id, acrescimo_forma)
  values (v_venda, r.cliente_nome, r.telefone, v_nome, r.valor_total, r.custo_total, 'Confirmada', v_tipo, 'Recebido',
          case when v_tipo = 'Entrega' then coalesce(v_de->>'endereco', '') else '' end, case when v_tipo = 'Entrega' then coalesce(v_de->>'complemento', '') else '' end,
          case when v_tipo = 'Entrega' then coalesce(v_de->>'referencia', '') else '' end, r.observacoes, 'Pago', now(), r.valor_original, r.valor_desconto,
          case when v_cod <> '' then 'Cupom ' || v_cod else '' end, 'Cardápio', null, r.taxa_entrega, v_caixa, r.requisicao_id, r.acrescimo_forma)
  returning numero_pedido into v_numero;

  insert into itens_venda (venda_id, produto_id, combo_id, descricao, quantidade, valor_unitario, custo_unitario, valor_total_item, adicionais_ids)
  select v_venda, _uuid(e->>'produtoId'), _uuid(e->>'comboId'), e->>'descricao', _num(e->>'quantidade', 1)::int, _num(e->>'valorUnitario'), _num(e->>'custoUnitario'),
         round(_num(e->>'quantidade', 1) * _num(e->>'valorUnitario'), 2),
         coalesce((select array_agg(_uuid(x)) filter (where _uuid(x) is not null) from jsonb_array_elements_text(e->'adicionaisIds') x), '{}')
  from jsonb_array_elements(r.itens) e;

  insert into pagamentos_venda (venda_id, forma_pagamento, valor, taxa_aplicada, acrescimo)
  values (v_venda, v_nome, r.valor_total, round(r.valor_total * coalesce(f.taxa_percentual, 0) / 100 + coalesce(f.taxa_fixa, 0), 2), r.acrescimo_forma);

  if r.telefone <> '' then
    v_cli := _upsert_cliente(r.telefone, r.cliente_nome);
    perform _carimbar_fidelidade(r.telefone, r.cliente_nome, v_venda);   -- como no recebimento manual: pedido pago = marca no cartão fidelidade
  end if;
  insert into contas_pedidos (venda_id, user_id) values (v_venda, r.user_id) on conflict do nothing;

  if r.cupom_uso_id is not null then update cupons_usos set venda_id = v_venda, cliente_id = v_cli where id = r.cupom_uso_id; end if;
  v_cc := _uuid(r.cupom->>'concedidoId');
  if v_cc is not null then update cupons_concedidos set venda_id = v_venda where id = v_cc; end if;
  for rec in select value as e from jsonb_array_elements(r.beneficios) loop
    if _uuid(rec.e->>'id') is not null then update contas_beneficios set venda_id = v_venda where id = _uuid(rec.e->>'id'); end if;
  end loop;

  update pedidos_reserva set estado = 'confirmada', venda_id = v_venda, atualizado_em = now() where id = r.id;
  update pagamentos_online set venda_id = v_venda, atualizado_em = now() where id = p_pag;
  perform _auditar_publico('Pedido pago pelo site (Mercado Pago)', 'Nº ' || v_numero || ' | Total R$ ' || _dinheiro(r.valor_total), r.telefone);
  return jsonb_build_object('vendaId', v_venda, 'numero', v_numero);
end $function$;

CREATE OR REPLACE FUNCTION public._trg_conta_cancelada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u uuid; bf record; mk record;
begin
  begin
    -- desfaz a marca de fidelidade que este pedido deu (vínculo guardado em fidelidade_marcas)
    for mk in select * from fidelidade_marcas where venda_id = new.id and not desfeita loop
      update fidelidade set carimbos = greatest(0, carimbos - 1), atualizada_em = now()
       where cliente_id = mk.cliente_id and carimbos > 0 and premios_resgatados = mk.premios_resgatados;
      if found then perform _auditar('Marca de fidelidade desfeita (venda cancelada)', 'Venda #' || new.numero_pedido); end if;
      update fidelidade_marcas set desfeita = true where venda_id = new.id;
    end loop;
    -- devolve o cupom recebido que foi usado neste pedido
    update cupons_concedidos set usado_em = null, venda_id = null where venda_id = new.id;
    update cupons_usos set user_id = null, telefone = '' where venda_id = new.id and cupom_id in (select id from cupons where automatico is not null);
    -- brindes usados neste pedido voltam: o de indicação fica disponível de novo e o cartão fidelidade reabre
    update contas_beneficios set status = 'Disponível', venda_id = null, usado_em = null, produto_id = null where venda_id = new.id and tipo = 'Indicação' and status = 'Usado';
    for bf in select b.id, cc.cliente_id from contas_beneficios b join contas_cliente cc on cc.user_id = b.user_id where b.venda_id = new.id and b.tipo = 'Fidelidade' and b.status = 'Usado' loop
      update fidelidade set carimbos = 10, premios_resgatados = greatest(0, premios_resgatados - 1), atualizada_em = now() where cliente_id = bf.cliente_id;
      update contas_beneficios set status = 'Anulado' where id = bf.id;
    end loop;
    -- indique e ganhe: se o pedido cancelado era o único concluído do indicado, o prêmio ainda não usado perde o efeito
    select user_id into u from contas_pedidos where venda_id = new.id;
    if u is not null and not exists (select 1 from contas_pedidos cp join vendas v on v.id = cp.venda_id
                                      where cp.user_id = u and v.id <> new.id and v.status = 'Confirmada' and v.status_pedido in ('Entregue', 'Retirada', 'Servida')) then
      update contas_beneficios set status = 'Anulado' where tipo = 'Indicação' and ref = u::text and status = 'Disponível';
      update cupons_concedidos set usado_em = now() where ref = u::text and origem in ('indicacao_indicador', 'indicacao_indicado') and usado_em is null and venda_id is null;
    end if;
  exception when others then null;
  end;
  return null;
end $function$;

-- F5-3: na edição da venda, a diferença a mais pode ser paga em outra forma (parâmetro opcional formaDiferenca; sem ele nada muda).
-- A função original passa a se chamar _editar_venda_base e api_editar_venda vira um envoltório que acerta os pagamentos depois dela.
do $$ begin
  if to_regprocedure('public._editar_venda_base(jsonb)') is null then
    alter function public.api_editar_venda(jsonb) rename to _editar_venda_base;
    revoke all on function public._editar_venda_base(jsonb) from public, anon, authenticated;
  end if;
end $$;

create or replace function public.api_editar_venda(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare r jsonb; v_fdif text := nullif(btrim(coalesce(p->>'formaDiferenca', '')), ''); v_id uuid := _uuid(p->>'id');
  fd formas_pagamento%rowtype; pv pagamentos_venda%rowtype; v_antes numeric; v_npag int; v_novo numeric; v_acr_novo numeric; v_dif numeric; v_acr_d numeric; v_total numeric;
begin
  if v_fdif is null then return _editar_venda_base(p); end if;
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select * into fd from formas_pagamento where lower(nome) = lower(v_fdif) and ativa;
  if not found then return _falha('A forma de pagamento da diferença não está disponível.'); end if;
  select count(*) into v_npag from pagamentos_venda where venda_id = v_id;
  select valor_total into v_antes from vendas where id = v_id;
  select * into pv from pagamentos_venda where venda_id = v_id limit 1;
  r := _editar_venda_base(p);
  if v_npag <> 1 or coalesce(r->>'ok', '') <> 'true' or lower(fd.nome) = lower(coalesce(pv.forma_pagamento, '')) then return r; end if;
  select valor_total, coalesce(acrescimo_forma, 0) into v_novo, v_acr_novo from vendas where id = v_id;
  v_dif := round((v_novo - v_acr_novo) - (v_antes - coalesce(pv.acrescimo, 0)), 2);   -- quanto os itens aumentaram (sem acréscimo de forma)
  if v_dif <= 0.009 then return r; end if;
  v_acr_d := _acrescimo_forma(fd, greatest(0.01, v_dif));
  v_total := round((v_novo - v_acr_novo) + coalesce(pv.acrescimo, 0) + v_acr_d, 2);
  -- o pagamento original volta ao que era e a diferença vira um segundo pagamento
  update pagamentos_venda set valor = pv.valor, acrescimo = pv.acrescimo, taxa_aplicada = pv.taxa_aplicada where id = pv.id;
  insert into pagamentos_venda (venda_id, forma_pagamento, valor, taxa_aplicada, acrescimo)
  values (v_id, fd.nome, round(v_dif + v_acr_d, 2), round((v_dif + v_acr_d) * fd.taxa_percentual / 100 + fd.taxa_fixa, 2), v_acr_d);
  update vendas set valor_total = v_total, acrescimo_forma = round(coalesce(pv.acrescimo, 0) + v_acr_d, 2) where id = v_id;
  perform _auditar('Venda editada: diferença em outra forma', 'R$ ' || _dinheiro(round(v_dif + v_acr_d, 2)) || ' em ' || fd.nome || ' (a venda era ' || coalesce(pv.forma_pagamento, '?') || ')');
  return r || jsonb_build_object('message', replace(coalesce(r->>'message', ''), 'Novo total: R$ ' || _dinheiro(v_novo), 'Novo total: R$ ' || _dinheiro(v_total)));
end $function$;
revoke all on function public.api_editar_venda(jsonb) from public, anon;
grant execute on function public.api_editar_venda(jsonb) to authenticated, service_role;

-- F5-2: o histórico da reconciliação guarda a hora em que a venda foi feita de verdade (a venda continua entrando no turno de hoje)
CREATE OR REPLACE FUNCTION public.api_reconciliar_venda_contingencia(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(left(btrim(coalesce(p->>'idFila','')), 120), '');
  d jsonb := p->'dados'; v_ja contingencia_reconciliada%rowtype; v_r jsonb; v_req text; v_venda uuid; v_origem text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_id is null or jsonb_typeof(d) <> 'object' or jsonb_typeof(d->'itens') <> 'array' then return _falha('Item da fila da contingência inválido.'); end if;
  perform pg_advisory_xact_lock(hashtext('recon:' || v_id));
  select * into v_ja from contingencia_reconciliada where id_fila = v_id;
  if found then return jsonb_build_object('ok', true, 'jaFeita', true, 'id', v_ja.venda_id); end if;

  v_origem := coalesce(d->>'origem', '');
  if v_origem = 'Cardápio' then
    -- mesmo caminho do pedido do cardápio; o id da fila vira requisicaoId (reenvio devolve o pedido já criado)
    v_r := _criar_pedido_publico((d - 'desconto' - 'senhaAdminConfirmacao') || jsonb_build_object('requisicaoId', v_id), null);
  elsif v_origem = 'Caixa' then
    -- usa o id da tentativa original: se o servidor chegou a gravar a venda antes de cair, não duplica
    v_req := coalesce(nullif(d->>'requisicaoOriginal', ''), v_id);
    v_r := api_iniciar_venda((d - 'desconto' - 'senhaAdminConfirmacao' - 'timestampOriginal' - 'requisicaoOriginal' - 'emergenciaOperador')
      || jsonb_build_object('origem', 'Balcão', 'requisicaoId', v_req));
  else
    return _falha('Origem desconhecida na fila: ' || left(v_origem, 40));
  end if;

  if coalesce(v_r->>'ok', '') <> 'true' then
    return jsonb_build_object('ok', false, 'message', coalesce(v_r->>'message', 'Não foi possível lançar a venda.'));
  end if;
  v_venda := nullif(v_r->>'id', '')::uuid;
  insert into contingencia_reconciliada (id_fila, venda_id, origem, usuario_id) values (v_id, v_venda, v_origem, auth.uid()) on conflict do nothing;
  perform _auditar('Venda da contingência reconciliada',
    'Fila ' || v_id || ' · origem ' || v_origem || ' · venda ' || left(coalesce(v_venda::text, ''), 8)
      || case when coalesce(d->>'timestampOriginal', '') <> '' then ' · feita em ' || left(d->>'timestampOriginal', 40) else '' end
      || case when coalesce(d->>'emergenciaOperador', '') <> '' then ' · feita em modo emergência por ' || left(d->>'emergenciaOperador', 40) else '' end, '');
  return jsonb_build_object('ok', true, 'id', v_venda, 'numero', v_r->'numero', 'duplicado', coalesce((v_r->>'duplicado')::boolean, false));
end $function$;

-- F7-2: o que o Admin altera direto nas telas de cadastro agora deixa registro no histórico (nome do item e quais campos mudaram; nunca o conteúdo).
-- Só registra pedidos feitos direto na tabela (PostgREST); mudanças feitas por funções do sistema já têm o próprio registro.
create or replace function public._trg_auditar_cadastro()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_path text := coalesce(current_setting('request.path', true), ''); n jsonb; o jsonb; v_nome text; v_campos text;
begin
  if auth.uid() is null or v_path = '' or v_path like '%/rpc/%' then return null; end if;
  n := to_jsonb(coalesce(new, old)); o := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  v_nome := left(coalesce(n->>'nome', n->>'ingrediente', n->>'chave', n->>'descricao', n->>'id', ''), 80);
  if tg_op = 'UPDATE' then
    select string_agg(k, ', ' order by k) into v_campos from jsonb_object_keys(n) k
     where n->k is distinct from o->k and k not in ('atualizado_em', 'updated_at', 'atualizada_em');
    if v_campos is null then return null; end if;
    if tg_table_name = 'estoque' and v_campos = 'quantidade' then return null; end if;   -- baixa por venda/compra tem histórico próprio
  end if;
  perform _auditar('Cadastro alterado direto (' || tg_table_name || ')', lower(tg_op) || ' · ' || v_nome || case when v_campos is not null then ' · campos: ' || left(v_campos, 200) else '' end);
  return null;
end $function$;
revoke all on function public._trg_auditar_cadastro() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['produtos','produto_precos','combos','combo_precos','adicionais','formas_pagamento','estoque','sistema','categorias'] loop
    if to_regclass('public.' || t) is not null then
      execute format('create or replace trigger trg_auditar_cadastro after insert or update or delete on public.%I for each row execute function public._trg_auditar_cadastro()', t);
    end if;
  end loop;
end $$;
