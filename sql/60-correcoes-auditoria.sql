-- 60 · Correções da auditoria final da versão 1.15 (25/10/2026). Pode rodar de novo sem erro.
-- "Conferir a senha" com a senha VAZIA respondia ok para o Admin (o _exige_admin deixa o Admin passar sem senha em funções antigas).
-- Desde 20/10 toda ação sensível pede a senha, inclusive do Admin: a conferência agora recusa senha vazia.
create or replace function public.api_verificar_senha_admin(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth_nivel() is null then return _negado(); end if;
  if coalesce(btrim(p->>'senha'), '') = '' then return jsonb_build_object('ok', false, 'message', 'Digite a senha.'); end if;
  return jsonb_build_object('ok', _exige_admin(p->>'senha') is not null);
end $function$;
