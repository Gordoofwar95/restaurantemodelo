-- 66 · iFood Catálogo v2 (v1.17) — revisado pela documentação oficial do módulo Catalog. Pode rodar de novo sem erro.
-- 1) Nova ação "catalogo_diagnostico": pergunta ao iFood por que itens NÃO aparecem no app (unsellableItems).
-- 2) Tabela ifood_cat_diag (guarda o último diagnóstico) + funções de leitura/pedido.
-- 3) Validações ao salvar: nome ≤ 100, descrição ≤ 500, preço do item > 0, mínimo ≤ máximo, tipo do grupo, combo.

alter table public.ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table public.ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar','negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler','catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','catalogo_modelo_enviar','catalogo_lote_preco','catalogo_lote_status','catalogo_opcao_preco','catalogo_opcao_status','catalogo_diagnostico','avaliacao_responder','motivos','codigo_coleta','codigo_entrega']));

create table if not exists public.ifood_cat_diag (
  id boolean primary key default true check (id),
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
alter table public.ifood_cat_diag enable row level security;
revoke all on public.ifood_cat_diag from anon, authenticated;

create or replace function public.ifood_cat_diag_gravar(p jsonb) returns void
 language sql security definer set search_path to 'public' as $f$
  insert into ifood_cat_diag (id, dados, atualizado_em) values (true, coalesce(p, '{}'::jsonb), now())
  on conflict (id) do update set dados = excluded.dados, atualizado_em = now()
$f$;
revoke all on function public.ifood_cat_diag_gravar(jsonb) from public, anon, authenticated;
grant execute on function public.ifood_cat_diag_gravar(jsonb) to service_role;

-- texto em português para cada motivo do iFood
create or replace function public._ifood_inelegivel_txt(p_motivo text) returns text language sql immutable as $f$
  select case upper(coalesce(p_motivo, ''))
    when 'CATEGORY_PAUSED' then 'A categoria está pausada. Ative a categoria.'
    when 'ITEM_PAUSED' then 'O item está pausado. Ative o item.'
    when 'ITEM_PRICE_MISSING' then 'O item está sem preço. Informe o preço.'
    when 'OPTION_GROUP_WITHOUT_AVAILABLE_OPTIONS' then 'Um grupo obrigatório ficou sem nenhum complemento disponível. Ative ao menos um complemento do grupo.'
    when 'OPTION_PAUSED' then 'Um complemento está pausado.'
    else 'Motivo informado pelo iFood: ' || coalesce(p_motivo, '(sem motivo)') end
$f$;

create or replace function public.api_ifood_cat_diag(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare d ifood_cat_diag%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into d from ifood_cat_diag where id;
  if not found then return jsonb_build_object('ok', true, 'vazio', true); end if;
  return jsonb_build_object('ok', true, 'em', d.atualizado_em, 'itens', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', coalesce(x->>'id', x->>'itemId', x->>'externalCode'),
      'nome', coalesce(x->>'name', (select m.nome from ifood_cat_modelo m where m.id::text = coalesce(x->>'externalCode', x->>'id', x->>'itemId') limit 1), x->>'externalCode', x->>'id'),
      'motivo', coalesce(x->>'reason', x->>'unsellableReason', x->>'cause'),
      'oQueFazer', _ifood_inelegivel_txt(coalesce(x->>'reason', x->>'unsellableReason', x->>'cause'))))
    from jsonb_array_elements(case when jsonb_typeof(d.dados->'itens') = 'array' then d.dados->'itens' else '[]'::jsonb end) x), '[]'::jsonb));
end $f$;

