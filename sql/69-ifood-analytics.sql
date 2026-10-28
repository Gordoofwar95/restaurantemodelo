-- 69 · iFood Analytics (v1.20) — indicadores D-1 (dia anterior) do módulo Analytics (API de KPIs). Pode rodar de novo sem erro.
-- O módulo Analytics exige um SEGUNDO aplicativo no Portal do Desenvolvedor (categoria BI, "por merchant") com Client ID e Secret PRÓPRIOS.
-- Esses dois valores são digitados em Integrações › iFood (campos "BI"), com a senha do Admin. O servidor busca os números, guarda aqui e a tela só lê.

-- 1) campos novos permitidos (Client ID / Secret do app BI)
alter table public.integracoes_segredos drop constraint if exists integracoes_segredos_chave_check;
alter table public.integracoes_segredos add constraint integracoes_segredos_chave_check check (chave = any (array['ifood_client_id','ifood_client_secret','ifood_merchant_id','ifood_bi_client_id','ifood_bi_client_secret','mp_access_token_producao','mp_access_token_teste','mp_public_key_producao','mp_public_key_teste','mp_webhook_secret','nfce_csc','nfce_token_homologacao','nfce_token_producao','ip_handle','ip_chave_checkout','ip_webhook_segredo']));

do $d$
declare d text;
begin
  d := pg_get_functiondef('public.api_integracoes_salvar_segredo(jsonb)'::regprocedure);
  if position('ifood_bi_client_id' in d) = 0 then
    d := replace(d, '''ifood_merchant_id'',', '''ifood_merchant_id'', ''ifood_bi_client_id'', ''ifood_bi_client_secret'',');
    execute d;
  end if;
  d := pg_get_functiondef('public.api_integracoes_config(jsonb)'::regprocedure);
  if position('biHomologacao' in d) = 0 then
    d := replace(d, '''modoHomologacao'',', '''modoHomologacao'', ''biHomologacao'',');
    execute d;
  end if;
end $d$;

-- 2) nova ação da fila
alter table public.ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table public.ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar','negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler','catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','catalogo_modelo_enviar','catalogo_lote_preco','catalogo_lote_status','catalogo_opcao_preco','catalogo_opcao_status','catalogo_diagnostico','avaliacao_responder','motivos','codigo_coleta','codigo_entrega','ship_cotar','ship_chamar','ship_cancelar','ship_motivos','ship_endereco','ship_safe','analytics_buscar']));

-- 3) token do app BI e resultados guardados
create table if not exists public.ifood_bi_token (
  id boolean primary key default true check (id),
  token text, expira_em timestamptz
);
insert into public.ifood_bi_token (id) values (true) on conflict do nothing;
alter table public.ifood_bi_token enable row level security;
revoke all on public.ifood_bi_token from anon, authenticated;

create table if not exists public.ifood_bi_dados (
  chave text primary key,
  de date not null, ate date not null,
  dados jsonb, erro text, buscando_desde timestamptz, buscado_em timestamptz,
  atualizado_em timestamptz not null default now()
);
alter table public.ifood_bi_dados enable row level security;
revoke all on public.ifood_bi_dados from anon, authenticated;

-- 4) só para a Edge Function
create or replace function public.ifood_bi_credenciais() returns jsonb
 language sql stable security definer set search_path to 'public' as $f$
  select jsonb_build_object('clientId', (select valor from integracoes_segredos where chave = 'ifood_bi_client_id'),
    'clientSecret', (select valor from integracoes_segredos where chave = 'ifood_bi_client_secret'),
    'merchantId', (select valor from integracoes_segredos where chave = 'ifood_merchant_id'),
    'homologacao', coalesce((select (config->>'biHomologacao')::boolean from integracoes_config where provedor = 'ifood'), false))
$f$;
create or replace function public.ifood_bi_token_ler() returns jsonb
 language sql stable security definer set search_path to 'public' as $f$
  select jsonb_build_object('token', token, 'expiraEm', expira_em) from ifood_bi_token where id and token is not null and expira_em > now() + interval '2 minutes'
