-- =====================================================================
-- 51 - Permissões explícitas (mudança do Supabase de 30/10/2026) e
--      limpeza diária do histórico do agendador (cron)
-- ---------------------------------------------------------------------
-- POR QUE: a partir de 30/10/2026 o Supabase deixa de dar permissão
-- automática às tabelas novas do schema public. Este arquivo grava, de
-- forma explícita, exatamente as permissões que o banco tem hoje
-- (conferidas no banco ao vivo em 25/10/2026). Assim, se for preciso
-- refazer o banco do zero, nada fica sem acesso.
--
-- SEGURO para rodar no banco atual: só CONCEDE o que já existe (não
-- tira nada, não apaga dado). Pode rodar mais de uma vez.
-- Tabela/visão que não existir é pulada sem erro.
--
-- REGRA PARA O FUTURO: toda tabela nova criada nos próximos arquivos
-- (52 em diante) já vem com o seu próprio GRANT no mesmo arquivo.
-- =====================================================================

create or replace function pg_temp.tb_grant(p_tipo text, p_nome text, p_papel text, p_privs text)
returns void language plpgsql as $f$
declare v_privs text := p_privs;
begin
  if to_regclass('public.' || quote_ident(p_nome)) is null then
    raise notice 'pulado (não existe): %', p_nome;
    return;
  end if;
  -- MAINTAIN só existe a partir do Postgres 17
  if current_setting('server_version_num')::int < 170000 then
    v_privs := regexp_replace(regexp_replace(v_privs, 'MAINTAIN,\s*', ''), ',\s*MAINTAIN', '');
    if v_privs = 'MAINTAIN' then return; end if;
  end if;
  execute format('grant %s on %s public.%I to %I', v_privs,
                 case when p_tipo = 's' then 'sequence' else 'table' end, p_nome, p_papel);
end $f$;

grant usage on schema public to anon, authenticated, service_role;

