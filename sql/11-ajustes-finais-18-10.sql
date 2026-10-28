-- 11 - Ajustes finais da auditoria de 18/10 (F4-1 e F6-1). Pode rodar de novo sem problema.
-- F4-1: ao trocar o entregador, avisa se outra pessoa já tinha trocado (a tela manda 'entregadorVisto'; telas antigas continuam funcionando).
-- F6-1: no histórico do estoque, a devolução de uma venda editada/cancelada aparece como 'Estorno da venda #...'.
CREATE OR REPLACE FUNCTION public.api_atribuir_entregador(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; v vendas; u usuarios; lg text := btrim(coalesce(p->>'entregador','')); ant text;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  if lg <> '' then
    select * into u from usuarios where lower(login) = lower(lg);
    if not found or u.nivel::text <> 'Entregador' then return _falha('Esse usuário não é um entregador cadastrado.'); end if;
    if not u.ativo then return _falha('Esse entregador está inativo.'); end if;
  end if;
  select * into t from _pedido_trava(p); v := t.v; if t.erro is not null then return t.erro; end if;
  if v.tipo <> 'Entrega' then return _falha('Só pedidos de entrega têm entregador.'); end if;
  if v.status_pedido::text = 'Entregue' then return _falha('Esta entrega já foi concluída.'); end if;
  if v.status_pedido::text = 'Saiu para entrega' and lg = '' then return _falha('O pedido já saiu para entrega — troque o entregador, não remova.'); end if;
  -- conflito: a tela mostrava um entregador e, enquanto isso, outra pessoa já trocou (só confere se a tela informou quem viu)
  if p ? 'entregadorVisto' and lower(coalesce(_login_de(v.entregador_id), '')) <> lower(btrim(coalesce(p->>'entregadorVisto', ''))) then
    return _conflito('O entregador deste pedido foi alterado por outra pessoa enquanto você editava. A tela foi atualizada — confira e atribua de novo.');
  end if;
  ant := coalesce(_login_de(v.entregador_id), '(nenhum)');
  update vendas set entregador_id = case when lg = '' then null else u.id end where id = v.id;
  perform _auditar('Entregador atribuído', '#' || v.numero_pedido || ': ' || ant || ' → ' || coalesce(nullif(lg,''), '(nenhum)'));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public._ajustar_estoque(p_itens jsonb, p_dir integer, p_venda uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; e estoque%rowtype; v_delta numeric; v_novo numeric;
        v_ref text := case when p_venda is not null then (case when p_dir < 0 then 'Estorno da venda #' else 'Venda #' end) || left(p_venda::text, 8) else case when p_dir > 0 then 'Venda' else 'Estorno de venda' end end;
        v_uid uuid := (select u.id from usuarios u where u.id = auth.uid());  -- cliente com conta não é da equipe: a movimentação fica sem usuário
begin
  for r in select * from _consumo(p_itens) order by ingrediente_id loop
    select * into e from estoque where id = r.ingrediente_id for update;
    if not found then continue; end if;
    v_delta := p_dir * r.qtd;
    v_novo := round(e.quantidade - v_delta, 3);
    update estoque set quantidade = v_novo where id = e.id;
    if p_dir > 0 and v_novo < 0 then perform _auditar('Estoque negativo', e.ingrediente || ': ' || v_novo || ' (' || v_ref || ')'); end if;
    if v_delta <> 0 then
      insert into movimentacoes_estoque (ingrediente_id, tipo, quantidade, qtd_antes, qtd_depois, motivo_referencia, usuario_id)
      values (e.id, (case when p_dir > 0 then 'Venda' else 'Saída' end)::tipo_mov_estoque, -v_delta, e.quantidade, v_novo, v_ref, v_uid);
    end if;
  end loop;
end $function$;
