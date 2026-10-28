-- =====================================================================
-- 58 · InfinitePay como segundo provedor de pagamento online (plano, seção 10).
-- Cada forma paga pelo site (Pix, crédito) escolhe o provedor: Mercado Pago ou InfinitePay. Dá para usar os dois ao mesmo tempo.
-- A InfinitePay usa o "Checkout Integrado": o cliente vai ao site da InfinitePay pagar e volta. O aviso (webhook) da InfinitePay
-- NÃO tem assinatura, então nada é aprovado sem CONSULTAR a InfinitePay (payment_check) e conferir o valor.
-- "Simulação" (modo homologacao): link falso; Pagar / Recusar / Expirar pelos botões, sem a InfinitePay.
-- Reembolso: feito no app da InfinitePay e REGISTRADO aqui (valor, motivo, quem, quando).
-- Tudo DESLIGADO por padrão. Aditivo; pode rodar de novo sem erro.
-- ⚠️ Escrito pela documentação pública (api.checkout.infinitepay.io: /links e /payment_check), sem conta real para testar.
-- =====================================================================

-- troca de texto conferida: se o trecho não aparecer exatamente 1 vez na função ao vivo, PARA com erro (nada fica pela metade em silêncio)
create or replace function pg_temp.tb_trocar1(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception '58: trecho esperado apareceu % vez(es): %', n, left(a, 90); end if;
  return replace(d, a, b);
end $f$;

-- ---------- estrutura ----------
alter table public.integracoes_config drop constraint if exists integracoes_config_provedor_check;
alter table public.integracoes_config add constraint integracoes_config_provedor_check check (provedor = any (array['ifood', 'nfce', 'mercadopago', 'infinitepay']));
insert into public.integracoes_config (provedor, ligado, modo, checklist, config)
values ('infinitepay', false, 'homologacao', '{}'::jsonb, '{"linkValidadeMin": 30, "emailsTeste": [], "testeNoCardapio": false}'::jsonb)
on conflict (provedor) do nothing;

alter table public.formas_pagamento add column if not exists provedor_online text not null default 'mercadopago';
alter table public.formas_pagamento drop constraint if exists formas_pagamento_provedor_online_check;
alter table public.formas_pagamento add constraint formas_pagamento_provedor_online_check check (provedor_online in ('mercadopago', 'infinitepay'));

alter table public.pagamentos_online add column if not exists provedor text not null default 'mercadopago';
alter table public.pagamentos_online add column if not exists ip_link text;
alter table public.pagamentos_online add column if not exists ip_slug text;
alter table public.pagamentos_online add column if not exists ip_transacao text;
alter table public.pagamentos_online add column if not exists ip_recibo text;
alter table public.pagamentos_online add column if not exists ip_metodo_pago text;
alter table public.pagamentos_online add column if not exists ip_conferido_em timestamptz;
-- chaves guardadas: + InfiniteTag, chave do Checkout (se a conta pedir) e segredo do aviso. Mantém as que o banco já aceita.
do $$
declare v_def text; v_lista text[];
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint where conname = 'integracoes_segredos_chave_check' and conrelid = 'public.integracoes_segredos'::regclass;
  if v_def is not null and position('ip_handle' in v_def) = 0 then
    select array_agg(distinct m[1]) into v_lista from regexp_matches(v_def, '''([a-z0-9_]+)''', 'g') m;
    v_lista := v_lista || array['ip_handle', 'ip_chave_checkout', 'ip_webhook_segredo'];
    alter table public.integracoes_segredos drop constraint integracoes_segredos_chave_check;
    execute format('alter table public.integracoes_segredos add constraint integracoes_segredos_chave_check check (chave = any (%L::text[]))', v_lista);
  end if;
end $$;

create index if not exists ix_pagamentos_online_provedor on public.pagamentos_online (provedor, criado_em desc);
create unique index if not exists ux_pagamentos_online_ip_transacao on public.pagamentos_online (ip_transacao) where ip_transacao is not null;

create table if not exists public.pagamentos_reembolsos_manuais (
  id bigserial primary key,
  pagamento_id uuid not null references public.pagamentos_online(id),
  valor numeric(10,2) not null check (valor > 0),
  motivo text not null,
  registrado_por uuid,
  registrado_em timestamptz not null default now()
);
alter table public.pagamentos_reembolsos_manuais enable row level security;
revoke all on table public.pagamentos_reembolsos_manuais from public, anon, authenticated;
grant all on table public.pagamentos_reembolsos_manuais to service_role;
grant usage, select on sequence public.pagamentos_reembolsos_manuais_id_seq to service_role;

create or replace function public._pag_nome(p_prov text) returns text language sql immutable as $$
  select case when p_prov = 'infinitepay' then 'InfinitePay' else 'Mercado Pago' end
$$;

-- ---------- o que o cardápio vê: junta Mercado Pago e InfinitePay ----------
-- 1) a função antiga vira _mp_publico_mp (só as formas do Mercado Pago)
do $$
declare d text;
begin
  if to_regprocedure('public._mp_publico_mp(uuid)') is null then
    select pg_get_functiondef('public._mp_publico(uuid)'::regprocedure) into d;
    d := pg_temp.tb_trocar1(d, 'FUNCTION public._mp_publico(', 'FUNCTION public._mp_publico_mp(');
    if position('f.aceita_online and f.tipo_online is not null;' in d) = 0 then raise exception '58: ponto de troca não encontrado em _mp_publico'; end if;
    d := pg_temp.tb_trocar1(d, 'f.aceita_online and f.tipo_online is not null;', 'f.aceita_online and f.tipo_online is not null and f.provedor_online = ''mercadopago'';');
    execute d;
  end if;
