-- 88 · Pedido do iFood que chega com o caixa fechado entra no próximo caixa que abrir (antes ficava sem caixa e fora do fechamento).
create or replace function public.api_abrir_caixa(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_fundo numeric := round(_num(p->>'fundoCaixa'), 2); v_id uuid; v_ult timestamptz; v_n int := 0;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  if v_fundo < 0 then return _falha('O fundo de caixa não pode ser negativo.'); end if;
  if exists (select 1 from caixa_sessoes where status = 'Aberto') then return _falha('Já existe um caixa aberto. Feche-o antes de abrir outro.'); end if;
  select max(fechamento) into v_ult from caixa_sessoes;
  begin
    insert into caixa_sessoes (fundo_caixa, usuario_abertura, status) values (v_fundo, auth.uid(), 'Aberto') returning id into v_id;
  exception when unique_violation then
    return _falha('Já existe um caixa aberto. Feche-o antes de abrir outro.');
  end;
  update vendas set caixa_id = v_id
   where caixa_id is null and canal = 'iFood' and status = 'Confirmada'
     and data_hora > coalesce(v_ult, now() - interval '1 day');
  get diagnostics v_n = row_count;
  perform _auditar('Caixa aberto', 'Fundo de caixa: R$ ' || _dinheiro(v_fundo) || case when v_n > 0 then ' · ' || v_n || ' pedido(s) do iFood recebido(s) com o caixa fechado ligado(s) a este caixa' else '' end);
  return jsonb_build_object('ok', true, 'message', 'Caixa aberto.' || case when v_n > 0 then ' ' || v_n || ' pedido(s) do iFood recebidos com o caixa fechado entraram neste caixa.' else '' end);
end $function$;

-- A tela passa a saber a que caixa cada venda pertence (para contar no turno o pedido do iFood que chegou antes da abertura).
create or replace view public.v_vendas as
 select id, numero_pedido as numero, data_hora, cliente_nome, telefone_cliente as cliente_telefone, forma_pagamento, valor_total,
        case when auth_nivel() = any (array['Admin'::nivel_acesso,'Operador'::nivel_acesso]) then custo_total else null::numeric end as custo_total,
        status, motivo_cancelamento, tipo as tipo_entrega, status_pedido, endereco, complemento, referencia, observacoes_entrega, pronta_em, concluida_em,
        status_pagamento, recebido_em, valor_original, valor_desconto, desconto_detalhe, _login_de(entregador_id) as entregador, saiu_em, origem, mesa_id,
        taxa_entrega, fechamento_entrega_id, _login_de(registrado_por) as registrado_por, inicio_preparo_em, _mesa_numero_de(mesa_id) as mesa_numero,
        acrescimo_forma, preferencias_cliente, canal, cliente_id, ifood_localizador, ifood_localizador_ate, caixa_id
   from vendas v where auth_nivel() is not null;
