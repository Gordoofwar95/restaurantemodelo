-- =====================================================================
-- 56 - Arquivo no Storage do Supabase (P-08) + espaço liberado de verdade
--      + previsão de quando enche + tela Armazenamento
-- ---------------------------------------------------------------------
-- Caminho dos dados antigos:  banco → Storage (bucket privado "arquivo")
--                             → planilha (só quando o Storage passa de 95%).
-- Nada sai de um lugar sem o outro confirmar que recebeu tudo.
-- Compactação (VACUUM FULL, que devolve o espaço de verdade): só às 05:30
-- de Brasília (depois do backup das 4h e do arquivamento das 5h). Mede o
-- tamanho antes e depois e avisa o Admin se o espaço não diminuir.
-- Tudo aditivo. Pode rodar mais de uma vez.
-- =====================================================================

insert into storage.buckets (id, name, public) values ('arquivo', 'arquivo', false) on conflict (id) do nothing;

alter table public.backup_config add column if not exists storage_limite_mb integer not null default 1024;
alter table public.espaco_historico add column if not exists storage_bytes bigint;

create table if not exists public.arquivo_mapa (
  id bigserial primary key,
  tipo text not null check (tipo in ('vendas', 'caixa')),
  mes text not null check (mes ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  local text not null default 'storage' check (local in ('storage', 'planilha')),
  caminho text not null unique,
  qtd integer not null default 0,
  bytes bigint not null default 0,
  criado_em timestamptz not null default now(),
  movido_em timestamptz
);
create index if not exists ix_arquivo_mapa_mes on public.arquivo_mapa (tipo, mes);
alter table public.arquivo_mapa enable row level security;
revoke all on table public.arquivo_mapa from public, anon, authenticated;
grant all on table public.arquivo_mapa to service_role;
grant usage, select on sequence public.arquivo_mapa_id_seq to service_role;

create table if not exists public.arquivo_execucoes (
  id bigserial primary key,
  em timestamptz not null default now(),
  gatilho text not null,             -- idade | banco95 | storage95 | manual | autoteste | resumo
  origem text not null default '',
  destino text not null default '',
  qtd integer not null default 0,
  arquivos integer not null default 0,
  ms integer,
  erro text,
  db_bytes_antes bigint,
  db_bytes_depois bigint,
  liberado_bytes bigint,
  medido_em timestamptz
);
create index if not exists ix_arquivo_execucoes_em on public.arquivo_execucoes (em desc);
alter table public.arquivo_execucoes enable row level security;
revoke all on table public.arquivo_execucoes from public, anon, authenticated;
grant all on table public.arquivo_execucoes to service_role;
grant usage, select on sequence public.arquivo_execucoes_id_seq to service_role;

-- ---------------------------------------------------------------------
-- Tamanho do Storage
-- ---------------------------------------------------------------------
create or replace function public._storage_bytes(p_bucket text default null) returns bigint
 language sql stable security definer set search_path to 'public', 'storage' as $$
  select coalesce(sum((o.metadata->>'size')::bigint), 0)::bigint from storage.objects o where p_bucket is null or o.bucket_id = p_bucket
$$;
revoke all on function public._storage_bytes(text) from public, anon, authenticated;
grant execute on function public._storage_bytes(text) to service_role;

create or replace function public.api_storage_percentual_servico() returns numeric
 language sql stable security definer set search_path to 'public' as $$
  select round(_storage_bytes() / 1048576.0 / greatest(coalesce((select storage_limite_mb from backup_config where id), 1024), 1) * 100, 1)
$$;
revoke all on function public.api_storage_percentual_servico() from public, anon, authenticated;
grant execute on function public.api_storage_percentual_servico() to service_role;

-- foto diária do tamanho: agora também do Storage
create or replace function public._espaco_snapshot() returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  insert into espaco_historico (dia, db_bytes, vendas_ativas, storage_bytes)
  values ((now() at time zone 'America/Sao_Paulo')::date, pg_database_size(current_database()), (select count(*) from vendas), _storage_bytes())
  on conflict (dia) do update set db_bytes = excluded.db_bytes, vendas_ativas = excluded.vendas_ativas, storage_bytes = excluded.storage_bytes;
end $function$;

-- avisos do Storage (70% e 85%), no máximo um por dia por faixa
create or replace function public.api_storage_alerta_servico() returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_pct numeric := api_storage_percentual_servico(); v_faixa int; v_chave text; v_hoje text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
begin
  v_faixa := case when v_pct >= 85 then 85 when v_pct >= 70 then 70 else 0 end;
  if v_faixa = 0 then return jsonb_build_object('ok', true, 'pct', v_pct); end if;
  v_chave := 'storage_alerta_' || v_faixa;
  if exists (select 1 from sistema where chave = v_chave and valor #>> '{}' = v_hoje) then return jsonb_build_object('ok', true, 'pct', v_pct, 'jaAvisado', true); end if;
  insert into sistema (chave, valor, atualizado_em) values (v_chave, to_jsonb(v_hoje), now()) on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  begin
    perform _push_admins('Storage do Supabase em ' || v_pct || '%',
      case when v_faixa = 85 then 'Perto do limite: a partir de 95% os arquivos mais antigos vão sozinhos para a planilha. Veja Administrador → Backup e espaço → Armazenamento.'
           else 'Acima de 70%. Nada a fazer agora; acompanhe em Administrador → Backup e espaço → Armazenamento.' end, 'storage-' || v_faixa);
  exception when others then null; end;
  return jsonb_build_object('ok', true, 'pct', v_pct, 'avisado', v_faixa);
end $function$;
revoke all on function public.api_storage_alerta_servico() from public, anon, authenticated;
grant execute on function public.api_storage_alerta_servico() to service_role;

-- ---------------------------------------------------------------------
-- Compactação: só às 05:30 de Brasília (08:30 UTC), uma pendente por vez
-- ---------------------------------------------------------------------
create or replace function public._compactar_agendar() returns void
 language plpgsql security definer set search_path to 'public', 'cron' as $function$
declare r record; v_pendente boolean := false; v_quando timestamptz; v_base timestamp;
begin
  for r in select jobname from cron.job where jobname like 'compactar-%' loop
    if coalesce(nullif(substring(r.jobname from 'compactar-(\d+)'), '')::bigint, 0) < extract(epoch from now() - interval '15 minutes') then
      perform cron.unschedule(r.jobname);                        -- já rodou (ou ficou para trás): sai da lista
    else v_pendente := true; end if;
  end loop;
  if v_pendente then return; end if;
  -- próxima 05:30 em Brasília (= 08:30 UTC)
  v_base := date_trunc('day', now() at time zone 'UTC') + interval '8 hours 30 minutes';
  v_quando := (v_base at time zone 'UTC');
  if v_quando <= now() + interval '2 minutes' then v_quando := v_quando + interval '1 day'; end if;
  perform cron.schedule('compactar-' || floor(extract(epoch from v_quando))::bigint,
    extract(minute from v_quando at time zone 'UTC')::int || ' ' || extract(hour from v_quando at time zone 'UTC')::int || ' ' ||
    extract(day from v_quando at time zone 'UTC')::int || ' ' || extract(month from v_quando at time zone 'UTC')::int || ' *',
    'vacuum full public.vendas, public.itens_venda, public.pagamentos_venda, public.caixa_sessoes, public.sangrias, public.vendas_resumo_arquivo, public.arquivo_historico');
end $function$;
revoke all on function public._compactar_agendar() from public, anon, authenticated;
grant execute on function public._compactar_agendar() to service_role;

-- 06:00 de Brasília: mede quanto a compactação liberou e avisa se não diminuiu
create or replace function public._arquivo_medir_compactacao() returns void
 language plpgsql security definer set search_path to 'public', 'cron' as $function$
declare v_db bigint := pg_database_size(current_database()); e record; v_rodou boolean;
begin
  -- só tira da lista o agendamento que já rodou (NÃO marca outro: a próxima compactação só é marcada quando algo sair do banco)
  for e in select jobname from cron.job where jobname like 'compactar-%' loop
    if coalesce(nullif(substring(e.jobname from 'compactar-(\d+)'), '')::bigint, 0) < extract(epoch from now() - interval '15 minutes') then perform cron.unschedule(e.jobname); end if;
  end loop;
  v_rodou := exists (select 1 from cron.job_run_details d where d.command like 'vacuum full public.vendas%' and d.start_time > now() - interval '3 hours' and d.status = 'succeeded');
  if not v_rodou then return; end if;
  for e in select * from arquivo_execucoes where medido_em is null and db_bytes_antes is not null and qtd > 0 and em < now() - interval '20 minutes' order by em loop
    update arquivo_execucoes set db_bytes_depois = v_db, liberado_bytes = db_bytes_antes - v_db, medido_em = now() where id = e.id;
  end loop;
  if exists (select 1 from arquivo_execucoes where medido_em > now() - interval '5 minutes' and liberado_bytes <= 0) then
    begin
      perform _push_admins('Arquivamento: o espaço do banco não diminuiu',
        'Os dados antigos saíram do banco, mas o tamanho não caiu depois da compactação. Veja Administrador → Sistema → Armazenamento.', 'arquivo-sem-liberar');
    exception when others then null; end;
  end if;
end $function$;
revoke all on function public._arquivo_medir_compactacao() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'arquivo-medir-compactacao') then
    perform cron.schedule('arquivo-medir-compactacao', '0 9 * * *', 'select public._arquivo_medir_compactacao()');
  end if;
  -- a cada hora: proteção do Storage (95% → planilha) e avisos 70%/85%
  if not exists (select 1 from cron.job where jobname = 'arquivo-protecao-storage') then
    perform cron.schedule('arquivo-protecao-storage', '41 * * * *', $c$ select public.chamar_edge('arquivar-antigos', '{"storage":true}'::jsonb); $c$);
  end if;
  -- todo dia 1 às 06:15 de Brasília: autoteste do caminho banco → Storage → planilha (com dados de TESTE) e cópia mensal do resumo
  if not exists (select 1 from cron.job where jobname = 'arquivo-autoteste-mensal') then
    perform cron.schedule('arquivo-autoteste-mensal', '15 9 1 * *', $c$ select public.chamar_edge('arquivar-antigos', '{"autoteste":true,"resumoMensal":true}'::jsonb); $c$);
  end if;
end $$;

-- resumo de um mês (para a cópia de segurança mensal na planilha): por dia, pedidos e total (ativos + arquivados)
create or replace function public.api_resumo_mes_servico(p_mes text) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
declare v_ini date; v_fim date;
begin
  if p_mes !~ '^\d{4}-(0[1-9]|1[0-2])$' then return jsonb_build_object('ok', false, 'message', 'Mês inválido.'); end if;
  v_ini := (p_mes || '-01')::date; v_fim := (v_ini + interval '1 month')::date;
  return jsonb_build_object('ok', true, 'mes', p_mes, 'dias', coalesce((
    select jsonb_agg(jsonb_build_object('dia', dia, 'pedidos', n, 'total', tot, 'cancelados', canc) order by dia) from (
      select (data_hora at time zone 'America/Sao_Paulo')::date dia, count(*) filter (where status::text = 'Confirmada') n,
             coalesce(sum(valor_total) filter (where status::text = 'Confirmada'), 0) tot, count(*) filter (where status::text = 'Cancelada') canc
        from (select data_hora, status::text status, valor_total from vendas
              union all select data_hora, status, valor_total from vendas_resumo_arquivo) t
       where (data_hora at time zone 'America/Sao_Paulo')::date >= v_ini and (data_hora at time zone 'America/Sao_Paulo')::date < v_fim
       group by 1) x), '[]'::jsonb));
end $function$;
revoke all on function public.api_resumo_mes_servico(text) from public, anon, authenticated;
grant execute on function public.api_resumo_mes_servico(text) to service_role;

-- ---------------------------------------------------------------------
-- Tela "Armazenamento" (Admin)
-- ---------------------------------------------------------------------
create or replace function public.api_armazenamento_painel(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_lim_db numeric := _limite_banco_mb(); v_lim_st numeric; v_db numeric := pg_database_size(current_database()) / 1048576.0; v_st numeric;
        v_n int; v_sdb numeric; v_sst numeric; v_cel bigint; v_cel_em timestamptz; v_novo int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_novo := nullif(p->>'storageLimiteMb', '')::int;
  if v_novo is not null then
    if v_novo < 100 or v_novo > 10000000 then return _falha('Informe o limite do Storage em MB (entre 100 e 10.000.000). Grátis: 1024.'); end if;
    if coalesce((api_verificar_senha_admin(jsonb_build_object('senha', coalesce(p->>'senha', '')))->>'ok')::boolean, false) is not true then
      return _falha('Senha incorreta. O limite não foi alterado.');
    end if;
    update backup_config set storage_limite_mb = v_novo where id;
    perform _auditar('Limite do Storage alterado', v_novo || ' MB');
  end if;
  perform _espaco_snapshot();
  select storage_limite_mb into v_lim_st from backup_config where id;
  v_lim_st := coalesce(v_lim_st, 1024);
  v_st := _storage_bytes() / 1048576.0;
  select count(*), regr_slope(db_bytes::double precision, extract(epoch from dia::timestamp)::double precision) * 86400 / 1048576.0,
         regr_slope(storage_bytes::double precision, extract(epoch from dia::timestamp)::double precision) filter (where storage_bytes is not null) * 86400 / 1048576.0
    into v_n, v_sdb, v_sst from espaco_historico where dia >= current_date - 44;
  select (valor #>> '{}')::bigint, atualizado_em into v_cel, v_cel_em from sistema where chave = 'planilha_celulas';
  return jsonb_build_object('ok', true,
    'banco', jsonb_build_object('mb', round(v_db, 1), 'limiteMb', v_lim_db, 'pct', round(v_db / v_lim_db * 100, 1),
       'crescimentoMbDia', case when v_n >= 5 then round(v_sdb, 3) end,
       'diasAte95', case when v_n >= 5 and v_sdb > 0.0001 then floor(greatest(0, (v_lim_db * 0.95 - v_db) / v_sdb)) end,
       'maiores', coalesce((select jsonb_agg(jsonb_build_object('tabela', relname, 'mb', mb) order by mb desc)
          from (select c.relname, round(pg_total_relation_size(c.oid) / 1048576.0, 1) mb from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname in ('public', 'cron') and c.relkind = 'r' order by pg_total_relation_size(c.oid) desc limit 8) t), '[]'::jsonb)),
    'storage', jsonb_build_object('mb', round(v_st, 2), 'limiteMb', v_lim_st, 'pct', round(v_st / v_lim_st * 100, 1),
       'crescimentoMbDia', case when v_n >= 5 and v_sst is not null then round(v_sst, 3) end,
       'diasAte95', case when v_n >= 5 and v_sst > 0.0001 then floor(greatest(0, (v_lim_st * 0.95 - v_st) / v_sst)) end,
       'buckets', coalesce((select jsonb_agg(jsonb_build_object('bucket', b.id, 'arquivos', (select count(*) from storage.objects o where o.bucket_id = b.id), 'mb', round(_storage_bytes(b.id) / 1048576.0, 2)) order by b.id) from storage.buckets b), '[]'::jsonb)),
    'planilha', jsonb_build_object('celulas', v_cel, 'limite', 10000000, 'pct', case when v_cel is not null then round(v_cel / 100000.0, 1) end, 'medidoEm', v_cel_em),
    'arquivo', coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'tipo', tipo, 'storage', st, 'planilha', pl) order by mes desc, tipo)
        from (select mes, tipo, sum(qtd) filter (where local = 'storage') st, sum(qtd) filter (where local = 'planilha') pl from arquivo_mapa group by 1, 2) m), '[]'::jsonb),
    'execucoes', coalesce((select jsonb_agg(jsonb_build_object('em', em, 'gatilho', gatilho, 'origem', origem, 'destino', destino, 'qtd', qtd, 'arquivos', arquivos,
        'erro', erro, 'liberadoMb', round(liberado_bytes / 1048576.0, 1), 'medido', medido_em is not null) order by em desc)
        from (select * from arquivo_execucoes order by em desc limit 12) e), '[]'::jsonb),
    'compactacao', jsonb_build_object(
        'proxima', (select min(to_timestamp(substring(jobname from 'compactar-(\d+)')::bigint)) from cron.job where jobname like 'compactar-%'),
        'ultima', greatest((select max(end_time) from cron.job_run_details where command like 'vacuum full public.vendas%' and status = 'succeeded'),
                           (select max(medido_em) from arquivo_execucoes))),   -- o histórico do agendador é limpo depois de 3 dias
    'config', (select jsonb_build_object('arquivarAtivo', arquivar_ativo, 'arquivarDias', arquivar_dias, 'storageLimiteMb', storage_limite_mb) from backup_config where id));
end $function$;
revoke all on function public.api_armazenamento_painel(jsonb) from public, anon;
grant execute on function public.api_armazenamento_painel(jsonb) to authenticated, service_role;

-- usados pela função "arquivar-antigos": aviso ao Admin e tamanho do banco antes do arquivamento
create or replace function public.api_push_admins_servico(p_titulo text, p_corpo text, p_tag text default 'arquivo')
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  perform _push_admins(left(coalesce(p_titulo, 'Aviso do arquivo'), 120), left(coalesce(p_corpo, ''), 400), coalesce(p_tag, 'arquivo'));
end $function$;
revoke all on function public.api_push_admins_servico(text, text, text) from public, anon, authenticated;
grant execute on function public.api_push_admins_servico(text, text, text) to service_role;

create or replace function public.api_espaco_tamanho_servico()
 returns bigint language sql stable security definer set search_path to 'public' as $function$
  select pg_database_size(current_database())
$function$;
revoke all on function public.api_espaco_tamanho_servico() from public, anon, authenticated;
grant execute on function public.api_espaco_tamanho_servico() to service_role;
