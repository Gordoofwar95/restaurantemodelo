-- Fase 5 (F5-1): ao confirmar o recebimento de pedido "A Receber", o operador informa a forma em que o cliente pagou de verdade
-- (antes ficava a forma escolhida no pedido: "Dinheiro" pago no Pix fazia o caixa esperar dinheiro na gaveta).
-- Sem "pagamentos" no corpo: comportamento antigo (mantém a forma do pedido).
create or replace function public.api_confirmar_recebimento_pedido(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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
  if nullif(v.telefone_cliente,'') is not null then perform _carimbar_fidelidade(v.telefone_cliente, v.cliente_nome); end if;
  perform _auditar('Pagamento confirmado', '#' || v.numero_pedido || case when v_troca and v_resumo is distinct from v.forma_pagamento then ' — forma: ' || coalesce(v.forma_pagamento,'?') || ' → ' || v_resumo else '' end, v.telefone_cliente);
  return jsonb_build_object('ok', true);
end $function$;