$f$;
create or replace function public.ifood_bi_token_gravar(p_token text, p_seg integer) returns void
 language sql security definer set search_path to 'public' as $f$
  update ifood_bi_token set token = p_token, expira_em = now() + make_interval(secs => greatest(p_seg, 60)) where id
$f$;
create or replace function public.ifood_bi_gravar(p_chave text, p_dados jsonb, p_erro text default null) returns void
 language sql security definer set search_path to 'public' as $f$
  update ifood_bi_dados set dados = coalesce(p_dados, dados), erro = left(p_erro, 500), buscando_desde = null,
    buscado_em = case when p_erro is null then now() else buscado_em end, atualizado_em = now() where chave = p_chave
$f$;
revoke all on function public.ifood_bi_credenciais(), public.ifood_bi_token_ler(), public.ifood_bi_token_gravar(text, integer), public.ifood_bi_gravar(text, jsonb, text) from public, anon, authenticated;
grant execute on function public.ifood_bi_credenciais(), public.ifood_bi_token_ler(), public.ifood_bi_token_gravar(text, integer), public.ifood_bi_gravar(text, jsonb, text) to service_role;

-- 5) telas (Admin)
create or replace function public.api_ifood_bi_ler(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1; v_de date; v_ate date; r ifood_bi_dados%rowtype; v_tem boolean;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_ate := coalesce(nullif(p->>'ate', '')::date, v_ontem);
  v_de := coalesce(nullif(p->>'de', '')::date, v_ate - 6);
  select count(*) = 2 into v_tem from integracoes_segredos where chave in ('ifood_bi_client_id', 'ifood_bi_client_secret');
  select * into r from ifood_bi_dados where chave = v_de::text || '|' || v_ate::text;
  return jsonb_build_object('ok', true, 'ontem', v_ontem, 'de', v_de, 'ate', v_ate, 'chavesOk', v_tem,
    'buscando', coalesce(r.buscando_desde > now() - interval '3 minutes', false), 'erro', r.erro, 'buscadoEm', r.buscado_em, 'dados', r.dados);
end $f$;

create or replace function public.api_ifood_bi_buscar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1; v_de date; v_ate date; v_ch text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  begin v_de := (p->>'de')::date; v_ate := (p->>'ate')::date; exception when others then return _falha('Datas inválidas.'); end;
  if v_de is null or v_ate is null then return _falha('Escolha a data inicial e a final.'); end if;
  if v_de > v_ate then return _falha('A data inicial não pode ser depois da final.'); end if;
  if v_ate > v_ontem then return _falha('O iFood só entrega números até ONTEM (dados D-1). Escolha a data final de ontem ou antes.'); end if;
  if v_ate - v_de > 92 then return _falha('Escolha no máximo 93 dias por vez.'); end if;
  if (select count(*) from integracoes_segredos where chave in ('ifood_bi_client_id', 'ifood_bi_client_secret')) < 2 then
    return _falha('Antes, digite o Client ID e o Client Secret do aplicativo BI (Analytics) em Integrações › iFood. Ele é um segundo aplicativo no Portal do Desenvolvedor.');
  end if;
  v_ch := v_de::text || '|' || v_ate::text;
  if exists (select 1 from ifood_bi_dados where chave = v_ch and buscando_desde > now() - interval '3 minutes') then return jsonb_build_object('ok', true, 'message', 'Já estou buscando. Aguarde alguns segundos.'); end if;
  insert into ifood_bi_dados (chave, de, ate, buscando_desde) values (v_ch, v_de, v_ate, now())
    on conflict (chave) do update set buscando_desde = now(), erro = null, atualizado_em = now();
  perform _ifood_enfileirar('LOJA', 'analytics_buscar', jsonb_build_object('chave', 'bi-' || v_ch || '-' || floor(extract(epoch from now()) / 60)::text, 'bi', v_ch, 'de', v_de, 'ate', v_ate));
  return jsonb_build_object('ok', true, 'message', 'Buscando os números no iFood. Isto leva alguns segundos.');
end $f$;
revoke all on function public.api_ifood_bi_ler(jsonb), public.api_ifood_bi_buscar(jsonb) from public, anon;
grant execute on function public.api_ifood_bi_ler(jsonb), public.api_ifood_bi_buscar(jsonb) to authenticated, service_role;
