-- =====================================================================
-- RESTAURANTE DEMO · 03-agendamentos.sql  (26 tarefas do pg_cron, iguais às do Supabase em 18/10/2026)
-- Rode POR ÚLTIMO, depois de recriar os segredos do Vault (LEIA-ME-REFAZER.txt, passo 4): várias tarefas chamam as Edge Functions
-- por public.chamar_edge(), que usa o segredo 'service_key' do Vault.
-- =====================================================================
select cron.schedule('ai_limpeza', '15 6 * * *', '
  delete from public.ai_cache where expira_em < now();
  delete from public.ai_log where criado_em < now() - interval ''30 days'';
  delete from public.ai_uso where dia < current_date - 90;
');
select cron.schedule('arquivar-diario', '0 8 * * *', ' select public.chamar_edge(''arquivar-antigos'',''{}''::jsonb); ');
select cron.schedule('arquivar-emergencia-horario', '30 * * * *', ' select public.chamar_edge(''arquivar-antigos'',''{"emergencia":true}''::jsonb); ');
select cron.schedule('auditoria-ip-limpeza', '50 6 * * *', 'update public.auditoria set ip = null where ip is not null and data_hora < now() - interval ''90 days''');
select cron.schedule('backup-horario', '0 * * * *', ' select public.chamar_edge(''criar-backup'',''{"tipo":"Automático","cron":true}''); ');
select cron.schedule('chat-limpeza-diaria', '45 6 * * *', '
  delete from public.entregador_posicoes where atualizado_em < now() - interval ''12 hours'';
  delete from public.pedido_destinos d using public.vendas v
   where v.id = d.venda_id and (v.status_pedido::text in (''Entregue'', ''Retirada'', ''Servida'') or d.criado_em < now() - interval ''2 days'');
  delete from public.chat_conversas where estado = ''recepcao'' and atualizado_em < now() - interval ''2 days'';
');
select cron.schedule('contas-aniversarios', '10 9 * * *', 'select public._job_aniversarios()');
select cron.schedule('contas-campanhas', '20 9 * * *', 'select public._job_campanhas()');
select cron.schedule('contas-inativas', '50 4 * * 0', 'select public._job_contas_inativas()');
select cron.schedule('contas-sem-aceite', '40 4 * * 0', 'select public._job_contas_sem_aceite()');
select cron.schedule('contingencia-espelho-10min', '3,13,23,33,43,53 * * * *', ' select public.chamar_edge(''planilha-admin'', ''{"acao":"sincronizarContingencia","rapido":true}''::jsonb); ');
select cron.schedule('contingencia-espelho-diario', '0 6 * * *', ' select public.chamar_edge(''planilha-admin'', ''{"acao":"sincronizarContingencia"}''::jsonb); ');
select cron.schedule('erros_cliente_limpeza', '30 6 * * *', ' delete from public.erros_cliente where criado_em < now() - interval ''14 days'' ');
select cron.schedule('ifood-limpeza-diaria', '55 6 * * *', 'select public.ifood_limpar()');
select cron.schedule('ifood-sync-minuto', '* * * * *', 'select case when public._integracao_ligada(''ifood'') then public.chamar_edge(''ifood-sync'', ''{}''::jsonb) end');
select cron.schedule('integridade-diaria', '10 9 * * *', ' select public.chamar_edge(''conferir-integridade'',''{"cron":true}''::jsonb); ');
select cron.schedule('lgpd-anonimizar', '30 4 * * 0', 'select public._job_lgpd_anonimizar()');
select cron.schedule('mp-cancelar-pix', '* * * * *', 'select case when jsonb_array_length(public.mp_pendentes_cancelar()) > 0 then public.chamar_edge(''mp-cancelar'', ''{}''::jsonb) end');
select cron.schedule('mp-expirar-reservas', '* * * * *', 'select public.mp_expirar_reservas()');
select cron.schedule('mp-lgpd-diario', '30 5 * * *', 'select public._job_mp_lgpd()');
select cron.schedule('nfce-emitir-minuto', '* * * * *', 'select case when public._integracao_ligada(''nfce'') and (exists (select 1 from public.nfce_notas where estado in (''pendente'', ''duvida'', ''contingencia'', ''cancelando'') and emitir_apos <= now() and proxima_tentativa <= now()) or exists (select 1 from public.nfce_inutilizacoes where estado in (''pendente'', ''duvida''))) then public.chamar_edge(''nfce-emitir'', ''{}''::jsonb) end');
select cron.schedule('ping-2dias', '0 12 */2 * *', ' select public.chamar_edge(''ping'',''{}''::jsonb); ');
select cron.schedule('push-clientes-feedback', '*/5 * * * *', 'select public._push_clientes_feedback()');
select cron.schedule('sync-alerta-30min', '*/30 * * * *', ' select public.api_sync_verificar_alerta(); ');
select cron.schedule('sync-fila-2min', '*/2 * * * *', ' select public.chamar_edge(''sync-fila'',''{}''::jsonb); ');
select cron.schedule('sync-limpar-diario', '0 6 * * *', ' select public.api_sync_limpar(); ');

