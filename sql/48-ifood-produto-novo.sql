-- 48 · iFood: produto novo cadastrado no sistema vai ao iFood PAUSADO (para revisar foto e ativar)
-- Só envia se o iFood estiver ligado, o ajuste "produtoNovoNoIfood" não for false (padrão: ligado) e o produto tiver preço do iFood.
-- O código do item no iFood é o id do produto: os pedidos desse item já chegam ligados ao produto.
-- A categoria é criada no iFood se ainda não existir (a Edge Function ifood-sync envia a categoria antes do item).
create or replace function public._ifood_produto_novo(p_id uuid) returns void
  language plpgsql security definer set search_path to 'public' as $$
declare v_p produtos%rowtype; v_cat text; v_preco numeric; v_cid uuid; v_cfg jsonb;
begin
  if not _integracao_ligada('ifood') then return; end if;
  select config into v_cfg from integracoes_config where provedor = 'ifood';
  if coalesce((v_cfg->>'produtoNovoNoIfood')::boolean, true) is not true then return; end if;
  select * into v_p from produtos where id = p_id; if v_p.id is null then return; end if;
  select pp.preco into v_preco from produto_precos pp where pp.produto_id = p_id and pp.forma_pagamento_id = _ifood_forma();
  if coalesce(v_preco, 0) <= 0 then return; end if;
  if exists (select 1 from ifood_cat_modelo where id = p_id) then return; end if;
  select nome into v_cat from categorias where id = v_p.categoria_id;
  v_cat := coalesce(nullif(btrim(v_cat), ''), 'Cardápio');
  select id into v_cid from ifood_cat_modelo where tipo = 'categoria' and lower(btrim(nome)) = lower(v_cat) and coalesce(dados->>'oculto', '') <> 'true' order by atualizado_em limit 1;
  if v_cid is null then
    insert into ifood_cat_modelo (tipo, nome, dados) values ('categoria', v_cat, '{"status":"AVAILABLE"}'::jsonb) returning id into v_cid;
  end if;
  insert into ifood_cat_modelo (id, tipo, nome, dados, estado)
  values (p_id, 'item', left(v_p.nome, 120), jsonb_build_object('descricao', left(coalesce(v_p.descricao, ''), 1000), 'preco', v_preco, 'status', 'UNAVAILABLE', 'categoriaId', v_cid, 'criadoPeloSistema', true), 'pendente');
  perform _ifood_enfileirar('LOJA', 'catalogo_modelo_enviar', jsonb_build_object('chave', p_id::text, 'id', p_id));
  perform _push_admins('Produto novo enviado ao iFood (pausado)', v_p.nome || ': revise a foto e ative em Integrações → iFood → Cardápio no iFood.', 'ifood-produto-novo');
exception when others then null;
end $$;
revoke all on function public._ifood_produto_novo(uuid) from public, anon, authenticated;
grant execute on function public._ifood_produto_novo(uuid) to service_role;

-- api_add_produto: mesma função de sempre, com a chamada _ifood_produto_novo ao final
CREATE OR REPLACE FUNCTION public.api_add_produto(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_nome text := btrim(coalesce(p->>'nome', '')); v_id uuid := gen_random_uuid(); v_cat uuid := _uuid(p->>'categoria');
        v_ordem int; v_proprio uuid;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_nome = '' then return _falha('Informe o nome do produto.'); end if;
  if exists (select 1 from produtos where lower(btrim(nome)) = lower(v_nome)) then return _falha('Já existe um produto com esse nome.'); end if;
  v_proprio := _estoque_proprio(null, v_nome, p->'estoqueProprio');
  select coalesce(max(ordem_cardapio), 0) + 1 into v_ordem from produtos where categoria_id is not distinct from v_cat;
  insert into produtos (id, nome, descricao, categoria_id, ativo, destaque, estoque_proprio_ingrediente_id, ordem_cardapio)
  values (v_id, v_nome, coalesce(p->>'descricao', ''), v_cat, true, coalesce((p->>'destaque')::boolean, false), v_proprio, v_ordem);
  perform _produto_gravar_precos(v_id, _precos_ou_base(p));
  perform _produto_gravar_receita(v_id, p->'ingredientes', v_proprio);
  perform _produto_gravar_adicionais(v_id, p->'adicionaisIds');
  perform _auditar('Produto cadastrado', v_nome);
  perform _ifood_produto_novo(v_id);
  return jsonb_build_object('ok', true, 'message', 'Produto cadastrado.', 'id', v_id);
end $function$;
