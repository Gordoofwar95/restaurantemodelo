-- 82 — Gemini: o modelo gemini-3.8-flash não respondia (travava 9 s antes de trocar). Passa a usar o gemini-3.6-flash como principal.
update public.ai_config set modelo_gemini = 'gemini-3.6-flash' where modelo_gemini = 'gemini-3.8-flash';