end $$;
revoke all on function public._mp_publico_mp(uuid) from public, anon, authenticated;

create or replace function public._ip_publico(p_user uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
declare c integracoes_config%rowtype; v_sim boolean; v_visivel boolean; v_email text; v_formas jsonb;
begin
  select * into c from integracoes_config where provedor = 'infinitepay';
  if c.provedor is null or not c.ligado then return jsonb_build_object('ligado', false); end if;
  v_sim := c.modo <> 'producao';
  if v_sim then
    v_visivel := coalesce((c.config->>'testeNoCardapio')::boolean, false);
    if not v_visivel and p_user is not null and jsonb_typeof(c.config->'emailsTeste') = 'array' then
      select lower(email) into v_email from auth.users where id = p_user;
      v_visivel := v_email is not null and exists (select 1 from jsonb_array_elements_text(c.config->'emailsTeste') x where lower(btrim(x)) = v_email);
    end if;
    if not coalesce(v_visivel, false) then return jsonb_build_object('ligado', false); end if;
  elsif not exists (select 1 from integracoes_segredos where chave = 'ip_handle') then
    return jsonb_build_object('ligado', false);
  elsif coalesce((c.config->>'producaoSoTeste')::boolean, false) then   -- PRODUÇÃO só para os e-mails da lista (teste real de valor pequeno)
    select lower(email) into v_email from auth.users where id = p_user;
    if v_email is null or jsonb_typeof(c.config->'emailsTeste') <> 'array'
       or not exists (select 1 from jsonb_array_elements_text(c.config->'emailsTeste') x where lower(btrim(x)) = v_email) then
      return jsonb_build_object('ligado', false);
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'tipo', f.tipo_online, 'provedor', 'infinitepay') order by f.ordem), '[]'::jsonb) into v_formas
    from formas_pagamento f where f.ativa and f.visivel_cardapio and f.aceita_online and f.tipo_online in ('pix', 'credito') and f.provedor_online = 'infinitepay';
  if jsonb_array_length(v_formas) = 0 then return jsonb_build_object('ligado', false); end if;
  return jsonb_build_object('ligado', true, 'modo', case when v_sim then 'simulacao' else 'producao' end, 'formas', v_formas,
    'linkValidadeMin', case when coalesce(c.config->>'linkValidadeMin', '') ~ '^[0-9]{1,3}$' then least(120, greatest(10, (c.config->>'linkValidadeMin')::int)) else 30 end);
end $function$;
revoke all on function public._ip_publico(uuid) from public, anon, authenticated;

create or replace function public._mp_publico(p_user uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
declare mp jsonb := public._mp_publico_mp(p_user); ip jsonb := public._ip_publico(p_user); v_formas jsonb := '[]'::jsonb;
begin
  if coalesce((mp->>'ligado')::boolean, false) then
    select coalesce(jsonb_agg(x || jsonb_build_object('provedor', 'mercadopago')), '[]'::jsonb) into v_formas from jsonb_array_elements(mp->'formas') x;
  end if;
  if coalesce((ip->>'ligado')::boolean, false) then v_formas := v_formas || (ip->'formas'); end if;
  if jsonb_array_length(v_formas) = 0 then return jsonb_build_object('ok', true, 'ligado', false); end if;
  return jsonb_build_object('ok', true, 'ligado', true,
    'modo', coalesce(mp->>'modo', case when ip->>'modo' = 'producao' then 'producao' else 'teste' end),
    'publicKey', mp->>'publicKey', 'formas', v_formas, 'pixValidadeMin', coalesce((mp->>'pixValidadeMin')::int, 15),
    'infinitepay', case when coalesce((ip->>'ligado')::boolean, false) then jsonb_build_object('modo', ip->>'modo', 'linkValidadeMin', ip->'linkValidadeMin') end);
end $function$;

-- 2) o Mercado Pago recusa forma que é da InfinitePay
do $$
declare d text; a text := 'if f.id is null or not f.aceita_online or f.tipo_online is null then return _falha(''Forma de pagamento inválida.''); end if;';
begin
  select pg_get_functiondef('public.mp_preparar_pagamento(jsonb)'::regprocedure) into d;
  if position('provedor_online' in d) = 0 then
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception '58: ponto de troca não encontrado em mp_preparar_pagamento'; end if;
    d := pg_temp.tb_trocar1(d, a, a || chr(10) || '  if f.provedor_online = ''infinitepay'' then return _falha(''Esta forma é paga pela InfinitePay.''); end if;');
    execute d;
  end if;
end $$;

