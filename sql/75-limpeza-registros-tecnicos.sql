-- 75 · Registros técnicos guardados por menos tempo (o banco fica menor). Idempotente.
-- Histórico das tarefas automáticas: as que deram certo ficam 1 dia (antes 3); as com erro continuam 14 dias.
select cron.alter_job((select jobid from cron.job where jobname = 'limpar-historico-cron'), command := $c$delete from cron.job_run_details
       where (status = 'succeeded' and start_time < now() - interval '1 day')
          or start_time < now() - interval '14 days'$c$);
-- Fila de cópia para as planilhas: o que já foi copiado fica 7 dias (antes 30).
do $$ declare d text; begin
  select pg_get_functiondef('public.api_sync_limpar()'::regprocedure) into d;
  if d like '%interval ''30 days''%' then execute replace(d, 'interval ''30 days''', 'interval ''7 days'''); end if;
end $$;