create or replace function public.api_ifood_cat_diag_pedir(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  perform _ifood_enfileirar('LOJA', 'catalogo_diagnostico', jsonb_build_object('chave', gen_random_uuid()::text));
  return jsonb_build_object('ok', true, 'message', 'Perguntando ao iFood. Toque em "Atualizar diagnóstico" em alguns segundos.');
end $f$;
revoke all on function public.api_ifood_cat_diag(jsonb), public.api_ifood_cat_diag_pedir(jsonb) from public, anon;
grant execute on function public.api_ifood_cat_diag(jsonb), public.api_ifood_cat_diag_pedir(jsonb) to authenticated, service_role;

-- salvar com as validações do iFood (nome ≤ 100, descrição ≤ 500, preço do item > 0, mínimo ≤ máximo, tipo do grupo, combo)
create or replace function public.api_ifood_cat_salvar(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_tipo text := p->>'tipo'; v_nome text := btrim(coalesce(p->>'nome', '')); v_d jsonb := coalesce(p->'dados', '{}'::jsonb); v_old jsonb; g jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_tipo not in ('categoria','item','grupo','opcao') then return _falha('Tipo inválido.'); end if;
  if v_nome = '' then return _falha('Informe o nome.'); end if;
  if length(v_nome) > 100 then return _falha('O nome pode ter no máximo 100 letras (limite do iFood). Tem ' || length(v_nome) || '.'); end if;
  if jsonb_typeof(v_d) <> 'object' then return _falha('Dados inválidos.'); end if;
  if length(coalesce(v_d->>'descricao', '')) > 500 then return _falha('A descrição pode ter no máximo 500 letras (limite do iFood).'); end if;
  if length(coalesce(v_d->>'fotoPendente', '')) > 700000 then return _falha('Foto grande demais. Escolha outra.'); end if;
  if v_d ? 'preco' and (coalesce(nullif(v_d->>'preco', ''), '0'))::numeric < 0 then return _falha('Preço inválido.'); end if;
  if v_tipo = 'item' and (coalesce(nullif(v_d->>'preco', ''), '0'))::numeric <= 0 then return _falha('O preço do item precisa ser maior que zero (só complemento pode ser grátis).'); end if;
  if v_tipo = 'grupo' and coalesce(v_d->>'tipoGrupo', 'OFFER_UNIT') not in ('OFFER_UNIT','INGREDIENTS','SPECIFICATION','CUTLERY') then return _falha('Tipo de grupo inválido.'); end if;
  if v_tipo = 'item' then
    for g in select value from jsonb_array_elements(case when jsonb_typeof(v_d->'grupos') = 'array' then v_d->'grupos' else '[]'::jsonb end) loop
      if coalesce(nullif(g->>'min', '')::int, 0) > coalesce(nullif(g->>'max', '')::int, 1) then return _falha('Em um dos grupos o mínimo é maior que o máximo.'); end if;
    end loop;
    if coalesce(v_d->>'combo', 'false') = 'true' and jsonb_array_length(case when jsonb_typeof(v_d->'grupos') = 'array' then v_d->'grupos' else '[]'::jsonb end) = 0 then
      return _falha('Um combo precisa de ao menos um grupo de complementos (o primeiro marcado é o principal).');
    end if;
  end if;
  if v_id is null then
    insert into ifood_cat_modelo (tipo, nome, dados) values (v_tipo, v_nome, v_d) returning id into v_id;
  else
    select dados into v_old from ifood_cat_modelo where id = v_id and tipo = v_tipo;
    if not found then return _falha('Registro não encontrado.'); end if;
    v_d := coalesce(p->'dados', '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('ifoodId', v_old->'ifoodId', 'productId', v_old->'productId', 'enviado', v_old->'enviado'));
    if not (v_d ? 'foto') and v_old ? 'foto' then v_d := v_d || jsonb_build_object('foto', v_old->'foto'); end if;
    update ifood_cat_modelo set nome = v_nome, dados = v_d, estado = 'rascunho', erro = null, atualizado_em = now() where id = v_id;
  end if;
  perform _auditar('Catálogo do iFood editado', v_tipo || ': ' || v_nome);
  return api_ifood_cat('{}') || jsonb_build_object('id', v_id);
end $$;
