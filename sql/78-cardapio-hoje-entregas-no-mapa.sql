-- 78 · Mapa do "Cardápio hoje": mostra também os pedidos ENTREGUES (sistema e iFood) em outra cor.
-- iFood: usa as coordenadas que o próprio pedido traz. Sistema: o endereço é localizado uma vez (pelo navegador, no OpenStreetMap) e guardado só como ponto aproximado (~500 m), sem o texto do endereço. Fica guardado (peso desprezível), não é apagado ao fechar o caixa.
create table if not exists public.geo_enderecos (
  chave text primary key,            -- md5 do endereço normalizado (não guarda o endereço)
  lat double precision, lng double precision,
  achou boolean not null default true,
  criado_em timestamptz not null default now()
);
alter table public.geo_enderecos enable row level security;
revoke all on public.geo_enderecos from public, anon, authenticated;
grant all on public.geo_enderecos to service_role;

create or replace function public.api_geo_endereco_salvar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_ch text := p->>'chave'; v_ok boolean := coalesce((p->>'achou')::boolean, true); v_lat double precision; v_lng double precision;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if v_ch is null or v_ch !~ '^[0-9a-f]{32}$' then return _falha('Endereço inválido.'); end if;
  if v_ok then
    v_lat := round((nullif(p->>'lat', '')::double precision / 0.005)::numeric) * 0.005;
    v_lng := round((nullif(p->>'lng', '')::double precision / 0.005)::numeric) * 0.005;
    if v_lat is null or v_lng is null or v_lat not between -34 and 6 or v_lng not between -74 and -34 then return _falha('Localização fora do Brasil.'); end if;
  end if;
  insert into geo_enderecos (chave, lat, lng, achou) values (v_ch, v_lat, v_lng, v_ok) on conflict (chave) do update set lat = excluded.lat, lng = excluded.lng, achou = excluded.achou;
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.api_geo_endereco_salvar(jsonb) from public, anon;
grant execute on function public.api_geo_endereco_salvar(jsonb) to authenticated, service_role;

-- fallback do mapa: se o endereço do sistema não é achado no OpenStreetMap, usa a posição de um pedido do iFood na mesma rua (o iFood traz coordenadas)
create or replace function public._geo_rua_ifood(p_rua text) returns table(lat double precision, lng double precision)
 language sql stable security definer set search_path to 'public' as $f$
  select avg(x.la), avg(x.ln) from (
    select (ip.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}')::double precision la, (ip.bruto #>> '{delivery,deliveryAddress,coordinates,longitude}')::double precision ln
      from ifood_pedidos ip join vendas v on v.id = ip.venda_id
     where coalesce(p_rua, '') <> '' and split_part(public._end_chave(v.endereco), '|', 1) = p_rua
       and ip.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}' ~ '^-?[0-9.]+$' and ip.bruto #>> '{delivery,deliveryAddress,coordinates,longitude}' ~ '^-?[0-9.]+$') x
$f$;
revoke all on function public._geo_rua_ifood(text) from public, anon, authenticated;
grant execute on function public._geo_rua_ifood(text) to service_role;

