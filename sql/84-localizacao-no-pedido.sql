-- 84 — Localização do cliente guardada junto do pedido (entrega_destinos) e usada pela "Melhor rota";
--      ao entregar, a posição vira ponto aproximado (~500 m) no mapa do "Cardápio hoje" e a posição exata é apagada (trigger já existente).
create or replace function public._venda_guardar_geo()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare d entrega_destinos%rowtype; v_ch text;
begin
  if nullif(btrim(coalesce(new.endereco, '')), '') is null then return new; end if;
  select * into d from entrega_destinos where venda_id = new.id;
  if d.venda_id is null then return new; end if;
  v_ch := md5(coalesce(public._end_chave(new.endereco), public._ifood_norm(new.endereco)));
  insert into geo_enderecos (chave, lat, lng, achou)
  values (v_ch, round((d.lat / 0.005)::numeric) * 0.005, round((d.lng / 0.005)::numeric) * 0.005, true)
  on conflict (chave) do update set lat = excluded.lat, lng = excluded.lng, achou = true, criado_em = now();
  return new;
exception when others then
  return new;
end $$;
revoke all on function public._venda_guardar_geo() from public, anon, authenticated;
grant execute on function public._venda_guardar_geo() to service_role;
create or replace trigger aa_venda_guardar_geo before update of status_pedido on public.vendas
  for each row when (new.status_pedido = 'Entregue'::status_pedido and old.status_pedido is distinct from new.status_pedido)
  execute function public._venda_guardar_geo();
-- api_rota_entrega (SQL 80) passou a devolver também "destinos" (entrega_destinos) — veja a versão atual no banco.
