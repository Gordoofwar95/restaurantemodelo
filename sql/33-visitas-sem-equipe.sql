-- 33 · Visitas ao cardápio: o aparelho de quem trabalha no sistema nunca conta (19/10/2026)
-- Quando alguém da equipe entra no sistema, o aparelho é registrado aqui. As visitas desse aparelho (inclusive as de antes do login,
-- como depois de limpar os dados do site) deixam de aparecer na contagem do Início.
create table if not exists public.cardapio_aparelhos_equipe (
  aparelho text primary key,
  criado_em timestamptz not null default now()
);
alter table public.cardapio_aparelhos_equipe enable row level security;
revoke all on public.cardapio_aparelhos_equipe from anon, authenticated;
grant all on public.cardapio_aparelhos_equipe to service_role;

create or replace function public.api_marcar_aparelho_equipe(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ap text := lower(btrim(coalesce(p->>'aparelho', '')));
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_ap !~ '^[a-z0-9]{16,40}$' then return jsonb_build_object('ok', false); end if;
  insert into cardapio_aparelhos_equipe (aparelho) values (v_ap) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.api_marcar_aparelho_equipe(jsonb) from public, anon;
grant execute on function public.api_marcar_aparelho_equipe(jsonb) to authenticated, service_role;

create or replace function public.api_visitas_cardapio_hoje(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_dia date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'hoje', (select count(*) from cardapio_visitas v where v.dia = v_dia
    and not exists (select 1 from cardapio_aparelhos_equipe e where e.aparelho = v.aparelho)));
end $$;

create or replace function public.api_registrar_visita_cardapio(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ap text := lower(btrim(coalesce(p->>'aparelho', ''))); v_dia date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_ap !~ '^[a-z0-9]{16,40}$' then return jsonb_build_object('ok', false); end if;
  if exists (select 1 from cardapio_aparelhos_equipe where aparelho = v_ap) then return jsonb_build_object('ok', true); end if;
  if (select count(*) from cardapio_visitas where dia = v_dia) >= 20000 then return jsonb_build_object('ok', true); end if;
  insert into cardapio_visitas (dia, aparelho) values (v_dia, v_ap) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;
