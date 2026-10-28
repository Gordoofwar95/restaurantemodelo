-- 46: iFood Catalog — gestão do cardápio no iFood pelo sistema (categorias, itens, grupos de complementos, complementos,
-- preço/status em massa). O sistema guarda o modelo aqui e o envia ao iFood pela Edge Function ifood-sync.
create table if not exists public.ifood_cat_modelo (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('categoria','item','grupo','opcao')),
  nome text not null,
  dados jsonb not null default '{}'::jsonb,
  estado text not null default 'rascunho' check (estado in ('rascunho','pendente','enviado','erro')),
  erro text,
  atualizado_em timestamptz not null default now()
);
alter table public.ifood_cat_modelo enable row level security;
revoke all on public.ifood_cat_modelo from anon, authenticated;

alter table ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar','negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler','catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','catalogo_modelo_enviar','catalogo_lote_preco','catalogo_lote_status','catalogo_opcao_preco','catalogo_opcao_status','avaliacao_responder']));

create or replace function public.api_ifood_cat(p jsonb default '{}'::jsonb) returns jsonb
  language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'itens', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'nome', nome, 'dados', dados - 'fotoPendente' || jsonb_build_object('temFotoPendente', dados ? 'fotoPendente'), 'estado', estado, 'erro', erro, 'em', atualizado_em) order by tipo, nome) from ifood_cat_modelo where coalesce(dados->>'oculto', 'false') <> 'true'), '[]'::jsonb));
end $$;

