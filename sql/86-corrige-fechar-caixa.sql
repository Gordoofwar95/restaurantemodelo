-- 86 — Fechar caixa dava "DELETE requires a WHERE clause": o gatilho que limpa os locais do cardápio ao fechar o caixa apagava sem WHERE.
create or replace function public._trg_caixa_fecha_apaga_locais() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status::text = 'Fechado' and old.status::text is distinct from 'Fechado' then delete from cardapio_locais where true; end if;
  return new;
end $$;
