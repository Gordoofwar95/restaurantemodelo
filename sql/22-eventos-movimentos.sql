-- =====================================================================
-- 22 · CENTRAL DE EVENTOS: lista de custos/recebimentos e cancelamento (18/10/2026)
-- Custos e recebimentos lançados podem ser cancelados (nada é apagado: fica marcado). Os totais ignoram os cancelados.
-- Aditivo: 2 colunas por tabela, 1 função ajustada, 2 funções novas.
-- =====================================================================
alter table public.eventos_custos add column if not exists cancelado boolean not null default false;
alter table public.eventos_custos add column if not exists motivo_cancelamento text;
alter table public.eventos_recebimentos add column if not exists cancelado boolean not null default false;
alter table public.eventos_recebimentos add column if not exists motivo_cancelamento text;

create or replace function public._recalcular_evento(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_contr numeric; v_custos numeric; v_rec numeric;
begin
  select valor_contratado into v_contr from eventos where id = p_id;
  if not found then return; end if;
  select coalesce(sum(valor), 0) into v_custos from eventos_custos where evento_id = p_id and not cancelado;
  select coalesce(sum(valor), 0) into v_rec from eventos_recebimentos where evento_id = p_id and not cancelado;
  update eventos set valor_recebido = v_rec, valor_a_receber = greatest(0, v_contr - v_rec), custo_total = v_custos,
         resultado = round(v_contr - v_custos, 2) where id = p_id;
end $$;

create or replace function public.api_evento_movimentos(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'eventoId');
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not exists (select 1 from eventos where id = v_id) then return _falha('Evento não encontrado.'); end if;
  return jsonb_build_object('ok', true,
    'custos', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'descricao', c.descricao, 'categoria', coalesce(c.categoria, ''), 'valor', c.valor,
        'data', coalesce(c.data::text, ''), 'observacao', coalesce(c.observacao, '')) order by c.data desc nulls last, c.criado_em desc)
        from eventos_custos c where c.evento_id = v_id and not c.cancelado), '[]'::jsonb),
    'recebimentos', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'valor', r.valor, 'forma', coalesce(r.forma_pagamento, ''),
        'data', coalesce(r.data::text, ''), 'observacao', coalesce(r.observacao, '')) order by r.data desc nulls last, r.criado_em desc)
        from eventos_recebimentos r where r.evento_id = v_id and not r.cancelado), '[]'::jsonb));
end $$;

create or replace function public.api_cancelar_movimento_evento(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_tipo text := p->>'tipo'; v_id uuid := _uuid(p->>'id'); v_motivo text := left(btrim(coalesce(p->>'motivo', '')), 300); v_aut text; v_ev uuid; v_val numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  if v_motivo = '' then return _falha('Informe o motivo do cancelamento.'); end if;
  if v_tipo = 'custo' then
    update eventos_custos set cancelado = true, motivo_cancelamento = v_motivo where id = v_id and not cancelado returning evento_id, valor into v_ev, v_val;
  elsif v_tipo = 'recebimento' then
    update eventos_recebimentos set cancelado = true, motivo_cancelamento = v_motivo where id = v_id and not cancelado returning evento_id, valor into v_ev, v_val;
  else
    return _falha('Tipo inválido.');
  end if;
  if v_ev is null then return _falha('Lançamento não encontrado ou já cancelado.'); end if;
  perform _recalcular_evento(v_ev);
  perform _auditar('Lançamento de evento cancelado', v_tipo || ' R$ ' || _dinheiro(v_val) || ' | ' || v_motivo);
  return jsonb_build_object('ok', true, 'message', 'Lançamento cancelado.', 'evento', _evento_json(v_ev));
end $$;

revoke all on function public.api_evento_movimentos(jsonb) from public;
revoke all on function public.api_cancelar_movimento_evento(jsonb) from public;
grant execute on function public.api_evento_movimentos(jsonb) to authenticated, service_role;
grant execute on function public.api_cancelar_movimento_evento(jsonb) to authenticated, service_role;
