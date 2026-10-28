-- 61 · Senha SEMPRE (inclusive do Admin) nas ações sensíveis + conferência de espaço antes da compactação das 05:30.
-- Versão 1.15 (25/10/2026). Pode rodar de novo sem erro (cada troca confere se já foi feita).
-- Se uma função ao vivo estiver diferente do esperado, o arquivo PARA com erro e nada fica pela metade.
--
-- 1) Funções antigas aceitavam a ação do Admin SEM senha quando a tela não mandava senha (o _exige_admin deixa o Admin passar
--    com senha vazia). Agora a senha vazia é recusada nelas; a tela sempre pede a senha (combinado de 20/10/2026).
-- 2) Exclusões e cancelamentos que não conferiam senha no banco passam a conferir (a tela também passa a pedir).
-- 3) A compactação (VACUUM FULL) precisa de espaço livre do tamanho da tabela enquanto roda: agora só entram na compactação
--    as tabelas que cabem no espaço livre; as outras ficam de fora (a limpeza automática do banco continua) e o Admin é avisado.

create or replace function pg_temp.tb_trocar1(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception '61: trecho esperado apareceu % vez(es): %', n, left(a, 90); end if;
  return replace(d, a, b);
end $f$;

-- ---------- ajuda: senha obrigatória (vazia = recusa; errada = recusa; o _exige_admin conta as tentativas) ----------
create or replace function public._exige_senha_sempre(p_senha text) returns text
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if coalesce(btrim(p_senha), '') = '' then return null; end if;
  return _exige_admin(p_senha);
end $function$;
revoke all on function public._exige_senha_sempre(text) from public, anon, authenticated;

-- ---------- 1) funções que deixavam o Admin passar com senha vazia ----------
do $do$
declare f text; d text;
  marca constant text := '/*61:senha-sempre*/';
  antes constant text := 'v_aut := _exige_admin(p->>''senhaAdminConfirmacao'');';
  depois constant text := marca || ' if coalesce(btrim(p->>''senhaAdminConfirmacao''), '''') = '''' then return _falha(''Digite a sua senha para confirmar (a senha é pedida sempre, inclusive para o Admin).''); end if;
  v_aut := _exige_admin(p->>''senhaAdminConfirmacao'');';
begin
  foreach f in array array['_editar_venda_base', 'api_cancelar_ajuste_pos_venda', 'api_cancelar_despesa', 'api_cancelar_movimento_evento',
                           'api_cancelar_pagamento_funcionario', 'api_cancelar_venda', 'api_estornar_compra', 'api_excluir_cliente',
                           'api_iniciar_venda', 'api_registrar_ajuste_pos_venda'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f and pg_get_function_identity_arguments(p.oid) = 'p jsonb';
    if d is null then raise exception '61: função % não encontrada', f; end if;
    if position(marca in d) > 0 then continue; end if;          -- já aplicado
    execute pg_temp.tb_trocar1(d, antes, depois);
  end loop;
end $do$;

-- ---------- 2) exclusões/cancelamentos que não conferiam a senha no banco ----------
do $do$
declare f text; d text; pos int;
  marca constant text := '/*61:senha-sempre*/';
  ins constant text := E'\n  ' || marca || ' if coalesce(btrim(p->>''senhaAdminConfirmacao''), '''') = '''' then return _falha(''Digite a sua senha para confirmar (a senha é pedida sempre, inclusive para o Admin).''); end if;'
                    || E'\n  if _exige_admin(p->>''senhaAdminConfirmacao'') is null then return _falha(''Senha de administrador incorreta. Nada foi mudado.''); end if;';
begin
  foreach f in array array['api_cancelar_compra', 'api_cancelar_evento', 'api_excluir_adicional', 'api_excluir_categoria', 'api_excluir_combo',
                           'api_excluir_ingrediente', 'api_excluir_mesa', 'api_excluir_produto', 'api_fiscal_perfil_excluir',
                           'api_ifood_cat_excluir', 'api_ifood_precos_desfazer', 'api_ponto_rosto_apagar'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
     where n.nspname = 'public' and p.proname = f and pg_get_function_identity_arguments(p.oid) = 'p jsonb' and l.lanname = 'plpgsql';
    if d is null then raise exception '61: função % não encontrada (ou não é plpgsql)', f; end if;
    if position(marca in d) > 0 then continue; end if;
    -- primeiro "begin" do corpo (logo depois do declare)
    pos := position(E'\nbegin' in lower(substr(d, position('$function$' in d))));
    if pos = 0 then raise exception '61: % sem "begin" no início de linha', f; end if;
    pos := position('$function$' in d) - 1 + pos + length(E'\nbegin');
    execute substr(d, 1, pos - 1) || ins || substr(d, pos);
  end loop;
end $do$;

-- ---------- 3) compactação: só o que cabe no espaço livre ----------
alter table public.backup_config add column if not exists compactacao_aviso text;
alter table public.backup_config add column if not exists compactacao_aviso_em timestamptz;

