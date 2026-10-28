-- 37 · Ajustes para a homologação do iFood (tudo continua DESLIGADO por padrão)
-- 1) opção "modoHomologacao" liberada na tela de ajustes; 2) consulta ao iFood a cada 30 s; 3) "Acompanhar entrega" passa a usar
--    os eventos oficiais de entrega (ADR, GTO, AAO, CLT, AAD, DRGO, DRDO) que já chegam pela consulta; 4) tira a consulta /tracking não verificada.
do $$
declare d text;
begin
  select pg_get_functiondef('public.api_integracoes_config'::regproc) into d;
  if position('modoHomologacao' in d) = 0 then
    if position('''acompanharEntrega'')' in d) = 0 then raise exception 'ponto de troca não encontrado em api_integracoes_config'; end if;
    d := replace(d, '''acompanharEntrega'')', '''acompanharEntrega'', ''modoHomologacao'')');
    execute d;
  end if;
end $$;

create or replace function public.api_ifood_rastreios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if not coalesce((select (config->>'acompanharEntrega')::boolean from integracoes_config where provedor = 'ifood'), false) then return jsonb_build_object('ok', true, 'ligado', false); end if;
  return jsonb_build_object('ok', true, 'ligado', true, 'mapa', coalesce((
    select jsonb_object_agg(x.venda_id::text, jsonb_build_object('dados', jsonb_build_object('etapa', x.cod, 'em', x.quando), 'em', x.quando))
    from (
      select distinct on (i.venda_id) i.venda_id,
             upper(coalesce(nullif(e.codigo, ''), e.codigo_completo)) cod,
             coalesce(e.criado_ifood, e.recebido_em) quando
        from ifood_pedidos i
        join vendas v on v.id = i.venda_id
        join ifood_eventos e on e.pedido_ifood = i.pedido_ifood
       where v.status_pedido::text in ('Pronta', 'Saiu para entrega')
         and e.recebido_em > now() - interval '6 hours'
         and (upper(e.codigo) in ('ADR','GTO','AAO','CLT','AAD','DRGO','DRDO')
              or upper(e.codigo_completo) in ('ASSIGN_DRIVER','GOING_TO_ORIGIN','ARRIVED_AT_ORIGIN','COLLECTED','ARRIVED_AT_DESTINATION'))
       order by i.venda_id, coalesce(e.criado_ifood, e.recebido_em) desc
    ) x), '{}'::jsonb));
end $$;

do $$
begin
  perform cron.unschedule('ifood-rastreio-minuto');
exception when others then null;
end $$;
select cron.alter_job((select jobid from cron.job where jobname = 'ifood-sync-minuto'), schedule := '30 seconds');
