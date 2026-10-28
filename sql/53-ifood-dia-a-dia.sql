-- =====================================================================
-- 53 - iFood no dia a dia (P-01, P-02, P-03, P-06, P-10, P-11)
-- ---------------------------------------------------------------------
-- P-01 Fechar o caixa já fechava os entregadores, mas a entrega concluída
--      DEPOIS da meia-noite (caixa aberto à noite ou caixa vencido) ficava
--      de fora. Agora todas as entregas do caixa entram, sem corte por dia.
-- (achado) A lista de vendas da tela não trazia o "canal": o selo iFood,
--      o "entrega pelo iFood" e a contagem de pedidos externos não
--      funcionavam. Agora vem junto.
-- P-02 Código localizador do cliente do iFood (para ligar no 0800) e a
--      validade dele: gravados no pedido, na tela e na comanda.
-- P-03 Cliente do iFood vira cadastro em Clientes, pelo ID do cliente no
--      iFood (nunca pelo 0800, que é igual para todos). Retroativo.
-- P-06 Detector de pedidos devolve quais pedidos do iFood esperam aceite
--      (para a vinheta do iFood tocar só para esses).
-- P-10 "Cadastrar no sistema" um item do iFood sem produto: vira
--      pré-cadastro (rascunho inativo, fora do cardápio) já ligado.
-- P-11 Excluir de vez itens do iFood de teste (com senha) e marcar pedido
--      do iFood como teste: saem dos alertas e não voltam.
-- Tudo aditivo. Pode rodar mais de uma vez.
-- =====================================================================

