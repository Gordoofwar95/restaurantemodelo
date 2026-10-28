-- 87 — Segurança (aviso do Supabase): 1) as telas v_vendas e v_fidelidade deixavam QUALQUER pessoa logada (inclusive cliente do cardápio) ler todas as vendas e a lista de fidelidade; agora só a equipe.
--      2) funções internas da equipe deixam de ser chamáveis sem login (já negavam, agora nem executam).
do $$ declare d text; begin
  d := regexp_replace(pg_get_viewdef('public.v_vendas'::regclass), ';\s*$', '');
  if d !~ 'auth_nivel\(\) IS NOT NULL' then execute 'create or replace view public.v_vendas as ' || d || ' WHERE auth_nivel() IS NOT NULL'; end if;
  d := regexp_replace(pg_get_viewdef('public.v_fidelidade'::regclass), ';\s*$', '');
  if d !~ 'auth_nivel\(\) IS NOT NULL' then execute 'create or replace view public.v_fidelidade as ' || d || ' AND auth_nivel() IS NOT NULL'; end if;
end $$;
do $$ declare f text; begin
  foreach f in array array['api_ajustar_precos_produtos_lote','api_alertas_config','api_alertas_pedido_adiar','api_alertas_pedidos','api_alertas_salvar','api_alertas_teste','api_cancelar_movimento_evento','api_cancelar_pagamento_funcionario','api_editar_compra_info','api_equipe_folha','api_equipe_importar_acessos','api_equipe_peso_mao_obra','api_equipe_reserva','api_escala_aplicar_padrao','api_escala_avisar','api_escala_copiar_semana','api_escala_padrao_salvar','api_escala_semana','api_espaco_historico','api_espaco_plano_salvar','api_estoque_sugestao','api_estornar_compra','api_evento_horas_salvar','api_evento_movimentos','api_evento_rendimento','api_margem_alerta','api_margem_config_salvar','api_margem_ignorar','api_margem_sugestao','api_minha_escala','api_pagar_funcionario','api_ponto_ajustar','api_ponto_bater','api_ponto_estado','api_ponto_relatorio','api_preco_historico','api_salvar_funcionario','api_salvar_turno','api_troca_decidir','api_troca_responder','api_troca_solicitar','api_trocas_lista','api_visibilidade_lote_produtos'] loop
    execute format('revoke execute on function public.%I(jsonb) from public, anon', f);
    execute format('grant execute on function public.%I(jsonb) to authenticated, service_role', f);
  end loop;
  revoke execute on function public._cliente_tem_endereco(uuid, text) from public, anon;
  grant execute on function public._cliente_tem_endereco(uuid, text) to authenticated, service_role;
end $$;
