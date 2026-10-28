/* =====================================================================
   FUNIL DO CARDÁPIO + "CARDÁPIO HOJE" COM MAPA (v1.15)
   Cliente (sem login): cada aparelho conta uma vez por dia em cada etapa:
     entrou no cardápio → abriu um item → pôs no carrinho → abriu o finalizar → enviou o pedido.
   Sem nome, sem telefone. A localização vai só se o cliente já permitiu no aparelho,
   e o banco guarda APROXIMADA (~500 m), apagando ao fechar o caixa (fim do turno) e em 24 h.
   Equipe (Admin/Operador): toque em "Cardápio hoje" no Início → funil + mapa.
   Aparelho da equipe nunca conta.
   ===================================================================== */
(function(){
  'use strict';
  function dia_(){ try{ return dataLocalISO(new Date()); }catch(e){ return new Date().toISOString().slice(0, 10); } }
  function equipe_(){
    try{ if(typeof currentUser !== 'undefined' && currentUser) return true; }catch(e){}
    try{ return localStorage.getItem('cdAparelhoEquipe') === '1' || !!localStorage.getItem(SESSAO_KEY); }catch(e){ return false; }
  }
  function aparelho_(){
    try{
      let ap = localStorage.getItem('cdAparelhoId');
      if(!ap || !/^[a-z0-9]{16,40}$/.test(ap)){ ap = Array.from(crypto.getRandomValues(new Uint8Array(12)), b=>b.toString(16).padStart(2, '0')).join(''); localStorage.setItem('cdAparelhoId', ap); }
      return ap;
    }catch(e){ return ''; }
  }
  function feitos_(){ try{ const j = JSON.parse(localStorage.getItem('cdFunil') || '{}'); return j.d === dia_() ? j : { d: dia_(), e: {} }; }catch(e){ return { d: dia_(), e: {} }; } }
  function marcar_(j){ try{ localStorage.setItem('cdFunil', JSON.stringify(j)); }catch(e){} }

  window.cdFunil_ = function(etapa){
    try{
      if(equipe_()) return;
      const ap = aparelho_(); if(!ap) return;
      const j = feitos_();
      const pos = (window.__posCd_ && window.__posCd_()) || null;
      const precisaLocal = pos && !j.loc;
      if(j.e[etapa] && !precisaLocal) return;
      const p = { aparelho: ap, etapa: j.e[etapa] ? 'visita' : etapa };
      if(pos){ p.lat = pos.lat; p.lng = pos.lng; }
      j.e[etapa] = 1; if(pos) j.loc = 1; marcar_(j);
      sbRpcPublico_('api_cardapio_funil', { p: p }).catch(function(){ /* estatística: se falhar, o cliente não precisa saber */ });
    }catch(e){}
  };
  function envolver_(nome, etapa, depois){
    const o = window[nome]; if(typeof o !== 'function' || o.__fun) return;
    const n = function(){ const r = o.apply(this, arguments); try{ if(!depois) window.cdFunil_(etapa); }catch(e){} return r; };
    n.__fun = true; window[nome] = n;
  }
  envolver_('carregarCardapioPublico', 'visita');
  envolver_('abrirCdItemModal', 'item');
  envolver_('confirmarAddCarrinho', 'carrinho');
  envolver_('abrirCarrinhoPublico', 'finalizar');
  envolver_('mostrarLinkAcompanhamento', 'pedido');
  /* a localização chega alguns segundos depois de abrir: manda junto assim que existir (uma vez por dia) */
  setTimeout(function(){ try{ if(!equipe_() && document.getElementById('cardapioPublico') && !document.getElementById('cardapioPublico').classList.contains('hidden')) window.cdFunil_('visita'); }catch(e){} }, 9000);

  /* ---------- Pop-up "CARDÁPIO HOJE" (Admin e Operador) ---------- */
  let zoom = 13, centro = null, dados = null;
  function tile_(lat, lng, z){ const n = Math.pow(2, z), r = lat * Math.PI / 180; return { x:(lng + 180) / 360 * n, y:(1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n, n:n }; }
  function modal_(){
    let m = document.getElementById('cdHojeModal');
    if(!m){
      m = document.createElement('div'); m.className = 'modal-overlay'; m.id = 'cdHojeModal';
      m.innerHTML = '<div class="modal-box" style="max-width:560px;"><div class="modal-header"><h2>📊 CARDÁPIO HOJE</h2><button class="close-btn" type="button" aria-label="Fechar" onclick="fecharFormModal(\'cdHojeModal\')">✕</button></div><div id="cdHojeCorpo"></div></div>';
      document.body.appendChild(m);
    }
    return m;
  }
  window.abrirCardapioHoje_ = async function(){
    const m = modal_(); abrirFormModal('cdHojeModal');
    const c = document.getElementById('cdHojeCorpo');
    c.innerHTML = '<div class="obs-line">⏳ Carregando…</div>';
    try{
      const r = await apiCall('cardapioHoje', {});
      if(!r || !r.ok){ c.innerHTML = '<div class="msg warn" role="alert" style="display:block;">⚠️ ' + escH((r && r.message) || 'Não foi possível carregar agora.') + '</div>'; return; }
      dados = r; zoom = 13; centro = null; desenhar_();
    }catch(e){ c.innerHTML = '<div class="msg warn" role="alert" style="display:block;">📡 Sem conexão para carregar o cardápio de hoje.</div>'; }
  };
  function desenhar_(){
    const c = document.getElementById('cdHojeCorpo'), r = dados; if(!c || !r) return;
    const f = r.funil || {}, base = Math.max(1, Number(f.visita) || 0);
    const etapas = [['visita', 'Entraram no cardápio'], ['item', 'Abriram um item'], ['carrinho', 'Puseram no carrinho'], ['finalizar', 'Abriram o finalizar'], ['pedido', 'Enviaram o pedido']];
    const desde = r.desde ? new Date(r.desde).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit' }) : '';
    let h = '<p class="sub fs-xs" style="margin:0 0 8px;">' + (r.turno ? 'Desde a abertura do caixa (' + escH(desde) + ').' : 'Caixa fechado: últimas 24 horas.') + ' Cada aparelho conta uma vez. Aparelhos da equipe não contam.</p>';
    h += '<div>' + etapas.map(function(e, i){
      const n = Number(f[e[0]]) || 0, pct = Math.round(n / base * 100);
      const ant = i ? (Number(f[etapas[i - 1][0]]) || 0) : 0, perda = i && ant ? Math.round((1 - n / ant) * 100) : 0;
      return '<div style="margin:6px 0;"><div class="d-flex" style="justify-content:space-between;font-size:13px;"><span>' + e[1] + '</span><b>' + n + (i ? ' <span class="txt-muted" style="font-weight:400;">(' + pct + '%)</span>' : '') + '</b></div>'
        + '<div style="height:10px;background:#1d2a39;border-radius:6px;overflow:hidden;"><div style="width:' + Math.min(100, pct) + '%;height:100%;background:var(--gold,#29cbbb);"></div></div>'
        + (i && ant && perda > 0 ? '<div class="obs-line" style="font-size:11px;">' + perda + '% pararam aqui</div>' : '') + '</div>';
    }).join('') + '</div>';
    h += '<div class="obs-line mt-1">Pedidos do cardápio no período: <b>' + (Number(r.pedidosCardapio) || 0) + '</b></div>';
    const pts = r.pontos || [], ped = (r.pedidos || []).concat(r.entregues || []).concat(r.entreguesIfood || []);
    h += '<h3 style="margin:12px 0 4px;">🗺️ De onde estão acessando</h3>';
    if(!pts.length && !ped.length && !(r.semCoord || []).length){
      h += '<div class="obs-line">Ainda sem localização no período (só aparece quem permitiu a localização no celular).</div>';
    } else {
      h += '<div id="cdHojeMapa" style="position:relative;height:300px;border-radius:8px;overflow:hidden;background:#2a2a2a;touch-action:pan-x pan-y;"></div>'
        + '<div class="obs-line fs-xs mt-1"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:rgba(41,203,187,.85);"></span> visitas (aproximadas, ~500 m) &nbsp; <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:#3fb97a;"></span> entregas do sistema &nbsp; <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:#ea1d2c;"></span> entregas do iFood &nbsp; ' + (r.restaurante ? '<span style="display:inline-block;width:10px;height:10px;background:#fff;border:2px solid #111;"></span> restaurante' : '') + '</div>';
    }
    h += '<div id="cdHojeGeoMsg" class="obs-line fs-xs">' + geoTexto_() + '</div>';
    h += '<p class="obs-line fs-xs mt-2">A localização é aproximada e é apagada ao fechar o caixa (e sempre depois de 24 horas).</p>';
    h += '<div class="btnrow mt-2"><button class="ghost" type="button" onclick="abrirCardapioHoje_()">🔄 Atualizar</button></div>';
    c.innerHTML = h;
    if(pts.length || ped.length) mapa_();
    geoBuscar_();
  }
  function geoTexto_(){
    const r = dados || {}, n = Number(r.naoLocalizados) || 0, pend = (r.semCoord || []).length;
    return (pend ? '⏳ Localizando ' + pend + ' endereço(s) de entrega no mapa…' : '') + (n ? (pend ? ' ' : '') + '<span style="color:#48d8ca;">⚠️ ' + n + ' entrega(s) sem como aparecer no mapa (endereço ausente ou não encontrado).</span>' : '') + (geoErro ? ' <span style="color:#e5534b;">⚠️ ' + escH(geoErro) + '</span>' : '');
  }
  let geoErro = '', geoRodando = false;
  /* "Rua X, Bairro, nº 554 — Cidade - SP" → tenta "Rua X 554, Cidade", depois "Rua X, Cidade" (a rua toda; serve para o ponto aproximado de ~500 m) e por fim o texto original */
  function variantes_(end){
    const t = String(end || '').replace(/\s+/g, ' ').trim(), out = [];
    const cid = (t.match(/[—–]\s*([^—–-]+?)\s*(?:-\s*[A-Z]{2})?\s*$/) || [])[1] || '';
    const semCid = t.replace(/\s*[—–].*$/, '');
    const rua = semCid.split(',')[0].trim();
    const num = (semCid.match(/n[º°o.]*\s*(\d+)/i) || semCid.match(/,\s*(\d+)\b/) || [])[1] || '';
    if(rua && num) out.push(rua + ' ' + num + (cid ? ', ' + cid : ''));
    if(rua) out.push(rua + (cid ? ', ' + cid : ''));
    out.push(t);
    return out.filter(function(x, i){ return x && out.indexOf(x) === i; });
  }
  async function geoBuscar_(){
    if(geoRodando) return; const r = dados; if(!r || !(r.semCoord || []).length) return; geoRodando = true; geoErro = '';
    const rest = r.restaurante && r.restaurante.lat ? r.restaurante : null;
    try{
      for(const it of r.semCoord.slice()){
        let a = null;
        try{
          const vb = rest ? '&viewbox=' + [Number(rest.lng) - 0.25, Number(rest.lat) + 0.25, Number(rest.lng) + 0.25, Number(rest.lat) - 0.25].join(',') + '&bounded=1' : '';
          const vars = variantes_(it.endereco);
          for(let k = 0; k < vars.length && !a; k++){
            if(k) await new Promise(res=>setTimeout(res, 1100));
            const resp = await fetch('https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&countrycodes=br&accept-language=pt-BR' + vb + '&q=' + encodeURIComponent(vars[k]), { cache:'no-store' });
            if(!resp.ok) throw new Error('mapa ' + resp.status);
            const j = await resp.json(); a = j && j[0] ? { lat:Number(j[0].lat), lng:Number(j[0].lon) } : null;
          }
        }catch(e){ geoErro = 'Não consegui consultar o mapa para localizar alguns endereços agora. Toque em Atualizar para tentar de novo.'; break; }
        const sv = await apiCall('geoEnderecoSalvar', a ? { chave:it.chave, achou:true, lat:a.lat, lng:a.lng } : { chave:it.chave, achou:false });
        if(!sv || !sv.ok){ geoErro = (sv && sv.message) || 'Não consegui guardar a localização de um endereço.'; break; }
        r.semCoord = r.semCoord.filter(x=>x.chave !== it.chave);
        if(a){ const chv = it.ifood ? 'entreguesIfood' : 'entregues'; r[chv] = (r[chv] || []).concat([{ lat:Math.round(a.lat / 0.005) * 0.005, lng:Math.round(a.lng / 0.005) * 0.005, n:1 }]); } else { r.naoLocalizados = (Number(r.naoLocalizados) || 0) + 1; }
        await new Promise(res=>setTimeout(res, 1100));
      }
    } finally { geoRodando = false; }
    if(dados === r && document.getElementById('cdHojeCorpo')){ centro = null; const m = document.getElementById('cdHojeMapa'); if(m) mapa_(); const g = document.getElementById('cdHojeGeoMsg'); if(g) g.innerHTML = geoTexto_(); if(!m && ((r.entregues || []).length || (r.entreguesIfood || []).length)) desenhar_(); }
  }
  function mapa_(){
    const div = document.getElementById('cdHojeMapa'); const r = dados; if(!div || !r) return;
    const todos = (r.pontos || []).concat(r.pedidos || []).concat(r.entregues || []).concat(r.entreguesIfood || []).concat(r.restaurante && r.restaurante.lat ? [r.restaurante] : []);
    if(!centro){
      const la = todos.map(p=>Number(p.lat)), ln = todos.map(p=>Number(p.lng));
      centro = { lat:(Math.min.apply(null, la) + Math.max.apply(null, la)) / 2, lng:(Math.min.apply(null, ln) + Math.max.apply(null, ln)) / 2 };
      const span = Math.max(Math.max.apply(null, la) - Math.min.apply(null, la), Math.max.apply(null, ln) - Math.min.apply(null, ln));
      zoom = span > 1 ? 9 : span > 0.4 ? 10 : span > 0.15 ? 11 : span > 0.07 ? 12 : span > 0.03 ? 13 : 14;
    }
    const W = div.clientWidth || 340, H = div.clientHeight || 300, t = tile_(centro.lat, centro.lng, zoom);
    const cx = Math.floor(t.x), cy = Math.floor(t.y), ox = (t.x - cx) * 256, oy = (t.y - cy) * 256;
    const dxMax = Math.ceil((W / 2) / 256) + 1, dyMax = Math.ceil((H / 2) / 256) + 1;
    let h = '';
    for(let dy = -dyMax; dy <= dyMax; dy++){ const ty = cy + dy; if(ty < 0 || ty >= t.n) continue;
      for(let dx = -dxMax; dx <= dxMax; dx++){ const tx = ((cx + dx) % t.n + t.n) % t.n;
        h += '<img alt="" draggable="false" referrerpolicy="origin" src="https://tile.openstreetmap.org/' + zoom + '/' + tx + '/' + ty + '.png" style="position:absolute;width:256px;height:256px;left:' + Math.round(W / 2 - ox + dx * 256) + 'px;top:' + Math.round(H / 2 - oy + dy * 256) + 'px;">'; } }
    const xy = function(p){ const q = tile_(Number(p.lat), Number(p.lng), zoom); return { x: W / 2 + (q.x - t.x) * 256, y: H / 2 + (q.y - t.y) * 256 }; };
    (r.pontos || []).forEach(function(p){ const a = xy(p), s = Math.min(46, 14 + Math.sqrt(Number(p.n) || 1) * 8);
      h += '<div title="' + (Number(p.n) || 1) + ' aparelho(s)" style="position:absolute;left:' + (a.x - s / 2) + 'px;top:' + (a.y - s / 2) + 'px;width:' + s + 'px;height:' + s + 'px;border-radius:50%;background:rgba(41,203,187,.55);border:2px solid rgba(41,203,187,.95);color:#111;font:700 11px/1 system-ui;display:flex;align-items:center;justify-content:center;">' + ((Number(p.n) || 1) > 1 ? p.n : '') + '</div>'; });
    (r.entregues || []).forEach(function(p){ const a = xy(p); h += '<div title="' + (Number(p.n) || 1) + ' entrega(s) do sistema" style="position:absolute;left:' + (a.x - 9) + 'px;top:' + (a.y - 9) + 'px;width:18px;height:18px;border-radius:50%;background:#3fb97a;border:2px solid #fff;"></div>'; });
    (r.entreguesIfood || []).forEach(function(p){ const a = xy(p); h += '<div title="' + (Number(p.n) || 1) + ' entrega(s) do iFood" style="position:absolute;left:' + (a.x - 5) + 'px;top:' + (a.y - 5) + 'px;width:10px;height:10px;border-radius:50%;background:#ea1d2c;border:2px solid #fff;"></div>'; });
    (r.pedidos || []).forEach(function(p){ const a = xy(p); h += '<div style="position:absolute;left:' + (a.x - 6) + 'px;top:' + (a.y - 6) + 'px;width:12px;height:12px;border-radius:50%;background:#3fb97a;border:2px solid #fff;"></div>'; });
    if(r.restaurante && r.restaurante.lat){ const a = xy(r.restaurante); h += '<div title="Restaurante" style="position:absolute;left:' + (a.x - 8) + 'px;top:' + (a.y - 8) + 'px;width:16px;height:16px;background:#fff;border:3px solid #111;"></div>'; }
    h += '<div style="position:absolute;left:8px;top:8px;display:flex;flex-direction:column;gap:6px;"><button type="button" aria-label="Aproximar" onclick="cdHojeZoom_(1)" style="width:36px;height:36px;padding:0;margin:0;border-radius:8px;background:#fff;color:#111;border:1px solid #999;font-size:20px;font-weight:700;line-height:1;">+</button><button type="button" aria-label="Afastar" onclick="cdHojeZoom_(-1)" style="width:36px;height:36px;padding:0;margin:0;border-radius:8px;background:#fff;color:#111;border:1px solid #999;font-size:20px;font-weight:700;line-height:1;">−</button></div>';
    h += '<div style="position:absolute;right:0;bottom:0;background:rgba(255,255,255,.8);color:#222;font-size:12px;padding:1px 5px;">© OpenStreetMap</div>';
    div.innerHTML = h;
  }
  window.cdHojeZoom_ = function(d){ zoom = Math.max(8, Math.min(17, zoom + d)); mapa_(); };
})();