-- troca exatamente 1 ocorrência de um trecho dentro do código de uma função
create or replace function pg_temp.tb_trocar(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception 'trecho encontrado % vez(es) (esperado 1): %', n, left(a, 80); end if;
  return replace(d, a, b);
end $f$;

-- ---------------------------------------------------------------------
-- Senha para ação sensível (usada aqui e nos próximos arquivos)
-- ---------------------------------------------------------------------
create or replace function public._senha_acao(p_senha text) returns text
 language plpgsql security definer set search_path to 'public' as $function$
declare v_login text; v_chave text; v_seg int;
begin
  select login into v_login from usuarios where id = auth.uid();
  v_chave := 'falhas_senha_propria_' || lower(coalesce(v_login, ''));
  if _excedeu(v_chave, 5) then
    select greatest(1, extract(epoch from (bloqueado_ate - now()))::int) into v_seg from tentativas where chave = v_chave;
    return 'Muitas tentativas erradas. Aguarde ' || ceil(coalesce(v_seg, 60) / 60.0)::int || ' min e tente de novo.';
  end if;
  if coalesce(p_senha, '') = '' or not _senha_confere(auth.uid(), p_senha) then
    perform _registrar_falha(v_chave);
    return 'Senha incorreta. Nada foi feito.';
  end if;
  perform _limpar_falhas(v_chave);
  return '';
end $function$;
revoke all on function public._senha_acao(text) from public, anon, authenticated;
grant execute on function public._senha_acao(text) to service_role;

-- ---------------------------------------------------------------------
-- P-01: fechamento automático do entregador pega o caixa inteiro
-- ---------------------------------------------------------------------
do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_fechar_caixa(jsonb)'::regprocedure);
  if position('(s.abertura at time zone ''America/Sao_Paulo'')::date as dia' in d) = 0 then
    d := pg_temp.tb_trocar(d,
      'select distinct v.entregador_id, u.login, (v.concluida_em at time zone ''America/Sao_Paulo'')::date as dia',
      'select distinct v.entregador_id, u.login, (s.abertura at time zone ''America/Sao_Paulo'')::date as dia');
    execute d;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Colunas novas
-- ---------------------------------------------------------------------
alter table public.vendas add column if not exists ifood_localizador text;
alter table public.vendas add column if not exists ifood_localizador_ate timestamptz;
alter table public.clientes add column if not exists ifood_id text;
alter table public.clientes add column if not exists origem text not null default '';
create unique index if not exists clientes_ifood_id_uq on public.clientes (ifood_id) where ifood_id is not null;
create index if not exists ix_vendas_cliente_id on public.vendas (cliente_id) where cliente_id is not null;
alter table public.produtos add column if not exists pre_cadastro boolean not null default false;
alter table public.produtos add column if not exists origem text not null default '';
alter table public.produtos add column if not exists ifood_chave text;

-- a tela passa a receber canal (iFood), cliente e o localizador (colunas novas sempre no fim)
create or replace view public.v_vendas as
 SELECT id,
    numero_pedido AS numero,
    data_hora,
    cliente_nome,
    telefone_cliente AS cliente_telefone,
    forma_pagamento,
    valor_total,
        CASE
            WHEN (auth_nivel() = ANY (ARRAY['Admin'::nivel_acesso, 'Operador'::nivel_acesso])) THEN custo_total
            ELSE NULL::numeric
        END AS custo_total,
    status,
    motivo_cancelamento,
    tipo AS tipo_entrega,
    status_pedido,
    endereco,
    complemento,
    referencia,
    observacoes_entrega,
    pronta_em,
    concluida_em,
    status_pagamento,
    recebido_em,
    valor_original,
    valor_desconto,
    desconto_detalhe,
    _login_de(entregador_id) AS entregador,
    saiu_em,
    origem,
    mesa_id,
    taxa_entrega,
    fechamento_entrega_id,
    _login_de(registrado_por) AS registrado_por,
    inicio_preparo_em,
    _mesa_numero_de(mesa_id) AS mesa_numero,
    acrescimo_forma,
    preferencias_cliente,
    canal,
    cliente_id,
    ifood_localizador,
    ifood_localizador_ate
   FROM vendas v;
grant select on public.v_vendas to authenticated;
grant all on public.v_vendas to service_role;

-- ---------------------------------------------------------------------
-- P-02 + P-03: localizador e cliente do iFood
-- ---------------------------------------------------------------------
create or replace function public._ifood_cliente(p_venda uuid, p_order jsonb) returns uuid
 language plpgsql security definer set search_path to 'public' as $function$
declare v_cid text; v_nome text; v_end text; ad jsonb; v_id uuid; v_loc text; v_ate timestamptz;
begin
  v_loc := nullif(btrim(coalesce(p_order->'customer'->'phone'->>'localizer', '')), '');
  begin v_ate := nullif(p_order->'customer'->'phone'->>'localizerExpiration', '')::timestamptz; exception when others then v_ate := null; end;
  if v_loc is not null then
    update vendas set ifood_localizador = left(regexp_replace(v_loc, '[^0-9A-Za-z]', '', 'g'), 20), ifood_localizador_ate = v_ate where id = p_venda;
  end if;
  v_cid := left(nullif(btrim(coalesce(p_order->'customer'->>'id', '')), ''), 80);
  if v_cid is null then return null; end if;
  v_nome := left(btrim(coalesce(p_order->'customer'->>'name', '')), 80);
  if v_nome = '' then v_nome := 'Cliente iFood'; end if;
  ad := coalesce(p_order->'delivery'->'deliveryAddress', '{}'::jsonb);
  v_end := left(coalesce(nullif(ad->>'formattedAddress', ''), btrim(concat_ws(', ', ad->>'streetName', ad->>'streetNumber', ad->>'neighborhood', ad->>'city'))), 300);
  select id into v_id from clientes where ifood_id = v_cid;
  if v_id is null then
    insert into clientes (nome, telefone, endereco, como_conheceu, primeiro_contato, observacoes, ifood_id, origem)
    values (v_nome, null, nullif(v_end, ''), 'iFood', now(), 'Cadastrado sozinho por pedido do iFood (sem telefone: o iFood usa 0800 + código).', v_cid, 'iFood')
    on conflict (ifood_id) where ifood_id is not null do nothing
    returning id into v_id;
    if v_id is null then select id into v_id from clientes where ifood_id = v_cid; end if;
  elsif nullif(v_end, '') is not null then
    update clientes set endereco = v_end where id = v_id and coalesce(endereco, '') <> v_end;
  end if;
  update vendas set cliente_id = v_id where id = p_venda and cliente_id is null;
  return v_id;
end $function$;
revoke all on function public._ifood_cliente(uuid, jsonb) from public, anon, authenticated;
grant execute on function public._ifood_cliente(uuid, jsonb) to service_role;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.ifood_criar_pedido(jsonb,boolean)'::regprocedure);
  if position('_ifood_cliente(v_venda' in d) = 0 then
    d := pg_temp.tb_trocar(d,
      '  returning numero_pedido into v_numero;',
      '  returning numero_pedido into v_numero;
  -- cliente do iFood (pelo ID do iFood) e código localizador; nunca impede o pedido de entrar
  if not p_simulado then
    begin perform public._ifood_cliente(v_venda, p_order);
    exception when others then perform _integ_log(''ifood'', ''aviso'', ''Pedido #'' || v_disp || '': cliente não cadastrado ('' || left(sqlerrm, 150) || '')''); end;
  end if;');
    execute d;
  end if;
end $$;

-- retroativo: pedidos do iFood que já existem
do $$
declare r record;
begin
  for r in select venda_id, bruto from ifood_pedidos where not coalesce(simulado, false) and venda_id is not null order by criado_em loop
    begin perform public._ifood_cliente(r.venda_id, r.bruto); exception when others then null; end;
  end loop;
end $$;

-- segmentos (Novo/Fiel/VIP/Em risco): cliente do iFood conta pelo cadastro dele, não pelo 0800
create or replace function public.api_clientes_segmentos(p_dias_risco integer default 45)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'diasRisco', greatest(coalesce(p_dias_risco,45),1), 'clientes', coalesce((
    with base as (
      select case when v.canal = 'iFood' then case when v.cliente_id is not null then 'ifood:' || v.cliente_id::text end
                  else _so_digitos(v.telefone_cliente) end tel, v.valor_total, v.data_hora
        from vendas v where v.status = 'Confirmada'
      union all
      select case when s.telefone like '0800%' then case when s.cliente_id is not null then 'ifood:' || s.cliente_id::text end
                  else s.telefone end, s.valor_total, s.data_hora
        from vendas_resumo_arquivo s where s.status = 'Confirmada'
    ),
    agg as (select tel, count(*)::int n, sum(valor_total) total, max(data_hora) ultimo from base
             where tel is not null and (tel like 'ifood:%' or length(tel) >= 8) group by tel)
    select jsonb_agg(jsonb_build_object(
             'telefone', a.tel, 'pedidos', a.n, 'total', a.total, 'ultimo', a.ultimo,
             'segmento', _segmento_cliente(a.n, a.total, a.ultimo, p_dias_risco),
             'temConta', a.tel not like 'ifood:%' and exists (select 1 from contas_cliente cc where cc.telefone <> '' and _so_digitos(cc.telefone) = a.tel),
             'aceitaPromocoes', a.tel not like 'ifood:%' and exists (select 1 from contas_cliente cc where cc.promo_ok and cc.telefone <> '' and _so_digitos(cc.telefone) = a.tel)))
      from agg a), '[]'::jsonb));
end $function$;

-- ---------------------------------------------------------------------
-- P-06: o detector diz quais pedidos do iFood esperam aceite
-- ---------------------------------------------------------------------
do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_detectar_novos_pedidos(jsonb)'::regprocedure);
  if position('''ifood''' in d) = 0 then
    d := pg_temp.tb_trocar(d,
      'return jsonb_build_object(''ok'', true, ''ids'', v_ids, ''recebidos'', v_rec, ''total'', jsonb_array_length(v_ids));',
      'return jsonb_build_object(''ok'', true, ''ids'', v_ids, ''recebidos'', v_rec, ''total'', jsonb_array_length(v_ids),
    ''ifood'', coalesce((select jsonb_agg(v.id::text) from (select * from vendas order by data_hora desc limit 300) v
                         where v.status = ''Confirmada'' and v.canal = ''iFood'' and v.status_pedido = ''Recebido''), ''[]''::jsonb));');
    execute d;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- P-11: itens do iFood descartados (excluídos de vez) e pedido de teste
-- ---------------------------------------------------------------------
create table if not exists public.ifood_itens_descartados (
  chave text primary key,
  nome text not null default '',
  tipo text not null default '',
  descartado_por uuid,
  descartado_em timestamptz not null default now()
);
alter table public.ifood_itens_descartados enable row level security;
revoke all on table public.ifood_itens_descartados from public, anon, authenticated;
grant all on table public.ifood_itens_descartados to service_role;

-- item descartado que voltar num pedido: não é recriado e conta como "ignorar"
create or replace function public._ifood_item_visto(p_chave text, p_nome text, p_tipo text)
 returns ifood_itens language plpgsql security definer set search_path to 'public' as $function$
declare r ifood_itens%rowtype; v_u uuid;
begin
  if exists (select 1 from ifood_itens_descartados where chave = p_chave) then
    r.chave := p_chave; r.nome := left(coalesce(nullif(p_nome, ''), p_chave), 200); r.tipo := p_tipo; r.ignorar := true;
    return r;
  end if;
  insert into ifood_itens (chave, nome, tipo) values (p_chave, left(coalesce(nullif(p_nome, ''), p_chave), 200), p_tipo)
    on conflict (chave) do update set nome = excluded.nome, visto_em = now() returning * into r;
  if r.produto_id is null and r.combo_id is null and r.adicional_id is null and not r.ignorar then
    v_u := case when p_chave ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p_chave::uuid end;
    if v_u is not null then
      if exists (select 1 from produtos where id = v_u) then update ifood_itens set produto_id = v_u, ligado_em = now() where chave = p_chave returning * into r;
      elsif exists (select 1 from combos where id = v_u) then update ifood_itens set combo_id = v_u, ligado_em = now() where chave = p_chave returning * into r;
      elsif p_tipo = 'opcao' and exists (select 1 from adicionais where id = v_u) then update ifood_itens set adicional_id = v_u, ligado_em = now() where chave = p_chave returning * into r;
      end if;
    end if;
  end if;
  return r;
end $function$;

-- recontagem dos itens sem ligação de um pedido (mesma regra de _ifood_gravar_itens, sem regravar nada)
create or replace function public._ifood_contar_sem_ligacao(p_order jsonb) returns int
 language plpgsql stable security definer set search_path to 'public' as $function$
declare it jsonb; v_chave text; v_n int := 0; i ifood_itens%rowtype;
begin
  for it in select value from jsonb_array_elements(coalesce(p_order->'items', '[]'::jsonb)) loop
    v_chave := coalesce(nullif(it->>'externalCode', ''), nullif(it->>'id', ''), 'sem-codigo-' || public._ifood_norm(it->>'name'));
    if exists (select 1 from ifood_itens_descartados where chave = v_chave) then continue; end if;
    select * into i from ifood_itens where chave = v_chave;
    if i.chave is null or (i.produto_id is null and i.combo_id is null and not coalesce(i.ignorar, false)) then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $function$;
revoke all on function public._ifood_contar_sem_ligacao(jsonb) from public, anon, authenticated;
grant execute on function public._ifood_contar_sem_ligacao(jsonb) to service_role;

-- alerta de saúde: pedido de teste não conta
do $$
declare d text;
begin
  d := pg_get_functiondef('public._saude_integracoes()'::regprocedure);
  if position('itens_sem_ligacao), 0) into v_sem from ifood_pedidos where estado <> ''cancelado'' and not coalesce(simulado, false)' in d) = 0 then
    d := pg_temp.tb_trocar(d,
      'select coalesce(sum(itens_sem_ligacao), 0) into v_sem from ifood_pedidos where estado <> ''cancelado'' and criado_em',
      'select coalesce(sum(itens_sem_ligacao), 0) into v_sem from ifood_pedidos where estado <> ''cancelado'' and not coalesce(simulado, false) and criado_em');
    execute d;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Tela "Itens do iFood": lista com pré-cadastros, descartados e categorias
-- ---------------------------------------------------------------------
create or replace function public.api_ifood_itens(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'itens', coalesce((select jsonb_agg(jsonb_build_object('chave', i.chave, 'nome', i.nome, 'tipo', i.tipo, 'ignorar', i.ignorar,
        'ligado', case when i.produto_id is not null then 'produto' when i.combo_id is not null then 'combo' when i.adicional_id is not null then 'adicional' end,
        'ligadoId', coalesce(i.produto_id, i.combo_id, i.adicional_id),
        'ligadoNome', coalesce((select nome from produtos where id = i.produto_id), (select nome from combos where id = i.combo_id), (select nome from adicionais where id = i.adicional_id)),
        'preCadastro', coalesce((select pr.pre_cadastro from produtos pr where pr.id = i.produto_id), false),
        'categoria', i.categoria, 'precoIfood', i.preco_ifood, 'vistoEm', i.visto_em,
        'sugestao', case when i.produto_id is null and i.combo_id is null and i.adicional_id is null and not i.ignorar then public._ifood_sugestao(i.nome, i.tipo) end)
        order by (i.produto_id is null and i.combo_id is null and i.adicional_id is null and not i.ignorar) desc, i.nome) from ifood_itens i), '[]'::jsonb),
    'produtos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from produtos where ativo), '[]'::jsonb),
    'combos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from combos where ativo), '[]'::jsonb),
    'adicionais', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from adicionais where ativo), '[]'::jsonb),
    'categorias', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by ordem, nome) from categorias where ativa), '[]'::jsonb),
    'descartados', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'nome', d.nome, 'tipo', d.tipo, 'em', d.descartado_em, 'por', _login_de(d.descartado_por)) order by d.descartado_em desc)
                               from (select * from ifood_itens_descartados order by descartado_em desc limit 100) d), '[]'::jsonb),
    'preCadastros', coalesce((select jsonb_agg(jsonb_build_object('id', pr.id, 'nome', pr.nome, 'semPreco', not exists (select 1 from produto_precos pp where pp.produto_id = pr.id and pp.preco > 0),
                               'semFicha', not exists (select 1 from produto_ingredientes pi where pi.produto_id = pr.id), 'semFoto', coalesce(pr.foto_id_principal, '') = '',
                               'semCategoria', pr.categoria_id is null) order by pr.nome)
                               from produtos pr where pr.pre_cadastro), '[]'::jsonb));