create or replace function public._compactar_agendar()
 returns void language plpgsql security definer set search_path to 'public', 'cron' as $function$
declare r record; v_pendente boolean := false; v_quando timestamptz; v_base timestamp;
  v_livre numeric; v_cabe text[] := '{}'; v_fora text[] := '{}'; v_t text; v_tam numeric;
  v_tabelas constant text[] := array['vendas', 'itens_venda', 'pagamentos_venda', 'caixa_sessoes', 'sangrias', 'vendas_resumo_arquivo', 'arquivo_historico'];
begin
  for r in select jobname from cron.job where jobname like 'compactar-%' loop
    if coalesce(nullif(substring(r.jobname from 'compactar-(\d+)'), '')::bigint, 0) < extract(epoch from now() - interval '15 minutes') then
      perform cron.unschedule(r.jobname);                        -- já rodou (ou ficou para trás): sai da lista
    else v_pendente := true; end if;
  end loop;
  if v_pendente then return; end if;
  -- espaço livre = limite do plano − tamanho atual do banco. A compactação refaz UMA tabela de cada vez:
  -- precisa de espaço livre do tamanho dela (com folga de 20%). Tabela maior que isso fica de fora desta vez.
  v_livre := _limite_banco_mb() * 1048576 - pg_database_size(current_database());
  foreach v_t in array v_tabelas loop
    if to_regclass('public.' || v_t) is null then continue; end if;
    v_tam := pg_total_relation_size(('public.' || v_t)::regclass);
    if v_tam * 1.2 < v_livre then v_cabe := v_cabe || ('public.' || v_t);
    else v_fora := v_fora || (v_t || ' (' || round(v_tam / 1048576.0, 1) || ' MB)'); end if;
  end loop;
  if cardinality(v_fora) > 0 then
    update backup_config set compactacao_aviso = 'Espaço livre (' || round(greatest(v_livre, 0) / 1048576.0, 1) || ' MB) não dá para compactar: '
        || array_to_string(v_fora, ', ') || '. Essas ficam de fora (a limpeza automática do banco continua). Para liberar: arquive mais pedidos antigos '
        || '(Armazenamento) ou aumente o plano do Supabase.', compactacao_aviso_em = now() where id;
    begin
      perform api_push_admins_servico('⚠️ Compactação incompleta', 'Falta espaço livre para compactar ' || array_to_string(v_fora, ', ') || '. Veja Sistema → Armazenamento.', 'compactacao');
    exception when others then null; end;
  else
    update backup_config set compactacao_aviso = null, compactacao_aviso_em = now() where id;
  end if;
  if cardinality(v_cabe) = 0 then return; end if;              -- nada cabe: não agenda (o aviso já ficou na tela)
  -- próxima 05:30 em Brasília (= 08:30 UTC)
  v_base := date_trunc('day', now() at time zone 'UTC') + interval '8 hours 30 minutes';
  v_quando := (v_base at time zone 'UTC');
  if v_quando <= now() + interval '2 minutes' then v_quando := v_quando + interval '1 day'; end if;
  perform cron.schedule('compactar-' || floor(extract(epoch from v_quando))::bigint,
    extract(minute from v_quando at time zone 'UTC')::int || ' ' || extract(hour from v_quando at time zone 'UTC')::int || ' ' ||
    extract(day from v_quando at time zone 'UTC')::int || ' ' || extract(month from v_quando at time zone 'UTC')::int || ' *',
    'vacuum full ' || array_to_string(v_cabe, ', '));
end $function$;
revoke all on function public._compactar_agendar() from public, anon, authenticated;

-- painel do Armazenamento: mostra o aviso e reconhece a compactação parcial como "feita"
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.api_armazenamento_painel(jsonb)'::regprocedure);
  if position('compactacaoAviso' in d) > 0 then return; end if;
  d := pg_temp.tb_trocar1(d, 'command like ''vacuum full public.vendas%''', 'command like ''vacuum full public.%''');
  d := pg_temp.tb_trocar1(d, '(select max(medido_em) from arquivo_execucoes))),',
     '(select max(medido_em) from arquivo_execucoes)),
        ''aviso'', (select compactacao_aviso from backup_config where id), ''avisoEm'', (select compactacao_aviso_em from backup_config where id), ''compactacaoAviso'', true),');
  execute d;
end $do$;