do $$
begin
  perform pg_temp.tb_grant('t', 'adicionais', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'adicionais', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_ajuda', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_ajuda', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_cache', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_config', 'authenticated', 'MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_log', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_log', 'authenticated', 'MAINTAIN, REFERENCES, SELECT, TRIGGER');
  perform pg_temp.tb_grant('t', 'ai_segredos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_uso', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ai_uso', 'authenticated', 'MAINTAIN, REFERENCES, SELECT, TRIGGER');
  perform pg_temp.tb_grant('t', 'ajustes_pos_venda', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ajustes_pos_venda', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'alertas_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'alertas_config', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'alertas_envios', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'alertas_envios', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'anonimizar_arquivo_fila', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'arquivo_historico', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'arquivo_historico', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'auditoria', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'auditoria', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'backup_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'backup_config', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'backups', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'backups', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'brindes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'brindes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'caixa_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'caixa_liberacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'caixa_sessoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'caixa_sessoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'cardapio_aparelhos_equipe', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'cardapio_visitas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'categorias', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'categorias', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'chat_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'chat_config', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'chat_conversas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'chat_conversas', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'chat_ia_cotas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'chat_mensagens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'chat_mensagens', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'chat_tokens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'clientes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'clientes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'combo_itens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'combo_itens', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'combo_precos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'combo_precos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'combos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'combos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_custos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_custos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_itens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_pagamentos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_pagamentos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_vinculos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'compra_vinculos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'compras', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'configuracoes_fotos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'configuracoes_fotos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'contas_acessos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contas_beneficios', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contas_cliente', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contas_enderecos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contas_pedidos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contingencia_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contingencia_config', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'contingencia_reconciliada', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'contingencia_reconciliada', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'cupons', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'cupons', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'cupons_concedidos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'cupons_usos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'cupons_usos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'despesas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'despesas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'despesas_recorrentes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'despesas_recorrentes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'entrega_destinos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'entregador_posicoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'entregador_posicoes', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'entregas_fechadas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'entregas_fechadas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'erros_cliente', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'erros_cliente', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'escala_padrao', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'escala_padrao', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'escala_trocas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'escala_trocas', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'escala_turnos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'escala_turnos', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'espaco_historico', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'estoque', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'estoque', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'etiqueta_impressoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'etiqueta_itens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos_custos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos_custos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos_recebimentos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'eventos_recebimentos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'evidencias_foto', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'faq_publico', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'faq_publico', 'authenticated', 'DELETE, INSERT, SELECT, UPDATE');
  perform pg_temp.tb_grant('t', 'fechamentos_entrega', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fechamentos_entrega', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'feedbacks', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'feedbacks', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'fidelidade', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fidelidade', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'fidelidade_marcas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fila_sync', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fila_sync', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'fiscal_empresa', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fiscal_empresa', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'fiscal_perfis', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fiscal_perfis', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'formas_pagamento', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'formas_pagamento', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'fornecedores', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fotos_historico', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'fotos_historico', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'funcionario_pagamentos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'funcionario_pagamentos', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'funcionarios', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'funcionarios', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'ifood_acoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_acoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_avaliacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_avaliacoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_cat_modelo', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_estado', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_estado', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_eventos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_eventos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_itens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_itens', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_lacunas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_loja', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_loja', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_negociacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_negociacoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_pedidos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_pedidos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_precos_hist', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_precos_hist', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_repasses', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_repasses', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_token', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ifood_token', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'indicacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'indicacoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_config', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_log', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_log', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_segredos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'integracoes_segredos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'integridade_checks', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'integridade_checks', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'itens_venda', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'itens_venda', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'mesas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'mesas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'mesas_codigos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'mesas_codigos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'movimentacoes_estoque', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'movimentacoes_estoque', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'nfce_inutilizacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'nfce_inutilizacoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'nfce_notas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'nfce_notas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'ocorrencias', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ocorrencias', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'pagamentos_online', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'pagamentos_online_eventos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'pagamentos_venda', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'pagamentos_venda', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'pedido_destinos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'pedido_destinos', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'pedidos_reserva', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ponto_registros', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'ponto_registros', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'ponto_rosto', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'preco_historico', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'preco_historico', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_adicionais', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_adicionais', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_ingredientes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_ingredientes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_precos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'produto_precos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'produtos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'produtos', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'promocoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'promocoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'push_cliente_pedidos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'push_clientes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'push_inscricoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'reembolsos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'reembolsos', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'requisicoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'requisicoes', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'sangrias', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'sangrias', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'sistema', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'sistema', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'sync_estado', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'sync_estado', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'tentativas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'tentativas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'usuarios', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'usuarios', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'vendas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'vendas', 'authenticated', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, UPDATE');
  perform pg_temp.tb_grant('t', 'vendas_resumo_arquivo', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'versoes_sync', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'faq_publico', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_adicionais', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_adicionais', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_adicionais', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_categorias', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_categorias', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_categorias', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_combo_itens', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_combo_itens', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_combo_itens', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_combos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_combos', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_combos', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_config', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_config', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_config', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_esgotados', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_esgotados', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_esgotados', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_formas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_formas', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_formas', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_mais_pedidos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_mais_pedidos', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_mais_pedidos', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_precos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_precos', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_precos', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_produtos', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_produtos', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_produtos', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_status', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_cardapio_status', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_cardapio_status', 'anon', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_fidelidade', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_fidelidade', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_formas_operacional', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_formas_operacional', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_indicacoes', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_indicacoes', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_itens_venda', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_itens_venda', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_mesas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_mesas', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_ocorrencias', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_ocorrencias', 'authenticated', 'SELECT');
  perform pg_temp.tb_grant('t', 'v_sessao_aberta', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_sessao_aberta', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('t', 'v_vendas', 'service_role', 'DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE');
  perform pg_temp.tb_grant('t', 'v_vendas', 'authenticated', 'MAINTAIN, SELECT');
  perform pg_temp.tb_grant('s', 'ai_ajuda_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ai_ajuda_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ai_log_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ai_log_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'anonimizar_arquivo_fila_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'anonimizar_arquivo_fila_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'arquivo_historico_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'arquivo_historico_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'auditoria_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'auditoria_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'chat_mensagens_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'chat_mensagens_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'erros_cliente_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'erros_cliente_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'fila_sync_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'fila_sync_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'fotos_historico_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'fotos_historico_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_acoes_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_acoes_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_lacunas_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_lacunas_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_precos_hist_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ifood_precos_hist_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'integracoes_log_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'integracoes_log_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'integridade_checks_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'integridade_checks_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'nfce_inutilizacoes_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'nfce_inutilizacoes_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'nfce_notas_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'nfce_notas_id_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ocorrencias_numero_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'ocorrencias_numero_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'vendas_numero_pedido_seq', 'service_role', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'vendas_numero_pedido_seq', 'authenticated', 'SELECT, UPDATE, USAGE');
  perform pg_temp.tb_grant('s', 'pagamentos_online_eventos_id_seq', 'service_role', 'SELECT, UPDATE, USAGE');
end $$;

-- ---------------------------------------------------------------------
-- Limpeza diária do histórico do agendador (já ligada no banco ao vivo
-- desde 24/10/2026). Apaga execuções com sucesso com mais de 3 dias e
-- qualquer execução com mais de 14 dias. Só cria se ainda não existir.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'limpar-historico-cron') then
    perform cron.schedule('limpar-historico-cron', '35 6 * * *',
      $c$delete from cron.job_run_details
       where (status = 'succeeded' and start_time < now() - interval '3 days')
          or start_time < now() - interval '14 days'$c$);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Avisos de segurança do Supabase (25/10/2026)
-- - 5 funções auxiliares sem "search_path" fixo: fixa o caminho (não
--   muda o resultado, são cálculos simples).
-- - _zz_teste_delete: sobra de teste vazia (begin null; end), não é
--   usada em lugar nenhum. Removida.
-- (As visões do cardápio "security definer" são de propósito: mostram
--  ao cliente só o que pode ser público. Ficam como estão.)
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['public._alertas_padrao()', 'public._escala_segunda(date)',
    'public._dist_metros(double precision,double precision,double precision,double precision)',
    'public._dist_descritor(double precision[],double precision[])'] loop
    if to_regprocedure(f) is not null then
      execute format('alter function %s set search_path = pg_catalog, public', f);
    end if;
  end loop;
end $$;
drop function if exists public._zz_teste_delete();

-- ---------------------------------------------------------------------
-- Sobra de agendamento: "compactar-1792355920" foi uma compactação de
-- uma vez só (18/10/2026 às 20:38), mas ficou marcada para TODO ano no
-- dia 18/10. Ela trava as tabelas de vendas enquanto roda. Removida.
-- ---------------------------------------------------------------------
do $$
declare j record;
begin
  -- só a sobra anual (a compactação marcada para todo 18/10); compactações de uma vez, marcadas pelo arquivamento, ficam
  for j in select jobname from cron.job where jobname like 'compactar-%' and schedule ~ '^\d+ \d+ 18 10 \*$' and jobname = 'compactar-1792355920' loop
    perform cron.unschedule(j.jobname);
  end loop;
end $$;
