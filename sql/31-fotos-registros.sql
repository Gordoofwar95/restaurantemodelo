-- 31 · Fotos opcionais em três lançamentos (18/10/2026): perda de estoque, recebimento de compra e ocorrência de pedido
-- • A foto vai para o Drive principal e para o da contingência (pasta privada "Restaurante Demo - Fotos de registros") pela Edge Function evidencia-foto.
-- • Até 3 fotos por registro, opcionais. Ficam 45 dias: rotina diária evidencias-45-dias apaga os arquivos dos dois Drives e as linhas.
-- • Quem pode anexar: só quem fez o lançamento, logo depois (30 minutos). Quem pode ver: Admin (perda, recebimento) e Admin/Operador (ocorrência).

create table if not exists public.evidencias_foto (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('perda', 'recebimento', 'ocorrencia')),
  ref_id uuid not null,
  path text not null,
  usuario_id uuid,
  criado_em timestamptz not null default now()
);
create index if not exists evidencias_foto_ref_idx on public.evidencias_foto (tipo, ref_id);
create index if not exists evidencias_foto_data_idx on public.evidencias_foto (criado_em);
alter table public.evidencias_foto enable row level security;
revoke all on public.evidencias_foto from anon, authenticated;
grant all on public.evidencias_foto to service_role;

-- a perda de estoque passa a devolver o id da movimentação (para ligar a foto)
create or replace function public.api_registrar_perda_estoque(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e estoque%rowtype; v_qtd numeric := _num(p->>'quantidade'); v_req text := nullif(p->>'requisicaoId', ''); v_r jsonb; v_depois numeric; v_motivo text := btrim(coalesce(p->>'motivo', '')); v_mid uuid;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_req is not null then perform pg_advisory_xact_lock(hashtext(v_req)); v_r := _idem_ler(v_req); if v_r is not null then return v_r; end if; end if;
  if v_qtd <= 0 then return _falha('Informe uma quantidade de perda maior que zero.'); end if;
  if v_motivo = '' then return _falha('Informe o motivo da perda.'); end if;
  select * into e from estoque where id = _uuid(p->>'ingredienteId') for update;
  if not found then return _falha('Ingrediente não encontrado.'); end if;
  if v_qtd > e.quantidade then return _falha('A perda (' || v_qtd || ') é maior que o estoque atual de ' || e.ingrediente || ' (' || e.quantidade || '). Nada foi registrado.'); end if;
  v_depois := greatest(0, e.quantidade - v_qtd);
  update estoque set quantidade = v_depois where id = e.id;
  insert into movimentacoes_estoque (ingrediente_id, tipo, quantidade, qtd_antes, qtd_depois, motivo_referencia, usuario_id)
  values (e.id, 'Perda', -v_qtd, e.quantidade, v_depois, v_motivo, auth.uid()) returning id into v_mid;
  perform _auditar('Perda de estoque', e.ingrediente || ': -' || v_qtd || ' (' || v_motivo || ')');
  v_r := jsonb_build_object('ok', true, 'message', 'Perda registrada.', 'id', v_mid);
  if v_req is not null then perform _idem_gravar(v_req, 'registrarPerdaEstoque', v_r); end if;
  return v_r;
end $$;

-- confere se esta pessoa pode anexar foto a este registro agora
create or replace function public._evidencia_pode(p_tipo text, p_ref uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ok boolean := false; v_n int;
begin
  if auth_nivel() is null then return _negado(); end if;
  if p_ref is null or p_tipo not in ('perda', 'recebimento', 'ocorrencia') then return _falha('Pedido inválido.'); end if;
  if p_tipo = 'perda' then
    v_ok := tem_nivel('Admin') and exists (select 1 from movimentacoes_estoque m where m.id = p_ref and m.tipo::text = 'Perda' and m.usuario_id = auth.uid() and m.data > now() - interval '30 minutes');
  elsif p_tipo = 'recebimento' then
    v_ok := tem_nivel('Admin') and exists (select 1 from compras c where c.id = p_ref and c.status = 'Recebida' and coalesce(c.recebida_em, c.criado_em) > now() - interval '60 minutes');
  else
    v_ok := exists (select 1 from ocorrencias o where o.id = p_ref and o.registrado_por = auth.uid() and o.data_hora > now() - interval '30 minutes');
  end if;
  if not v_ok then return _falha('Não foi possível anexar foto a este registro (ou já passou do prazo).'); end if;
  select count(*) into v_n from evidencias_foto where tipo = p_tipo and ref_id = p_ref;
  if v_n >= 3 then return _falha('Este registro já tem 3 fotos.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_evidencia_pode(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  return _evidencia_pode(p->>'tipo', nullif(p->>'refId', '')::uuid);
exception when invalid_text_representation then return _falha('Pedido inválido.');
end $$;

create or replace function public.api_evidencia_anexar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_t text := p->>'tipo'; v_ref uuid; v_path text := p->>'path'; v_ok jsonb;
begin
  begin v_ref := nullif(p->>'refId', '')::uuid; exception when others then return _falha('Pedido inválido.'); end;
  v_ok := _evidencia_pode(v_t, v_ref);
  if not coalesce((v_ok->>'ok')::boolean, false) then return v_ok; end if;
  if v_path is null or v_path = '' or v_path !~ '^(drive:[A-Za-z0-9_-]{10,80})?(\|)?(cont:[A-Za-z0-9_-]{10,80})?$' then return _falha('Caminho da foto inválido.'); end if;
  insert into evidencias_foto (tipo, ref_id, path, usuario_id) values (v_t, v_ref, v_path, auth.uid());
  return jsonb_build_object('ok', true);
end $$;

-- quantas fotos cada registro tem (só para quem pode ver)
create or replace function public.api_evidencias_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_t text := p->>'tipo'; v_ids uuid[]; v_m jsonb;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_t not in ('perda', 'recebimento', 'ocorrencia') then return _falha('Pedido inválido.'); end if;
  if not ((v_t = 'ocorrencia' and tem_nivel('Admin', 'Operador')) or (v_t <> 'ocorrencia' and tem_nivel('Admin'))) then return jsonb_build_object('ok', true, 'mapa', '{}'::jsonb); end if;
  begin select array_agg(x::uuid) into v_ids from (select jsonb_array_elements_text(p->'ids') x limit 150) s; exception when others then v_ids := null; end;
  select coalesce(jsonb_object_agg(ref_id::text, n), '{}'::jsonb) into v_m from (select ref_id, count(*) n from evidencias_foto where tipo = v_t and ref_id = any(coalesce(v_ids, '{}')) group by 1) q;
  return jsonb_build_object('ok', true, 'mapa', v_m);
end $$;

do $$
declare f text;
begin
  foreach f in array array['api_evidencia_pode(jsonb)', 'api_evidencia_anexar(jsonb)', 'api_evidencias_lista(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
  revoke all on function public._evidencia_pode(text, uuid) from public, anon, authenticated;
end $$;

-- limpeza diária: a Edge Function evidencia-foto apaga nos dois Drives e remove as linhas com mais de 45 dias
select cron.schedule('evidencias-45-dias', '50 6 * * *', $$select public.chamar_edge('evidencia-foto', '{"acao":"limpar"}'::jsonb)$$);