create or replace function public.api_cardapio_hoje(p jsonb DEFAULT '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare v_ini timestamptz; v_turno boolean; v_h jsonb; v_ent jsonb; v_pend jsonb; v_nao int; v_enti jsonb;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select abertura into v_ini from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  v_turno := v_ini is not null;
  v_ini := coalesce(v_ini, now() - interval '24 hours');
  select coalesce(jsonb_agg(jsonb_build_object('lat',
           case when ip.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}' ~ '^-?[0-9.]+$' then (ip.bruto #>> '{delivery,deliveryAddress,coordinates,latitude}')::double precision end,
         'lng', case when ip.bruto #>> '{delivery,deliveryAddress,coordinates,longitude}' ~ '^-?[0-9.]+$' then (ip.bruto #>> '{delivery,deliveryAddress,coordinates,longitude}')::double precision end,
         'chave', case when nullif(btrim(v.endereco), '') is not null then md5(coalesce(public._end_chave(v.endereco), public._ifood_norm(v.endereco))) end,
         'endereco', v.endereco, 'ifood', ip.venda_id is not null, 'rua', coalesce(split_part(public._end_chave(v.endereco), '|', 1), ''))), '[]'::jsonb) into v_h
    from vendas v left join ifood_pedidos ip on ip.venda_id = v.id
   where v.tipo = 'Entrega' and v.status_pedido = 'Entregue' and v.status = 'Confirmada' and v.data_hora >= v_ini;
  select coalesce(jsonb_agg(jsonb_build_object('lat', la, 'lng', ln, 'n', n)), '[]'::jsonb) into v_ent from (
    select round((coalesce(h.lat, g.lat, r.lat) / 0.005)::numeric) * 0.005 la, round((coalesce(h.lng, g.lng, r.lng) / 0.005)::numeric) * 0.005 ln, count(*)::int n
      from jsonb_to_recordset(v_h) h(lat double precision, lng double precision, chave text, endereco text, ifood boolean, rua text)
      left join geo_enderecos g on g.chave = h.chave and g.achou
      left join lateral public._geo_rua_ifood(h.rua) r on h.lat is null and h.rua <> ''
     where coalesce(h.lat, g.lat, r.lat) is not null and not coalesce(h.ifood, false) group by 1, 2) x;
  select coalesce(jsonb_agg(jsonb_build_object('lat', la, 'lng', ln, 'n', n)), '[]'::jsonb) into v_enti from (
    select round((coalesce(h.lat, g.lat, r.lat) / 0.005)::numeric) * 0.005 la, round((coalesce(h.lng, g.lng, r.lng) / 0.005)::numeric) * 0.005 ln, count(*)::int n
      from jsonb_to_recordset(v_h) h(lat double precision, lng double precision, chave text, endereco text, ifood boolean, rua text)
      left join geo_enderecos g on g.chave = h.chave and g.achou
      left join lateral public._geo_rua_ifood(h.rua) r on h.lat is null and h.rua <> ''
     where coalesce(h.lat, g.lat, r.lat) is not null and coalesce(h.ifood, false) group by 1, 2) x2;
  select coalesce(jsonb_agg(jsonb_build_object('chave', chave, 'endereco', endereco, 'ifood', coalesce(ifood, false))), '[]'::jsonb) into v_pend from (
    select distinct on (h.chave) h.chave, h.endereco, h.ifood from jsonb_to_recordset(v_h) h(lat double precision, lng double precision, chave text, endereco text, ifood boolean, rua text)
      left join geo_enderecos g on g.chave = h.chave
      left join lateral public._geo_rua_ifood(h.rua) r on h.rua <> ''
     where h.lat is null and r.lat is null and h.chave is not null and g.chave is null limit 6) y;
  select count(*)::int into v_nao from jsonb_to_recordset(v_h) h(lat double precision, lng double precision, chave text, endereco text, ifood boolean, rua text)
   where h.lat is null and not exists (select 1 from public._geo_rua_ifood(h.rua) r where h.rua <> '' and r.lat is not null) and (h.chave is null or exists (select 1 from geo_enderecos g where g.chave = h.chave and not g.achou));
  return jsonb_build_object('ok', true, 'desde', v_ini, 'turno', v_turno,
    'funil', (select jsonb_build_object(
        'visita',    count(distinct aparelho) filter (where etapa = 'visita'),
        'item',      count(distinct aparelho) filter (where etapa = 'item'),
        'carrinho',  count(distinct aparelho) filter (where etapa = 'carrinho'),
        'finalizar', count(distinct aparelho) filter (where etapa = 'finalizar'),
        'pedido',    count(distinct aparelho) filter (where etapa = 'pedido'))
      from cardapio_funil f where f.primeiro_em >= v_ini
       and not exists (select 1 from cardapio_aparelhos_equipe e where e.aparelho = f.aparelho)),
    'pedidosCardapio', (select count(*) from vendas where origem = 'Cardápio' and status = 'Confirmada' and data_hora >= v_ini),
    'pontos', coalesce((select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'n', n)) from (
        select l.lat, l.lng, count(*)::int n from cardapio_locais l
         where l.criado_em >= v_ini and not exists (select 1 from cardapio_aparelhos_equipe e where e.aparelho = l.aparelho)
         group by l.lat, l.lng) x), '[]'::jsonb),
    'pedidos', coalesce((select jsonb_agg(jsonb_build_object('lat', round((d.lat / 0.005)::numeric) * 0.005, 'lng', round((d.lng / 0.005)::numeric) * 0.005))
        from pedido_destinos d join vendas v on v.id = d.venda_id
       where v.data_hora >= v_ini and v.status = 'Confirmada'), '[]'::jsonb),
    'entregues', v_ent, 'entreguesIfood', v_enti, 'entreguesTotal', jsonb_array_length(v_h), 'semCoord', v_pend, 'naoLocalizados', v_nao,
    'restaurante', (select jsonb_build_object('lat', (valor->>'lat')::numeric, 'lng', (valor->>'lng')::numeric) from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object'));
end $f$;