end $function$;

-- Excluir de vez (com senha). Item ligado não pode. Também restaura um descartado.
create or replace function public.api_ifood_itens_excluir(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_err text; v_chaves text[]; v_lig int; v_n int; v_rest text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_err := _senha_acao(p->>'senha'); if v_err <> '' then return _falha(v_err); end if;
  v_rest := nullif(p->>'restaurar', '');
  if v_rest is not null then
    delete from ifood_itens_descartados where chave = v_rest;
    perform _auditar('Item do iFood restaurado (volta a aparecer quando vier num pedido)', v_rest);
    return api_ifood_itens('{}') || jsonb_build_object('message', 'Restaurado. Ele volta para a lista quando aparecer de novo num pedido.');
  end if;
  if coalesce((p->>'todosIgnorados')::boolean, false) then
    select coalesce(array_agg(chave), '{}') into v_chaves from ifood_itens where ignorar and produto_id is null and combo_id is null and adicional_id is null;
  else
    select coalesce(array_agg(x), '{}') into v_chaves from jsonb_array_elements_text(case when jsonb_typeof(p->'chaves') = 'array' then p->'chaves' else '[]'::jsonb end) x;
  end if;
  if coalesce(array_length(v_chaves, 1), 0) = 0 then return _falha('Nenhum item escolhido para excluir.'); end if;
  select count(*) into v_lig from ifood_itens where chave = any(v_chaves) and (produto_id is not null or combo_id is not null or adicional_id is not null);
  if v_lig > 0 then return _falha('Há ' || v_lig || ' item(ns) ligado(s) a produto do sistema. Desfaça a ligação antes de excluir. Nada foi excluído.'); end if;
  insert into ifood_itens_descartados (chave, nome, tipo, descartado_por)
    select chave, coalesce(nome, ''), coalesce(tipo, ''), auth.uid() from ifood_itens where chave = any(v_chaves)
    on conflict (chave) do nothing;
  delete from ifood_itens where chave = any(v_chaves);
  get diagnostics v_n = row_count;
  update ifood_pedidos set itens_sem_ligacao = public._ifood_contar_sem_ligacao(bruto) where itens_sem_ligacao > 0;
  perform _auditar('Itens do iFood excluídos de vez', v_n || ' item(ns): ' || left(array_to_string(v_chaves, ', '), 600));
  return api_ifood_itens('{}') || jsonb_build_object('message', v_n || ' item(ns) excluído(s) de vez. Se voltarem num pedido, não aparecem nem geram alerta.');
end $function$;

-- Marcar pedido do iFood como teste (com senha): sai dos alertas e dos relatórios do iFood
create or replace function public.api_ifood_marcar_teste(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_err text; v_num text := btrim(coalesce(p->>'numero', '')); v_id text; v_venda uuid; v_teste boolean := coalesce((p->>'teste')::boolean, true);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_err := _senha_acao(p->>'senha'); if v_err <> '' then return _falha(v_err); end if;
  select pedido_ifood, venda_id into v_id, v_venda from ifood_pedidos where numero_ifood = v_num or pedido_ifood = v_num order by criado_em desc limit 1;
  if v_id is null then return _falha('Pedido do iFood não encontrado (use o número que aparece como "iFood #...").'); end if;
  update ifood_pedidos set simulado = v_teste, itens_sem_ligacao = case when v_teste then 0 else public._ifood_contar_sem_ligacao(bruto) end where pedido_ifood = v_id;
  perform _auditar(case when v_teste then 'Pedido do iFood marcado como teste' else 'Pedido do iFood desmarcado como teste' end, 'iFood #' || v_num);
  return jsonb_build_object('ok', true, 'message', case when v_teste
    then 'Pedido iFood #' || v_num || ' marcado como TESTE: saiu dos alertas e dos relatórios do iFood. A venda continua no caixa; se ela não deveria existir, cancele a venda normalmente (pede senha).'
    else 'Pedido iFood #' || v_num || ' voltou a contar normalmente.' end);
end $function$;

-- ---------------------------------------------------------------------
-- P-10: pré-cadastro de item do iFood
-- ---------------------------------------------------------------------
create or replace function public.api_ifood_pre_cadastro(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare it ifood_itens%rowtype; v_nome text; v_desc text; v_preco numeric; v_cat uuid; v_catnova text; v_id uuid; v_dup record; v_forcar boolean := coalesce((p->>'forcar')::boolean, false); v_forma uuid;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into it from ifood_itens where chave = p->>'chave';
  if it.chave is null then return _falha('Item do iFood não encontrado.'); end if;
  if it.produto_id is not null or it.combo_id is not null or it.adicional_id is not null then return _falha('Este item já está ligado a um produto do sistema.'); end if;
  v_nome := left(btrim(coalesce(nullif(p->>'nome', ''), it.nome, '')), 120);
  if v_nome = '' then return _falha('Informe o nome.'); end if;
  v_desc := left(btrim(coalesce(p->>'descricao', '')), 1000);
  v_preco := round(greatest(case when nullif(btrim(coalesce(p->>'preco', '')), '') is null then coalesce(it.preco_ifood, 0) else _num(p->>'preco') end, 0), 2);
  if it.tipo = 'opcao' then
    if not v_forcar then
      select id, nome into v_dup from adicionais where public._ifood_norm(nome) = public._ifood_norm(v_nome) limit 1;
      if v_dup.id is not null then
        return jsonb_build_object('ok', false, 'duplicado', true, 'existente', jsonb_build_object('id', v_dup.id, 'nome', v_dup.nome, 'tipo', 'adicional'),
          'message', 'Já existe um adicional com esse nome ("' || v_dup.nome || '"). Ligar a ele em vez de criar?');
      end if;
    end if;
    insert into adicionais (nome, preco, ativo) values (v_nome, v_preco, false) returning id into v_id;
    update ifood_itens set adicional_id = v_id, ignorar = false, ligado_em = now() where chave = it.chave;
    perform _auditar('Pré-cadastro do iFood (adicional)', v_nome || ' · ' || it.chave);
    return api_ifood_itens('{}') || jsonb_build_object('criadoId', v_id, 'message',
      'Adicional "' || v_nome || '" criado INATIVO e já ligado. Em Adicionais, informe o ingrediente que ele baixa e ative.');
  end if;
  if not v_forcar then
    select id, nome, 'produto' t into v_dup from produtos where public._ifood_norm(nome) = public._ifood_norm(v_nome)
    union all select id, nome, 'combo' from combos where public._ifood_norm(nome) = public._ifood_norm(v_nome) limit 1;
    if v_dup.id is not null then
      return jsonb_build_object('ok', false, 'duplicado', true, 'existente', jsonb_build_object('id', v_dup.id, 'nome', v_dup.nome, 'tipo', v_dup.t),
        'message', 'Já existe um ' || v_dup.t || ' parecido ("' || v_dup.nome || '"). Ligar a ele em vez de criar?');
    end if;
  end if;
  v_cat := case when coalesce(p->>'categoriaId', '') ~* '^[0-9a-f-]{36}$' then (p->>'categoriaId')::uuid end;
  if v_cat is not null and not exists (select 1 from categorias where id = v_cat) then v_cat := null; end if;
  v_catnova := left(btrim(coalesce(p->>'categoriaNova', '')), 60);
  if v_cat is null and v_catnova <> '' then
    select id into v_cat from categorias where lower(btrim(nome)) = lower(v_catnova) limit 1;
    if v_cat is null then insert into categorias (nome) values (v_catnova) returning id into v_cat; end if;
  end if;
  insert into produtos (nome, descricao, categoria_id, ativo, pre_cadastro, origem, ifood_chave)
  values (v_nome, nullif(v_desc, ''), v_cat, false, true, 'ifood', it.chave) returning id into v_id;
  v_forma := _ifood_forma();
  if v_forma is not null and v_preco > 0 then
    insert into produto_precos (produto_id, forma_pagamento_id, preco, custo) values (v_id, v_forma, v_preco, 0);
  end if;
  update ifood_itens set produto_id = v_id, ignorar = false, ligado_em = now() where chave = it.chave;
  perform _auditar('Pré-cadastro do iFood (produto)', v_nome || ' · ' || it.chave);
  return api_ifood_itens('{}') || jsonb_build_object('criadoId', v_id, 'message',
    '"' || v_nome || '" criado como RASCUNHO (fora do cardápio) e já ligado ao item do iFood.'
    || case when v_forma is not null and v_preco > 0 then ' Preço do iFood gravado na forma iFood.' else ' Sem preço: complete em Produtos.' end
    || ' Complete ficha técnica, preços das outras formas e foto em Produtos, e ative quando estiver pronto.');
end $function$;

-- ativou o produto: deixa de ser pré-cadastro
create or replace function public._trg_produto_pre_cadastro() returns trigger
 language plpgsql set search_path to 'public' as $function$
begin
  if new.ativo and not coalesce(old.ativo, false) and new.pre_cadastro then new.pre_cadastro := false; end if;
  return new;
end $function$;
drop trigger if exists produtos_pre_cadastro on public.produtos;
create trigger produtos_pre_cadastro before update of ativo on public.produtos for each row execute function public._trg_produto_pre_cadastro();

revoke all on function public.api_ifood_itens(jsonb), public.api_ifood_itens_excluir(jsonb), public.api_ifood_marcar_teste(jsonb), public.api_ifood_pre_cadastro(jsonb) from public, anon;
grant execute on function public.api_ifood_itens(jsonb), public.api_ifood_itens_excluir(jsonb), public.api_ifood_marcar_teste(jsonb), public.api_ifood_pre_cadastro(jsonb) to authenticated, service_role;
revoke all on function public._trg_produto_pre_cadastro() from public, anon, authenticated;