-- 3) textos de reembolso com o nome do provedor certo
do $$
declare d text; t text[][] := array[
  array['''Reembolsado pelo Mercado Pago''', '''Reembolsado pelo '' || _pag_nome(g.provedor)'],
  array['v_vr, ''Mercado Pago'', ''Reembolso feito no painel do Mercado Pago''', 'v_vr, _pag_nome(g.provedor), ''Reembolso feito no painel/app de '' || _pag_nome(g.provedor)'],
  array['''Devolvido direto no painel do Mercado Pago; a venda continua ativa: decida se cancela.''', '''Devolvido direto no '' || _pag_nome(g.provedor) || ''; a venda continua ativa: decida se cancela.'''],
  array['''Reembolso feito no Mercado Pago''', '''Reembolso feito no '' || _pag_nome(g.provedor)'],
  array[''' devolvido direto no painel do Mercado Pago. A venda continua ativa: veja se cancela.''', ''' devolvido direto no '' || _pag_nome(g.provedor) || ''. A venda continua ativa: veja se cancela.'''],
  array['''Reembolso parcial no Mercado Pago''', '''Reembolso parcial no '' || _pag_nome(g.provedor)'],
  array[''' devolvido direto no painel do Mercado Pago.''', ''' devolvido direto no '' || _pag_nome(g.provedor) || ''.'''],
  array['''Reembolso Mercado Pago''', '''Reembolso '' || _pag_nome(g.provedor)']]; i int;
begin
  select pg_get_functiondef('public.mp_aplicar_status(jsonb)'::regprocedure) into d;
  if position('_pag_nome' in d) = 0 then
    for i in 1 .. array_length(t, 1) loop
      if (length(d) - length(replace(d, t[i][1], ''))) / length(t[i][1]) <> 1 then raise exception '58: texto % não encontrado uma vez em mp_aplicar_status', i; end if;
      d := pg_temp.tb_trocar1(d, t[i][1], t[i][2]);
    end loop;
    execute d;
  end if;
end $$;

-- 3b) InfinitePay: sem o valor pago informado pela InfinitePay, ou valor menor, nunca aprova direto (vai para "Pagamentos que precisam de decisão")
do $$
declare d text;
begin
  select pg_get_functiondef('public.mp_aplicar_status(jsonb)'::regprocedure) into d;
  if position('g.provedor = ''infinitepay'') and v_vp <' in d) = 0 then
    d := pg_temp.tb_trocar1(d, 'if v_vp > 0 and v_vp < g.valor - 0.009 and g.venda_id is null', 'if (v_vp > 0 or g.provedor = ''infinitepay'') and v_vp < g.valor - 0.009 and g.venda_id is null');
    execute d;
  end if;
  -- texto da auditoria do pedido pago pelo site com o nome do provedor certo
  select pg_get_functiondef('public._mp_criar_venda(uuid,uuid)'::regprocedure) into d;
  if position('_pag_nome' in d) = 0 then
    d := pg_temp.tb_trocar1(d, '''Pedido pago pelo site (Mercado Pago)''', '''Pedido pago pelo site ('' || _pag_nome((select provedor from pagamentos_online where id = p_pag)) || '')''');
    execute d;
  end if;
end $$;

-- 4) testes do Mercado Pago contam só pagamentos do Mercado Pago (a simulação da InfinitePay não pode marcar o passo dele)
do $$
declare d text;
begin
  select pg_get_functiondef('public.api_mp_pagamentos_recentes(jsonb)'::regprocedure) into d;
  if position('provedor = ''mercadopago''' in d) = 0 then
    if (length(d) - length(replace(d, 'where mp_modo = ''homologacao'' and metodo', ''))) / length('where mp_modo = ''homologacao'' and metodo') <> 3 then raise exception '58: api_mp_pagamentos_recentes diferente do esperado'; end if;
    d := replace(d, 'where mp_modo = ''homologacao'' and metodo', 'where provedor = ''mercadopago'' and mp_modo = ''homologacao'' and metodo');
    d := pg_temp.tb_trocar1(d, 'from (select * from pagamentos_online order by criado_em desc limit 15) x', 'from (select * from pagamentos_online where provedor = ''mercadopago'' order by criado_em desc limit 15) x');
    execute d;
  end if;
  select pg_get_functiondef('public._integ_pendencias(text,text)'::regprocedure) into d;
  if position('infinitepay' in d) = 0 then
    if position('g.mp_modo = ''homologacao''' in d) = 0 or position('when ''chaves_producao'' then' in d) = 0 then raise exception '58: pontos de troca não encontrados em _integ_pendencias'; end if;
    d := pg_temp.tb_trocar1(d, 'g.mp_modo = ''homologacao''', 'g.provedor = ''mercadopago'' and g.mp_modo = ''homologacao''');
    d := pg_temp.tb_trocar1(d, 'when ''chaves_producao'' then',
      'when ''ip_handle'' then exists (select 1 from integracoes_segredos where chave = ''ip_handle'')
        when ''ip_segredo'' then exists (select 1 from integracoes_segredos where chave = ''ip_webhook_segredo'')
        when ''ip_formas'' then exists (select 1 from formas_pagamento where ativa and visivel_cardapio and aceita_online and tipo_online in (''pix'', ''credito'') and provedor_online = ''infinitepay'')
        when ''ip_simulacao'' then (select count(distinct status) from pagamentos_online where provedor = ''infinitepay'' and mp_modo = ''homologacao'' and status in (''aprovado'', ''recusado'', ''expirado'')) = 3
        when ''ip_real'' then (select count(distinct metodo) from pagamentos_online where provedor = ''infinitepay'' and mp_modo = ''producao'' and metodo in (''pix'', ''credito'') and status in (''aprovado'', ''reembolso_parcial'', ''reembolsado'')) = 2
        when ''chaves_producao'' then');
    d := pg_temp.tb_trocar1(d, 'if p_prov = ''mercadopago'' and p_modo = ''homologacao'' and',
      'if p_prov = ''infinitepay'' and p_modo = ''homologacao'' and (v_item->>''id'') in (''conta'', ''ip_handle'', ''ip_segredo'', ''ip_simulacao'', ''ip_real'', ''reembolso'') then continue; end if;
    if p_prov = ''infinitepay'' and p_modo = ''producao'' and (v_item->>''id'') in (''ip_real'', ''reembolso'') then continue; end if;
    if p_prov = ''mercadopago'' and p_modo = ''homologacao'' and');
    execute d;
  end if;
  select pg_get_functiondef('public._integ_checklist_def(text)'::regprocedure) into d;
  if position('infinitepay' in d) = 0 then
    d := pg_temp.tb_trocar1(d, '    else ''[]''::jsonb end', '    when ''infinitepay'' then ''[
      {"id":"conta","titulo":"Conta InfinitePay ativa, com o Checkout Integrado liberado"},
      {"id":"ip_handle","titulo":"InfiniteTag digitada aqui","auto":true},
      {"id":"ip_segredo","titulo":"Segredo do aviso gerado (botão Gerar)","auto":true},
      {"id":"ip_formas","titulo":"Pelo menos uma forma (Pix ou crédito) escolhida para pagar pela InfinitePay","auto":true},
      {"id":"ip_simulacao","titulo":"Simulação feita: um pagamento aprovado, um recusado e um expirado","auto":true},
      {"id":"ip_real","titulo":"Depois de ligar em PRODUÇÃO: teste real de valor pequeno, Pix e crédito aprovados","auto":true},
      {"id":"reembolso","titulo":"Reembolso manual testado (devolvido no app da InfinitePay e registrado aqui)"}]''::jsonb
    else ''[]''::jsonb end');
    execute d;
  end if;
end $$;

-- 5) telas de integração: InfinitePay entra nas mesmas funções (listar, ligar, desligar, ajustes, chaves)
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' and p.proname in ('api_integracoes_desligar', 'api_integracoes_config', 'api_integracoes_ligar', 'api_integracoes_marcar') loop
    d := pg_get_functiondef(r.oid);
    if position('''infinitepay''' in d) = 0 and position('''ifood'', ''nfce'', ''mercadopago''' in d) > 0 then
      d := replace(d, '''ifood'', ''nfce'', ''mercadopago''', '''ifood'', ''nfce'', ''mercadopago'', ''infinitepay''');   -- todas as vezes (a guarda acima garante pelo menos 1)
      d := replace(d, 'if v_prov in (''nfce'', ''mercadopago'') and', 'if v_prov in (''nfce'', ''mercadopago'', ''infinitepay'') and');   -- só existe em api_integracoes_ligar (conferido no fim)
      d := replace(d, '  if v_prov = ''mercadopago'' and not exists (select 1 from formas_pagamento where ativa and visivel_cardapio and aceita_online and tipo_online is not null) then',
        '  if v_prov = ''infinitepay'' and not exists (select 1 from formas_pagamento where ativa and visivel_cardapio and aceita_online and tipo_online in (''pix'', ''credito'') and provedor_online = ''infinitepay'') then
    return _falha(''Escolha pelo menos uma forma (Pix ou cartão de crédito) para pagar pela InfinitePay antes de ligar.'');
  end if;
  if v_prov = ''mercadopago'' and not exists (select 1 from formas_pagamento where ativa and visivel_cardapio and aceita_online and tipo_online is not null) then');
      execute d;
    end if;
  end loop;
  if position('provedor_online = ''infinitepay''' in pg_get_functiondef('public.api_integracoes_ligar(jsonb)'::regprocedure)) = 0
     or position('''infinitepay''' in pg_get_functiondef('public.api_integracoes_desligar(jsonb)'::regprocedure)) = 0
     or position('''infinitepay''' in pg_get_functiondef('public.api_integracoes_config(jsonb)'::regprocedure)) = 0 then
    raise exception '58: as telas de integração não ficaram preparadas para a InfinitePay';
  end if;

  select pg_get_functiondef('public.api_integracoes_status(jsonb)'::regprocedure) into d;
  if position('infinitepay' in d) = 0 then
    d := pg_temp.tb_trocar1(d, 'or (r.provedor = ''mercadopago'' and s.chave like ''mp\_%'')', 'or (r.provedor = ''mercadopago'' and s.chave like ''mp\_%'') or (r.provedor = ''infinitepay'' and s.chave like ''ip\_%'')');
    d := pg_temp.tb_trocar1(d, '''aceitaOnline'', f.aceita_online, ''tipoOnline'', f.tipo_online)', '''aceitaOnline'', f.aceita_online, ''tipoOnline'', f.tipo_online, ''provedorOnline'', f.provedor_online)');
    d := pg_temp.tb_trocar1(d, '         else ''{}''::jsonb end);', '         when r.provedor = ''infinitepay'' then (
           select jsonb_build_object(''pendenciasTeste'', to_jsonb(a.t), ''pendenciasProducao'', to_jsonb(a.p),
             ''podeLigarTeste'', coalesce(array_length(a.t, 1), 0) = 0, ''podeLigarProducao'', coalesce(array_length(a.p, 1), 0) = 0,
             ''formas'', (select coalesce(jsonb_agg(jsonb_build_object(''id'', f.id, ''nome'', f.nome, ''aceitaOnline'', f.aceita_online, ''tipoOnline'', f.tipo_online, ''provedorOnline'', f.provedor_online) order by f.ordem), ''[]''::jsonb)
                          from formas_pagamento f where f.ativa and f.visivel_cardapio))
             from (select _integ_pendencias(''infinitepay'', ''homologacao'') as t, _integ_pendencias(''infinitepay'', ''producao'') as p) a)
         else ''{}''::jsonb end);');
    if position('''infinitepay'' then (' in d) = 0 then raise exception '58: ponto de troca não encontrado em api_integracoes_status'; end if;
    execute d;
  end if;

  select pg_get_functiondef('public.api_integracoes_salvar_segredo(jsonb)'::regprocedure) into d;
  if position('ip_handle' in d) = 0 then
    d := pg_temp.tb_trocar1(d, '''mp_access_token_producao'', ''mp_webhook_secret'')', '''mp_access_token_producao'', ''mp_webhook_secret'', ''ip_handle'', ''ip_chave_checkout'')');
    d := pg_temp.tb_trocar1(d, 'if length(v_valor) < 8 or', 'if v_chave = ''ip_handle'' then v_valor := lower(regexp_replace(v_valor, ''^[$@]+'', '''')); end if;
  if length(v_valor) < (case when v_chave = ''ip_handle'' then 3 else 8 end) or');
    if position('ip_handle' in d) = 0 then raise exception '58: ponto de troca não encontrado em api_integracoes_salvar_segredo'; end if;
    execute d;
  end if;
end $$;

-- pendências de decisão mostram o provedor (o reembolso da InfinitePay é registrado à mão)
do $$
declare d text;
begin
  select pg_get_functiondef('public.api_mp_pendencias_decisao(jsonb)'::regprocedure) into d;
  if position('''provedor'', x.provedor' in d) = 0 then
    d := pg_temp.tb_trocar1(d, '''pagamentoId'', x.id,', '''pagamentoId'', x.id, ''provedor'', x.provedor,');
    execute d;
  end if;
end $$;

-- ---------- forma × provedor (Admin) ----------
create or replace function public.api_pag_forma_provedor(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare f formas_pagamento%rowtype; v_prov text := lower(coalesce(p->>'provedor', ''));
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'senha', '') = '' or _exige_admin(p->>'senha') is null then return _falha('Senha de administrador incorreta. Nada foi mudado.'); end if;
  if v_prov not in ('mercadopago', 'infinitepay') then return _falha('Provedor inválido.'); end if;
  select * into f from formas_pagamento where id = _uuid(p->>'formaId');
  if not found then return _falha('Forma de pagamento não encontrada.'); end if;
  if v_prov = 'infinitepay' and (coalesce(f.tipo_online, '') = 'debito' or (f.tipo_online is null and translate(lower(f.nome), 'áàâãéêíóôõúç', 'aaaaeeiooouc') ~ 'debito')) then return _falha('A InfinitePay não faz débito pelo Checkout Integrado. Use o Mercado Pago ou "Só na entrega".'); end if;
  update formas_pagamento set provedor_online = v_prov where id = f.id;
  perform _auditar('Pagamento online: provedor da forma', f.nome || ' → ' || _pag_nome(v_prov), null);
  return api_integracoes_status('{}') || jsonb_build_object('message', f.nome || ': ' || _pag_nome(v_prov) || '.');
end $function$;
revoke all on function public.api_pag_forma_provedor(jsonb) from public, anon;
grant execute on function public.api_pag_forma_provedor(jsonb) to authenticated, service_role;

-- ---------- InfinitePay: preparar, credenciais, link, retorno ----------
create or replace function public.ip_credenciais() returns jsonb
 language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object('ligado', c.ligado, 'modo', c.modo, 'config', c.config,
    'handle', (select valor from integracoes_segredos where chave = 'ip_handle'),
    'chave', (select valor from integracoes_segredos where chave = 'ip_chave_checkout'),
    'webhookSegredo', (select valor from integracoes_segredos where chave = 'ip_webhook_segredo'))
  from integracoes_config c where c.provedor = 'infinitepay'
$function$;
revoke all on function public.ip_credenciais() from public, anon, authenticated;
grant execute on function public.ip_credenciais() to service_role;

create or replace function public.ip_preparar_pagamento(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare r pedidos_reserva%rowtype; f formas_pagamento%rowtype; g pagamentos_online%rowtype; c integracoes_config%rowtype; v_novo uuid; v_email text; v_min int; v_ip jsonb;
begin
  select * into r from pedidos_reserva where id = _uuid(p->>'reservaId') for update;
  if not found or r.user_id is distinct from _uuid(p->>'userId') then return _falha('Pedido não encontrado.'); end if;
  if r.estado = 'confirmada' then return _falha('Este pedido já foi pago.'); end if;
  if r.estado <> 'ativa' or r.expira_em < now() then return _falha('O tempo deste pedido acabou. Faça o pedido de novo.'); end if;
  v_ip := public._ip_publico(r.user_id);
  if coalesce((v_ip->>'ligado')::boolean, false) is not true then return _falha('O pagamento pela InfinitePay não está disponível agora.'); end if;
  select * into f from formas_pagamento where id = r.forma_pagamento_id;
  if f.id is null or not f.aceita_online or f.tipo_online not in ('pix', 'credito') or f.provedor_online <> 'infinitepay' then return _falha('Forma de pagamento inválida.'); end if;
  if exists (select 1 from pagamentos_online where reserva_id = r.id and status = 'aprovado') then return _falha('Este pedido já foi pago.'); end if;
  if (select count(*) from pagamentos_online where reserva_id = r.id) >= 5 then return _falha('Muitas tentativas de pagamento. Faça o pedido de novo.'); end if;
  select * into c from integracoes_config where provedor = 'infinitepay';
  -- link ainda valendo para esta reserva: reaproveita (o cliente pode ter fechado a aba e voltado)
  select * into g from pagamentos_online where reserva_id = r.id and provedor = 'infinitepay' and status = 'aguardando' order by criado_em desc limit 1;
  if found and (g.ip_link is not null or c.modo <> 'producao') then
    return jsonb_build_object('ok', true, 'reaproveitar', true, 'pagamentoId', g.id, 'metodo', g.metodo, 'valor', g.valor, 'link', g.ip_link,
      'simulacao', g.mp_modo <> 'producao', 'expiraEm', r.expira_em);
  end if;
  update pagamentos_online set status = 'cancelado', status_detalhe = 'substituído por nova tentativa', atualizado_em = now() where reserva_id = r.id and status = 'aguardando';
  -- o link vale o tempo da InfinitePay (ajuste "Validade do link"): a reserva acompanha
  v_min := coalesce((v_ip->>'linkValidadeMin')::int, 30);
  update pedidos_reserva set expira_em = greatest(expira_em, now() + make_interval(mins => v_min)), atualizado_em = now() where id = r.id returning * into r;
  insert into pagamentos_online (reserva_id, user_id, metodo, mp_modo, valor, provedor)
  values (r.id, r.user_id, f.tipo_online, case when c.modo = 'producao' then 'producao' else 'homologacao' end, r.valor_total, 'infinitepay') returning id into v_novo;
  select email into v_email from auth.users where id = r.user_id;
  return jsonb_build_object('ok', true, 'pagamentoId', v_novo, 'metodo', f.tipo_online, 'simulacao', c.modo <> 'producao', 'valor', r.valor_total, 'expiraEm', r.expira_em,
    'email', v_email, 'nome', r.cliente_nome, 'telefone', r.telefone,
    'quantidade', (select coalesce(sum(_num(e->>'quantidade', 1)), 1) from jsonb_array_elements(r.itens) e));
end $function$;
revoke all on function public.ip_preparar_pagamento(jsonb) from public, anon, authenticated;
grant execute on function public.ip_preparar_pagamento(jsonb) to service_role;

-- guarda o link criado e, na volta do checkout / no aviso, os dados da transação (para a consulta payment_check)
create or replace function public.ip_registrar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare g pagamentos_online%rowtype; v_tr text;
begin
  select * into g from pagamentos_online where id = _uuid(p->>'pagamentoId') and provedor = 'infinitepay' for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Pagamento não encontrado.'); end if;
  v_tr := nullif(left(regexp_replace(coalesce(p->>'transacao', ''), '[^A-Za-z0-9_-]', '', 'g'), 80), '');
  if v_tr is not null and exists (select 1 from pagamentos_online where ip_transacao = v_tr and id <> g.id) then
    perform _integ_log('infinitepay', 'erro', 'Transação ' || v_tr || ' já usada em outro pagamento: ignorada no pagamento ' || left(g.id::text, 8));
    return jsonb_build_object('ok', false, 'message', 'Transação já usada em outro pagamento.');
  end if;
  update pagamentos_online set
    ip_link = coalesce(nullif(left(p->>'link', 500), ''), ip_link),
    ip_slug = coalesce(nullif(left(regexp_replace(coalesce(p->>'slug', ''), '[^A-Za-z0-9_-]', '', 'g'), 80), ''), ip_slug),
    ip_transacao = coalesce(v_tr, ip_transacao),
    ip_recibo = coalesce(case when p->>'recibo' ~ '^https://' then left(p->>'recibo', 500) end, ip_recibo),
    ip_metodo_pago = coalesce(nullif(left(p->>'metodoPago', 30), ''), ip_metodo_pago),
    ip_conferido_em = case when (p->>'conferido')::boolean then now() else ip_conferido_em end,
    atualizado_em = now()
   where id = g.id;
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function public.ip_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.ip_registrar(jsonb) to service_role;

create or replace function public.ip_pagamento(p_id uuid) returns jsonb
 language sql stable security definer set search_path to 'public' as $function$
  select to_jsonb(g) - 'pix_qr_base64' from pagamentos_online g where g.id = p_id and g.provedor = 'infinitepay'
$function$;
revoke all on function public.ip_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.ip_pagamento(uuid) to service_role;

-- ---------- simulação: Pagar / Recusar / Expirar (dono da reserva, só no modo SIMULAÇÃO; ou Admin) ----------
create or replace function public.api_ip_simular(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare g pagamentos_online%rowtype; c integracoes_config%rowtype; v_acao text := lower(coalesce(p->>'acao', '')); v_res jsonb; v_email text;
begin
  select * into g from pagamentos_online
   where provedor = 'infinitepay' and (id = _uuid(p->>'pagamentoId') or (reserva_id = _uuid(p->>'reservaId') and status = 'aguardando'))
   order by criado_em desc limit 1;
  if not found then return _falha('Pagamento não encontrado.'); end if;
  if g.user_id is distinct from auth.uid() and not tem_nivel('Admin') then return _negado(); end if;
  if g.mp_modo = 'producao' then return _falha('Simulação só funciona com a InfinitePay em SIMULAÇÃO.'); end if;
  select * into c from integracoes_config where provedor = 'infinitepay';
  if not coalesce(c.ligado, false) or c.modo = 'producao' then
    return _falha('A simulação da InfinitePay não está mais ligada. Este pagamento não vale; escolha outra forma.');
  end if;
  -- "Pagar" simulado cria pedido de verdade: só para quem está na lista de e-mails de teste (ou Admin), mesmo com "mostrar a todos"
  if v_acao = 'pagar' and not tem_nivel('Admin') then
    select lower(email) into v_email from auth.users where id = auth.uid();
    if v_email is null or jsonb_typeof(c.config->'emailsTeste') <> 'array'
       or not exists (select 1 from jsonb_array_elements_text(c.config->'emailsTeste') x where lower(btrim(x)) = v_email) then
      return _falha('Pagamento simulado só para os e-mails de teste cadastrados pelo restaurante. Escolha outra forma de pagamento.');
    end if;
  end if;
  if g.status <> 'aguardando' then return _falha('Este pagamento não está mais aguardando.'); end if;
  if v_acao = 'pagar' then
    perform public.ip_registrar(jsonb_build_object('pagamentoId', g.id, 'metodoPago', case when g.metodo = 'pix' then 'pix' else 'credit_card' end, 'conferido', true));
    v_res := public.mp_aplicar_status(jsonb_build_object('pagamentoId', g.id, 'status', 'aprovado', 'statusDetalhe', 'simulação: aprovado', 'valorPago', g.valor));
    -- marca a venda como TESTE (aparece na tela e na comanda)
    update vendas set observacoes_entrega = left(coalesce(nullif(observacoes_entrega, '') || ' · ', '') || 'TESTE: pago na SIMULAÇÃO da InfinitePay (nenhum dinheiro recebido)', 500)
     where id = (select venda_id from pagamentos_online where id = g.id) and coalesce(observacoes_entrega, '') not like '%SIMULAÇÃO da InfinitePay%';
  elsif v_acao = 'recusar' then
    v_res := public.mp_aplicar_status(jsonb_build_object('pagamentoId', g.id, 'status', 'recusado', 'statusDetalhe', 'simulação: recusado'));
  elsif v_acao = 'expirar' then
    v_res := public.mp_aplicar_status(jsonb_build_object('pagamentoId', g.id, 'status', 'expirado', 'statusDetalhe', 'simulação: link vencido'));
    if exists (select 1 from pedidos_reserva where id = g.reserva_id and estado = 'ativa') then perform _mp_soltar(g.reserva_id, 'expirada', 'Link de pagamento vencido (simulação)'); end if;
  else return _falha('Ação inválida.'); end if;
  perform _integ_log('infinitepay', 'info', 'Simulação: ' || v_acao || ' · pagamento ' || left(g.id::text, 8));
  return jsonb_build_object('ok', true, 'resultado', v_res);
end $function$;
revoke all on function public.api_ip_simular(jsonb) from public, anon;
grant execute on function public.api_ip_simular(jsonb) to authenticated, service_role;

-- ---------- reembolso manual (feito no app da InfinitePay) ----------
create or replace function public.api_ip_reembolso(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare g pagamentos_online%rowtype; v_uid text; v_val numeric := round(_num(p->>'valor', 0), 2); v_motivo text := btrim(coalesce(p->>'motivo', '')); v_total numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_uid := _exige_admin(p->>'senha');
  if coalesce(p->>'senha', '') = '' or v_uid is null then return _falha('Senha de administrador incorreta.'); end if;
  select * into g from pagamentos_online where id = _uuid(p->>'pagamentoId') and provedor = 'infinitepay' for update;
  if not found then return _falha('Pagamento da InfinitePay não encontrado.'); end if;
  if g.status not in ('aprovado', 'reembolso_parcial') then return _falha('Só dá para registrar reembolso de pagamento aprovado.'); end if;
  if v_val <= 0 then return _falha('Informe o valor devolvido.'); end if;
  if length(v_motivo) < 3 then return _falha('Escreva o motivo do reembolso.'); end if;
  v_total := round(coalesce(g.valor_reembolsado, 0) + v_val, 2);
  if v_total > g.valor + 0.009 then return _falha('O total devolvido (R$ ' || _dinheiro(v_total) || ') passaria do valor pago (R$ ' || _dinheiro(g.valor) || ').'); end if;
  insert into pagamentos_reembolsos_manuais (pagamento_id, valor, motivo, registrado_por) values (g.id, v_val, left(v_motivo, 300), auth.uid());
  perform public.mp_aplicar_status(jsonb_build_object('pagamentoId', g.id, 'status', case when v_total >= g.valor - 0.009 then 'reembolsado' else 'reembolso_parcial' end, 'valorReembolsado', v_total));
  perform _auditar('InfinitePay: reembolso registrado', 'Pagamento ' || left(g.id::text, 8) || ' · R$ ' || _dinheiro(v_val) || ' (total devolvido R$ ' || _dinheiro(v_total) || ') · ' || left(v_motivo, 120), null);
  if g.mp_modo = 'producao' then
    update integracoes_config set checklist = coalesce(checklist, '{}'::jsonb) || '{"reembolso": true}'::jsonb where provedor = 'infinitepay';
  end if;
  return jsonb_build_object('ok', true, 'message', 'Reembolso registrado: R$ ' || _dinheiro(v_val) || '.');
end $function$;
revoke all on function public.api_ip_reembolso(jsonb) from public, anon;
grant execute on function public.api_ip_reembolso(jsonb) to authenticated, service_role;

-- segredo do aviso (vai no endereço do aviso de cada cobrança). Gerado pelo sistema; trocar invalida os avisos de links antigos.
create or replace function public.api_ip_gerar_segredo(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_uid text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_uid := _exige_admin(p->>'senha');
  if coalesce(p->>'senha', '') = '' or v_uid is null then return _falha('Senha de administrador incorreta.'); end if;
  insert into integracoes_segredos (chave, valor, atualizado_em) values ('ip_webhook_segredo', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform _auditar('InfinitePay: segredo do aviso gerado', '', null);
  return api_integracoes_status('{}') || jsonb_build_object('message', 'Segredo do aviso gerado.');
end $function$;
revoke all on function public.api_ip_gerar_segredo(jsonb) from public, anon;
grant execute on function public.api_ip_gerar_segredo(jsonb) to authenticated, service_role;

-- lista do cartão da InfinitePay (teste guiado e reembolsos)
create or replace function public.api_ip_pagamentos(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'em', to_char(x.criado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'modo', x.mp_modo, 'metodo', x.metodo,
                'pagoCom', x.ip_metodo_pago, 'status', x.status, 'valor', x.valor, 'reembolsado', coalesce(x.valor_reembolsado, 0), 'recibo', x.ip_recibo,
                'aDecidir', (x.decisao_pendente and x.decisao is null), 'detalhe', left(coalesce(nullif(x.erro, ''), x.status_detalhe, ''), 120),
                'reembolsos', (select coalesce(jsonb_agg(jsonb_build_object('valor', m.valor, 'motivo', m.motivo, 'em', to_char(m.registrado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                                 'por', (select login from usuarios u where u.id = m.registrado_por)) order by m.id), '[]'::jsonb) from pagamentos_reembolsos_manuais m where m.pagamento_id = x.id)) order by x.criado_em desc), '[]'::jsonb)
              from (select * from pagamentos_online where provedor = 'infinitepay' order by criado_em desc limit 20) x),
    'simAprovado', exists (select 1 from pagamentos_online where provedor = 'infinitepay' and mp_modo = 'homologacao' and status in ('aprovado', 'reembolso_parcial', 'reembolsado')),
    'simRecusado', exists (select 1 from pagamentos_online where provedor = 'infinitepay' and mp_modo = 'homologacao' and status = 'recusado'),
    'simExpirado', exists (select 1 from pagamentos_online where provedor = 'infinitepay' and mp_modo = 'homologacao' and status = 'expirado'),
    'realPix', exists (select 1 from pagamentos_online where provedor = 'infinitepay' and mp_modo = 'producao' and metodo = 'pix' and status in ('aprovado', 'reembolso_parcial', 'reembolsado')),
    'realCredito', exists (select 1 from pagamentos_online where provedor = 'infinitepay' and mp_modo = 'producao' and metodo = 'credito' and status in ('aprovado', 'reembolso_parcial', 'reembolsado')));
end $function$;
revoke all on function public.api_ip_pagamentos(jsonb) from public, anon;
grant execute on function public.api_ip_pagamentos(jsonb) to authenticated, service_role;

-- ajustes do cartão da InfinitePay (validade do link, e-mails da simulação, mostrar a todos) e o sinal "ligada" para o app
do $$
declare d text;
begin
  select pg_get_functiondef('public.api_integracoes_config(jsonb)'::regprocedure) into d;
  if position('linkValidadeMin' in d) = 0 then
    if position('elsif v_prov = ''mercadopago'' and v_chave = ''testeNoCardapio'' then' in d) = 0 then raise exception '58: ponto de troca não encontrado em api_integracoes_config'; end if;
    d := pg_temp.tb_trocar1(d, 'elsif v_prov = ''mercadopago'' and v_chave = ''testeNoCardapio'' then',
      'elsif v_prov = ''infinitepay'' and v_chave = ''linkValidadeMin'' then
      if coalesce(v_cfg->>v_chave, '''') !~ ''^[0-9]{1,3}$'' or (v_cfg->>v_chave)::int not between 10 and 120 then return _falha(''A validade do link deve ficar entre 10 e 120 minutos.''); end if;
      v_novo := v_novo || jsonb_build_object(v_chave, (v_cfg->>v_chave)::int);
    elsif v_prov = ''infinitepay'' and v_chave = ''producaoSoTeste'' then v_novo := v_novo || jsonb_build_object(v_chave, coalesce((v_cfg->>v_chave)::boolean, false));
    elsif v_prov in (''mercadopago'', ''infinitepay'') and v_chave = ''testeNoCardapio'' then');
    d := pg_temp.tb_trocar1(d, 'elsif v_prov = ''mercadopago'' and v_chave = ''emailsTeste''', 'elsif v_prov in (''mercadopago'', ''infinitepay'') and v_chave = ''emailsTeste''');
    execute d;
  end if;
  select pg_get_functiondef('public.api_integracoes_flags(jsonb)'::regprocedure) into d;
  if position('infinitepay' in d) = 0 then
    d := pg_temp.tb_trocar1(d, '''mercadopago'', _integracao_ligada(''mercadopago''),', '''mercadopago'', _integracao_ligada(''mercadopago''), ''infinitepay'', _integracao_ligada(''infinitepay''),');
    execute d;
  end if;
end $$;


-- ---------- conferência de pagamentos que ficaram sem resposta (o cliente pagou e fechou a página, o aviso não chegou) ----------
-- A cada 10 minutos a função ip-status (modo serviço) consulta na InfinitePay os pagamentos das últimas 48 h que têm os dados da transação.
-- Pago depois de a reserva vencer entra pela mesma porta de sempre: vira "Pagamento que precisa de decisão".
create or replace function public.ip_pendentes_conferir() returns jsonb
 language sql stable security definer set search_path to 'public' as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'slug', g.ip_slug, 'transacao', g.ip_transacao, 'valor', g.valor) order by g.criado_em), '[]'::jsonb)
  from (select * from pagamentos_online
         where provedor = 'infinitepay' and mp_modo = 'producao' and status in ('aguardando', 'expirado', 'cancelado')
           and ip_slug is not null and ip_transacao is not null and criado_em > now() - interval '48 hours'
           and (ip_conferido_em is null or ip_conferido_em < now() - interval '9 minutes')
         order by criado_em limit 20) g
$function$;
revoke all on function public.ip_pendentes_conferir() from public, anon, authenticated;
grant execute on function public.ip_pendentes_conferir() to service_role;
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'ip-conferir-pendentes') then
    perform cron.schedule('ip-conferir-pendentes', '*/10 * * * *',
      $c$ select public.chamar_edge('ip-status', '{"servico":true}'::jsonb) where exists (select 1 from public.integracoes_config where provedor = 'infinitepay' and ligado and modo = 'producao'); $c$);
  end if;
end $$;
