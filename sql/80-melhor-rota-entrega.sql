-- 80 — Melhor rota de entrega: devolve ao aparelho as coordenadas exatas dos pedidos do iFood
-- e o local do restaurante (se definido em Equipe > Ponto). Só leitura; nada é gravado.
create or replace function public.api_rota_entrega(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_ids uuid[]; v_pts jsonb; v_rest jsonb; v_adm boolean;
begin
  if not tem_nivel('Admin', 'Operador', 'Entregador') then return _negado(); end if;
  v_adm := tem_nivel('Admin', 'Operador');
  begin
    select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  exception when others then return _falha('Pedidos inválidos.'); end;
  if cardinality(v_ids) > 12 then return _falha('Pedidos demais para uma rota.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id,
           'lat', (i.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}')::double precision,
           'lng', (i.bruto #>> '{delivery,deliveryAddress,coordinates,longitude}')::double precision)), '[]'::jsonb)
    into v_pts
    from vendas v join ifood_pedidos i on i.venda_id = v.id
   where v.id = any(v_ids) and (v_adm or v.entregador_id = auth.uid())
     and (i.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}') is not null;
  select jsonb_build_object('lat', (valor->>'lat')::double precision, 'lng', (valor->>'lng')::double precision)
    into v_rest from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object';
  return jsonb_build_object('ok', true, 'ifood', v_pts, 'restaurante', v_rest);
end $$;
revoke all on function public.api_rota_entrega(jsonb) from public, anon;
grant execute on function public.api_rota_entrega(jsonb) to authenticated, service_role;
