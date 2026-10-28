-- =====================================================================
-- 55 - Funil do cardápio + "CARDÁPIO HOJE" com mapa
-- ---------------------------------------------------------------------
-- Funil (por aparelho, sem nome nem telefone): entrou no cardápio →
-- abriu um item → pôs no carrinho → abriu o finalizar → enviou o pedido.
-- Mapa: localização APROXIMADA de quem entrou (arredondada em ~500 m),
-- só de quem já permitiu a localização no aparelho. É APAGADA ao fechar
-- o caixa e, de qualquer forma, depois de 24 horas.
-- Leitura: só Admin e Operador. Aparelho da equipe não conta.
-- Tudo aditivo. Pode rodar mais de uma vez.
-- =====================================================================

create table if not exists public.cardapio_funil (
  dia date not null,
  aparelho text not null,
  etapa text not null check (etapa in ('visita', 'item', 'carrinho', 'finalizar', 'pedido')),
  primeiro_em timestamptz not null default now(),
  primary key (dia, aparelho, etapa)
);
create index if not exists ix_cardapio_funil_em on public.cardapio_funil (primeiro_em);
alter table public.cardapio_funil enable row level security;
revoke all on table public.cardapio_funil from public, anon, authenticated;
grant all on table public.cardapio_funil to service_role;

create table if not exists public.cardapio_locais (
  aparelho text primary key,
  lat numeric(8,4) not null,
  lng numeric(8,4) not null,
  criado_em timestamptz not null default now()
);
create index if not exists ix_cardapio_locais_em on public.cardapio_locais (criado_em);
alter table public.cardapio_locais enable row level security;
revoke all on table public.cardapio_locais from public, anon, authenticated;
grant all on table public.cardapio_locais to service_role;

-- registrar uma etapa (cliente, sem login). Limite: 40 mil registros por dia no total.
create or replace function public.api_cardapio_funil(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_ap text := lower(btrim(coalesce(p->>'aparelho', ''))); v_et text := lower(btrim(coalesce(p->>'etapa', '')));
        v_dia date := (now() at time zone 'America/Sao_Paulo')::date; v_lat numeric; v_lng numeric;
begin
  if v_ap !~ '^[a-z0-9]{16,40}$' or v_et not in ('visita', 'item', 'carrinho', 'finalizar', 'pedido') then return jsonb_build_object('ok', false); end if;
  if exists (select 1 from cardapio_aparelhos_equipe where aparelho = v_ap) then return jsonb_build_object('ok', true); end if;
  if (select count(*) from cardapio_funil where dia = v_dia) >= 40000 then return jsonb_build_object('ok', true); end if;
  insert into cardapio_funil (dia, aparelho, etapa) values (v_dia, v_ap, v_et) on conflict do nothing;
  if v_et = 'visita' then
    insert into cardapio_visitas (dia, aparelho) values (v_dia, v_ap) on conflict do nothing;   -- o contador antigo continua igual
  end if;
  -- localização aproximada (grade de ~500 m), só dentro do Brasil
  begin v_lat := (p->>'lat')::numeric; v_lng := (p->>'lng')::numeric; exception when others then v_lat := null; end;
  if v_lat is not null and v_lng is not null and v_lat between -34 and 6 and v_lng between -74 and -34 then
    insert into cardapio_locais (aparelho, lat, lng) values (v_ap, round(v_lat / 0.005) * 0.005, round(v_lng / 0.005) * 0.005)
      on conflict (aparelho) do update set lat = excluded.lat, lng = excluded.lng, criado_em = now();
  end if;
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function public.api_cardapio_funil(jsonb) from public;
grant execute on function public.api_cardapio_funil(jsonb) to anon, authenticated, service_role;

-- "CARDÁPIO HOJE" (Admin e Operador): desde a abertura do caixa (turno); sem caixa aberto, últimas 24 horas
create or replace function public.api_cardapio_hoje(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_ini timestamptz; v_turno boolean;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select abertura into v_ini from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  v_turno := v_ini is not null;
  v_ini := coalesce(v_ini, now() - interval '24 hours');
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
    'restaurante', (select jsonb_build_object('lat', (valor->>'lat')::numeric, 'lng', (valor->>'lng')::numeric) from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object'));
end $function$;
revoke all on function public.api_cardapio_hoje(jsonb) from public, anon;
grant execute on function public.api_cardapio_hoje(jsonb) to authenticated, service_role;

-- fechou o caixa: apaga as localizações (fim do turno)
create or replace function public._trg_caixa_fecha_apaga_locais() returns trigger
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.status::text = 'Fechado' and old.status::text is distinct from 'Fechado' then delete from cardapio_locais; end if;
  return new;
end $function$;
revoke all on function public._trg_caixa_fecha_apaga_locais() from public, anon, authenticated;
drop trigger if exists caixa_fecha_apaga_locais on public.caixa_sessoes;
create trigger caixa_fecha_apaga_locais after update of status on public.caixa_sessoes for each row execute function public._trg_caixa_fecha_apaga_locais();

-- de hora em hora: localização com mais de 24 h sai; funil guarda 90 dias
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'cardapio-funil-limpeza') then
    perform cron.schedule('cardapio-funil-limpeza', '17 * * * *',
      $c$delete from public.cardapio_locais where criado_em < now() - interval '24 hours';
         delete from public.cardapio_funil where dia < current_date - 90$c$);
  end if;
end $$;