create or replace function public.api_ifood_cat_salvar(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_tipo text := p->>'tipo'; v_nome text := left(btrim(coalesce(p->>'nome', '')), 120); v_d jsonb := coalesce(p->'dados', '{}'::jsonb); v_old jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_tipo not in ('categoria','item','grupo','opcao') then return _falha('Tipo inválido.'); end if;
  if v_nome = '' then return _falha('Informe o nome.'); end if;
  if jsonb_typeof(v_d) <> 'object' then return _falha('Dados inválidos.'); end if;
  if length(coalesce(v_d->>'fotoPendente', '')) > 700000 then return _falha('Foto grande demais. Escolha outra.'); end if;
  if v_d ? 'preco' and (coalesce(nullif(v_d->>'preco', ''), '0'))::numeric < 0 then return _falha('Preço inválido.'); end if;
  if v_id is null then
    insert into ifood_cat_modelo (tipo, nome, dados) values (v_tipo, v_nome, v_d) returning id into v_id;
  else
    select dados into v_old from ifood_cat_modelo where id = v_id and tipo = v_tipo;
    if not found then return _falha('Registro não encontrado.'); end if;
    -- campos controlados pelo servidor (ids do iFood e último estado enviado) não vêm da tela
    v_d := coalesce(p->'dados', '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('ifoodId', v_old->'ifoodId', 'productId', v_old->'productId', 'enviado', v_old->'enviado'));
    if not (v_d ? 'foto') and v_old ? 'foto' then v_d := v_d || jsonb_build_object('foto', v_old->'foto'); end if;
    update ifood_cat_modelo set nome = v_nome, dados = v_d, estado = 'rascunho', erro = null, atualizado_em = now() where id = v_id;
  end if;
  perform _auditar('Catálogo do iFood editado', v_tipo || ': ' || v_nome);
  return api_ifood_cat('{}') || jsonb_build_object('id', v_id);
end $$;

create or replace function public.api_ifood_cat_excluir(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  update ifood_cat_modelo set dados = dados || '{"oculto": true}'::jsonb, atualizado_em = now() where id = (p->>'id')::uuid;
  perform _auditar('Catálogo do iFood: registro escondido no sistema', coalesce(p->>'id', ''));
  return api_ifood_cat('{}') || jsonb_build_object('message', 'Removido da lista (no iFood nada foi apagado).');
end $$;

create or replace function public.api_ifood_cat_enviar(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := (p->>'id')::uuid; r ifood_cat_modelo%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  select * into r from ifood_cat_modelo where id = v_id;
  if not found then return _falha('Registro não encontrado.'); end if;
  if r.tipo not in ('categoria','item') then return _falha('Envie pela categoria ou pelo item: grupos e complementos vão junto com o item.'); end if;
  update ifood_cat_modelo set estado = 'pendente', erro = null where id = v_id;
  perform _ifood_enfileirar('LOJA', 'catalogo_modelo_enviar', jsonb_build_object('chave', v_id::text, 'id', v_id));
  perform _auditar('Catálogo do iFood enviado', r.tipo || ': ' || r.nome);
  return api_ifood_cat('{}') || jsonb_build_object('message', 'Enviando ao iFood. Toque em Atualizar em alguns segundos.');
end $$;

-- preço/status em massa (itens) e de complementos: p = { modo: 'preco'|'status'|'opcao_preco'|'opcao_status', itens: [{id, valor}] }
create or replace function public.api_ifood_cat_lote(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
declare v_modo text := p->>'modo'; v_l jsonb := coalesce(p->'itens', '[]'::jsonb); e jsonb; v_acao text; v_tipo text; v_n int := 0;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  if v_modo not in ('preco','status','opcao_preco','opcao_status') then return _falha('Modo inválido.'); end if;
  if jsonb_typeof(v_l) <> 'array' or jsonb_array_length(v_l) = 0 then return _falha('Escolha ao menos um item.'); end if;
  v_tipo := case when v_modo like 'opcao%' then 'opcao' else 'item' end;
  v_acao := case v_modo when 'preco' then 'catalogo_lote_preco' when 'status' then 'catalogo_lote_status' when 'opcao_preco' then 'catalogo_opcao_preco' else 'catalogo_opcao_status' end;
  for e in select value from jsonb_array_elements(v_l) loop
    if not exists (select 1 from ifood_cat_modelo where id = (e->>'id')::uuid and tipo = v_tipo and coalesce(dados->>'enviado', '') <> '') then
      return _falha('Todos precisam já ter sido enviados ao iFood.');
    end if;
    if v_modo in ('preco','opcao_preco') and (coalesce(nullif(e->>'valor', ''), '-1'))::numeric < 0 then return _falha('Preço inválido.'); end if;
    if v_modo in ('status','opcao_status') and (e->>'valor') not in ('AVAILABLE','UNAVAILABLE') then return _falha('Status inválido.'); end if;
    v_n := v_n + 1;
  end loop;
  perform _ifood_enfileirar('LOJA', v_acao, jsonb_build_object('chave', gen_random_uuid()::text, 'itens', v_l));
  perform _auditar('Catálogo do iFood em massa', v_modo || ': ' || v_n || ' item(ns)');
  return jsonb_build_object('ok', true, 'message', v_n || ' item(ns) enviados ao iFood em uma chamada. Toque em Atualizar em alguns segundos.');
end $$;

-- usadas só pela Edge Function (service_role)
create or replace function public.ifood_cat_arvore(p_id uuid) returns jsonb
  language plpgsql stable security definer set search_path to 'public' as $$
declare r ifood_cat_modelo%rowtype; v_cat ifood_cat_modelo%rowtype; v_grupos jsonb := '[]'::jsonb; v_opcoes jsonb := '[]'::jsonb; g ifood_cat_modelo%rowtype; o jsonb; x ifood_cat_modelo%rowtype;
begin
  select * into r from ifood_cat_modelo where id = p_id;
  if not found then return null; end if;
  if r.tipo = 'item' then
    select * into v_cat from ifood_cat_modelo where id = nullif(r.dados->>'categoriaId', '')::uuid;
    for o in select value from jsonb_array_elements(coalesce(r.dados->'grupos', '[]'::jsonb)) loop
      select * into g from ifood_cat_modelo where id = nullif(o->>'id', '')::uuid and tipo = 'grupo';
      if found then
        v_grupos := v_grupos || jsonb_build_array(jsonb_build_object('id', g.id, 'nome', g.nome, 'dados', g.dados, 'min', coalesce(nullif(o->>'min', '')::int, 0), 'max', coalesce(nullif(o->>'max', '')::int, 1)));
        for x in select m.* from ifood_cat_modelo m where m.tipo = 'opcao' and m.id in (select nullif(oo->>'id', '')::uuid from jsonb_array_elements(coalesce(g.dados->'opcoes', '[]'::jsonb)) oo) loop
          if not exists (select 1 from jsonb_array_elements(v_opcoes) q where q->>'id' = x.id::text) then
            v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('id', x.id, 'nome', x.nome, 'dados', x.dados));
          end if;
        end loop;
      end if;
    end loop;
  end if;
  return jsonb_build_object('registro', jsonb_build_object('id', r.id, 'tipo', r.tipo, 'nome', r.nome, 'dados', r.dados),
    'categoria', case when v_cat.id is not null then jsonb_build_object('id', v_cat.id, 'nome', v_cat.nome, 'dados', v_cat.dados) end,
    'grupos', v_grupos, 'opcoes', v_opcoes);
end $$;

create or replace function public.ifood_cat_resultado(p_id uuid, p_estado text, p_erro text default null, p_patch jsonb default '{}'::jsonb) returns void
  language sql security definer set search_path to 'public' as $$
  update ifood_cat_modelo set estado = p_estado, erro = left(p_erro, 400), dados = (dados - 'fotoPendente') || coalesce(p_patch, '{}'::jsonb), atualizado_em = now() where id = p_id
$$;
create or replace function public.ifood_cat_patch(p_id uuid, p_patch jsonb) returns void
  language sql security definer set search_path to 'public' as $$
  update ifood_cat_modelo set dados = case when coalesce(p_patch, '{}'::jsonb) ? 'foto' then dados - 'fotoPendente' else dados end || coalesce(p_patch, '{}'::jsonb), atualizado_em = now() where id = p_id
$$;

revoke all on function public.api_ifood_cat(jsonb), public.api_ifood_cat_salvar(jsonb), public.api_ifood_cat_excluir(jsonb), public.api_ifood_cat_enviar(jsonb), public.api_ifood_cat_lote(jsonb), public.ifood_cat_arvore(uuid), public.ifood_cat_resultado(uuid, text, text, jsonb), public.ifood_cat_patch(uuid, jsonb) from public, anon;
grant execute on function public.api_ifood_cat(jsonb), public.api_ifood_cat_salvar(jsonb), public.api_ifood_cat_excluir(jsonb), public.api_ifood_cat_enviar(jsonb), public.api_ifood_cat_lote(jsonb) to authenticated, service_role;
grant execute on function public.ifood_cat_arvore(uuid), public.ifood_cat_resultado(uuid, text, text, jsonb), public.ifood_cat_patch(uuid, jsonb) to service_role;
