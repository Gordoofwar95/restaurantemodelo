-- 32 · Etiquetas de validade (18/10/2026)
-- • Cadastro de itens com os dias de validade (aberto, manipulado, descongelado, fechado) — o dono preenche; nada vem pronto.
-- • Admin cadastra e muda os itens; Admin, Operador e Cozinha imprimem. Cada impressão fica registrada (limpeza após 45 dias pela rotina diária da Edge Function evidencia-foto).

create table if not exists public.etiqueta_itens (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  dias jsonb not null default '{}'::jsonb,       -- {"aberto":3,"manipulado":2,"descongelado":1,"fechado":30} (só o que o dono preencher)
  conservacao text not null default 'Refrigerado' check (conservacao in ('Refrigerado', 'Congelado', 'Ambiente')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create unique index if not exists etiqueta_itens_nome_uq on public.etiqueta_itens (lower(nome));
create table if not exists public.etiqueta_impressoes (
  id uuid primary key default gen_random_uuid(),
  item_nome text not null,
  tipo text not null,
  qtd int not null,
  manipulado_em timestamptz,
  validade date,
  conservacao text,
  lote text,
  usuario_id uuid,
  usuario_nome text,
  criado_em timestamptz not null default now()
);
create index if not exists etiqueta_impressoes_data_idx on public.etiqueta_impressoes (criado_em);
alter table public.etiqueta_itens enable row level security;
alter table public.etiqueta_impressoes enable row level security;
revoke all on public.etiqueta_itens, public.etiqueta_impressoes from anon, authenticated;
grant all on public.etiqueta_itens, public.etiqueta_impressoes to service_role;

create or replace function public.api_etiquetas_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_todos boolean := coalesce((p->>'todos')::boolean, false) and tem_nivel('Admin');
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'itens', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'nome', i.nome, 'dias', i.dias, 'conservacao', i.conservacao, 'ativo', i.ativo) order by lower(i.nome))
    from etiqueta_itens i where v_todos or i.ativo), '[]'::jsonb));
end $$;

create or replace function public.api_etiqueta_salvar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_nome text := btrim(coalesce(p->>'nome', '')); v_id uuid; v_dias jsonb := '{}'::jsonb; k text; n numeric; v_cons text := coalesce(nullif(p->>'conservacao', ''), 'Refrigerado');
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_nome = '' or length(v_nome) > 60 then return _falha('Informe o nome do item (até 60 letras).'); end if;
  if v_cons not in ('Refrigerado', 'Congelado', 'Ambiente') then return _falha('Conservação inválida.'); end if;
  foreach k in array array['aberto', 'manipulado', 'descongelado', 'fechado'] loop
    if nullif(btrim(coalesce(p->'dias'->>k, '')), '') is not null then
      begin n := (p->'dias'->>k)::numeric; exception when others then return _falha('Dias de validade inválidos.'); end;
      if n < 0 or n > 3650 or n <> trunc(n) then return _falha('Dias de validade devem ser um número inteiro entre 0 e 3650.'); end if;
      v_dias := v_dias || jsonb_build_object(k, n::int);
    end if;
  end loop;
  begin v_id := nullif(p->>'id', '')::uuid; exception when others then return _falha('Pedido inválido.'); end;
  if v_id is not null then
    update etiqueta_itens set nome = v_nome, dias = v_dias, conservacao = v_cons, ativo = coalesce((p->>'ativo')::boolean, true) where id = v_id;
    if not found then return _falha('Item não encontrado.'); end if;
  else
    if exists (select 1 from etiqueta_itens where lower(nome) = lower(v_nome)) then return _falha('Já existe um item com esse nome.'); end if;
    insert into etiqueta_itens (nome, dias, conservacao) values (v_nome, v_dias, v_cons) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'message', 'Item salvo.');
exception when unique_violation then return _falha('Já existe um item com esse nome.');
end $$;

create or replace function public.api_etiqueta_importar_estoque(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  insert into etiqueta_itens (nome) select btrim(e.ingrediente) from estoque e where btrim(coalesce(e.ingrediente, '')) <> '' on conflict do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'novos', v_n, 'message', v_n || ' ingrediente(s) trazido(s) do estoque. Agora preencha os dias de validade de cada um.');
end $$;

create or replace function public.api_etiqueta_registrar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_nome text := btrim(coalesce(p->>'nome', '')); v_tipo text := p->>'tipo'; v_qtd int; v_val date; v_man timestamptz; v_cons text := nullif(p->>'conservacao', ''); v_u text;
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha') then return _negado(); end if;
  if v_nome = '' or length(v_nome) > 60 then return _falha('Informe o nome do item.'); end if;
  if v_tipo not in ('Aberto', 'Manipulado', 'Descongelado', 'Fechado') then return _falha('Escolha o tipo da etiqueta.'); end if;
  begin v_qtd := (p->>'qtd')::int; v_val := (p->>'validade')::date; v_man := nullif(p->>'manipuladoEm', '')::timestamptz;
  exception when others then return _falha('Dados da etiqueta inválidos.'); end;
  if v_qtd is null or v_qtd < 1 or v_qtd > 100 then return _falha('A quantidade de etiquetas deve ficar entre 1 e 100.'); end if;
  if v_val is null then return _falha('Informe a validade.'); end if;
  select coalesce(nullif(u.nome, ''), u.login) into v_u from usuarios u where u.id = auth.uid();
  insert into etiqueta_impressoes (item_nome, tipo, qtd, manipulado_em, validade, conservacao, lote, usuario_id, usuario_nome)
  values (v_nome, v_tipo, v_qtd, v_man, v_val, left(v_cons, 20), left(nullif(btrim(coalesce(p->>'lote', '')), ''), 40), auth.uid(), v_u);
  return jsonb_build_object('ok', true, 'responsavel', v_u);
end $$;

do $$
declare f text;
begin
  foreach f in array array['api_etiquetas_lista(jsonb)', 'api_etiqueta_salvar(jsonb)', 'api_etiqueta_importar_estoque(jsonb)', 'api_etiqueta_registrar(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
