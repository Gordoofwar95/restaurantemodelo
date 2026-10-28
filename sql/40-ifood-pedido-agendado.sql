-- 40 · iFood: pedido AGENDADO só é despachado a partir do início da janela de entrega.
-- Antes, o "despachar" saía na hora e o iFood reprovou na homologação ("despachado antes da janela de entrega agendada").
-- Agora a ação fica guardada (pendente) e é enviada sozinha quando a janela abre.
create or replace function public.ifood_acoes_pendentes() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'pedido', a.pedido_ifood, 'acao', a.acao, 'dados', a.dados, 'tentativas', a.tentativas) order by a.id), '[]'::jsonb)
  from (
    select x.* from ifood_acoes x
    where x.estado = 'pendente'
      and not (
        x.acao = 'despachar'
        and exists (
          select 1 from ifood_pedidos p
          where p.pedido_ifood = x.pedido_ifood
            and upper(coalesce(p.bruto->>'orderTiming', '')) = 'SCHEDULED'
            and coalesce(p.bruto->'schedule'->>'deliveryDateTimeStart', '') ~ '^\d{4}-\d{2}-\d{2}T'
            and (p.bruto->'schedule'->>'deliveryDateTimeStart')::timestamptz > now()
        )
      )
    order by x.id limit 20
  ) a
$$;
revoke all on function public.ifood_acoes_pendentes() from public, anon, authenticated;
grant execute on function public.ifood_acoes_pendentes() to service_role;
