/* ============================================================
   CADASTRO FÁCIL — produto em 3 tipos, receita rápida, ingrediente simples, preços em lote, bebidas separadas, aviso.
   - "Preparado aqui": receita (busca por digitação, criar ingrediente na hora, copiar de outro produto). Custo = receita.
   - "Comprado pronto": estoque próprio (bebidas etc.). Custo = "paguei R$ X por N unidades".
   - "Sem controle": custo digitado.
   A receita guarda a quantidade na unidade do ingrediente (kg, l, un); a tela pede gramas/ml quando o ingrediente é kg/l.
   O banco recalcula o custo dos produtos e combos sozinho quando o preço de um ingrediente muda (gatilhos no Supabase).
   ============================================================ */
var CF_TIPO_ = { p:'receita', pp:'receita' };
var _cfEsc_ = { p:null, pp:null };
var _cfEstAba_ = 'ing';
var _cfLote_ = {};
var _cfEeUnAntes_ = '';
const CF_UN_NOME_ = { un:'unidades', kg:'kg', g:'gramas', l:'litros', ml:'ml' };
const CF_AJUDA_TIPO_ = {
  receita: 'Lanches, porções e tudo que é montado aqui. O custo sai da receita e se atualiza sozinho.',
  pronto: 'Bebidas e itens que você compra prontos. Cada venda baixa 1 do estoque e o custo sai do que você pagou.',
  manual: 'Sem receita e sem estoque. Digite o custo se souber.'
};

function cfNum_(v){ const n = Number(String(v == null ? '' : v).replace(',', '.')); return isFinite(n) ? n : 0; }
function cfVal_(id){ const el = document.getElementById(id); return el ? el.value : ''; }
function cfSet_(id, v){ const el = document.getElementById(id); if(el) el.value = (v == null ? '' : v); }
function cfNorm_(s){ return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim(); }
function cfMoeda4_(n){ return 'R$ ' + (Number(n) || 0).toLocaleString('pt-BR', { minimumFractionDigits:2, maximumFractionDigits:4 }); }
function cfQtdTxt_(n){ return (Math.round((Number(n) || 0) * 1000) / 1000).toLocaleString('pt-BR', { maximumFractionDigits:3 }); }
function cfIngr_(id){ return (estoque || []).find(e => e.id === id); }
function cfEhBebida_(estoqueId){ return (produtos || []).some(p => p.estoqueProprioIngredienteId === estoqueId); }
function cfFatorUso_(un){ return (un === 'kg' || un === 'l') ? 1000 : 1; }
function cfUnUso_(un){ return un === 'kg' ? 'g' : (un === 'l' ? 'ml' : (un || 'un')); }
function cfFator_(de, para){
  de = de || 'un'; para = para || 'un';
  if(de === para) return 1;
  const m = { 'kg>g':1000, 'g>kg':0.001, 'l>ml':1000, 'ml>l':0.001 };
  return m[de + '>' + para] || null;
}
/* ---------- QUANTIDADE EM GRAMAS / ML (mesmo jeito em adicional e em receita de produto) ----------
   Quem digita sempre pensa em g/ml/un. O banco continua guardando na unidade do estoque (kg, l, un):
   a conversão (30 g = 0,03 kg) é feita aqui, na entrada e na saída, e mostrada ao vivo embaixo do campo. */
var CF_USO_ = {
  ae: { input:'aeQtd',        un:'aeQtdUn',  chips:'aeQtdChips', resumo:'aeQtdResumo', label:'aeQtdLbl', alvo:'adicional', ing:'aeIngrediente',       preco:'aePreco' },
  ad: { input:'adQtdDesconto', un:'adQtdUn',  chips:'adQtdChips', resumo:'adQtdResumo', label:'adQtdLbl', alvo:'adicional', ing:'adIngredienteSelect', preco:'adPreco' },
  p:  { input:'pRwQtd',       un:'pRwQtdUn', chips:'pRwQtdChips', resumo:'pRwQtdResumo', label:'pRwQtdLbl', alvo:'produto' },
  pp: { input:'ppRwQtd',      un:'ppRwQtdUn', chips:'ppRwQtdChips', resumo:'ppRwQtdResumo', label:'ppRwQtdLbl', alvo:'produto' }
};
function cfUsoParaEst_(un, q){ return Math.round(cfNum_(q) / cfFatorUso_(un) * 1000) / 1000; }
function cfUsoDeEst_(un, qEst){ return Math.round(cfNum_(qEst) * cfFatorUso_(un) * 1000) / 1000; }
function cfUsoChips_(un){ const u = cfUnUso_(un); return u === 'g' ? [10, 20, 30, 50, 100] : (u === 'ml' ? [10, 30, 50, 100, 200] : [0.5, 1, 2]); }
function cfUsoIngId_(k){
  if(k === 'p' || k === 'pp') return _cfEsc_[k] || '';
  const sel = document.getElementById(CF_USO_[k].ing); return sel ? sel.value : '';
}
/* texto curto para listas: "30 g de Queijo cremoso" */
function cfUsoTexto_(ingredienteId, qEst){
  const e = cfIngr_(ingredienteId); if(!e) return '';
  return cfQtdTxt_(cfUsoDeEst_(e.unidade, qEst)) + ' ' + cfUnUso_(e.unidade) + ' de ' + e.nome;
}
function cfUsoResumo_(e, q, preco){
  const un = e.unidade || 'un', u = cfUnUso_(un), custo = cfNum_(e.custo);
  if(un === 'un'){
    return (q > 0 ? '<b>' + escH(cfQtdTxt_(q)) + ' un</b> de ' + escH(e.nome) + '. ' : '')
      + 'Este ingrediente é controlado por <b>unidade</b>. Para digitar em gramas, troque a unidade dele em Estoque para g ou kg e depois confira as quantidades nas receitas e nos adicionais (a troca de unidade para peso não converte sozinha).';
  }
  if(!(q > 0)) return 'Digite quanto de <b>' + escH(e.nome) + '</b> vai em cada ' + 'um — em <b>' + escH(u) + '</b>.';
  const qEst = cfUsoParaEst_(un, q);
  if(!(qEst > 0)) return '<span class="cf-sem">Quantidade muito pequena. O mínimo é 1 ' + escH(u) + '.</span>';
  let t = '<b>' + escH(cfQtdTxt_(q)) + ' ' + escH(u) + '</b> de ' + escH(e.nome);
  if(un !== u) t += ' · baixa <b>' + escH(cfQtdTxt_(qEst)) + ' ' + escH(un) + '</b> do estoque';
  else t += ' · baixa do estoque na mesma medida';
  if(custo > 0){
    const c = qEst * custo; t += ' · custo <b>' + formatarMoeda(c) + '</b>';
    if(preco > 0){
      const dif = Math.round((preco - c) * 100) / 100;
      if(dif < 0) t += ' · você cobra ' + formatarMoeda(preco) + ' → <span class="cf-perda">VOCÊ PERDE ' + formatarMoeda(-dif) + ' a cada adicional vendido. Aumente o preço ou diminua a quantidade.</span>';
      else if(dif === 0) t += ' · você cobra ' + formatarMoeda(preco) + ' → <span class="cf-sem">não sobra nada (lucro zero)</span>';
      else t += ' · você cobra ' + formatarMoeda(preco) + ' → lucro de <b>' + formatarMoeda(dif) + '</b> por adicional';
    }
  } else t += ' · <span class="cf-sem">ingrediente sem preço</span>';
  return t;
}
/* ---------- INGREDIENTE DO ADICIONAL: digitar e escolher (em vez de abrir a lista enorme) ----------
   O <select> original continua na página, escondido, como fonte da verdade (valor e unidade); o campo de busca só o preenche.
   Campo vazio = sem vínculo com o estoque. Digitou e não escolheu = o salvar avisa. */
var CF_ADING_ = {
  ad: { sel:'adIngredienteSelect', busca:'adIngBusca', sug:'adIngSug', qtd:'adQtdDesconto', msg:'adMsg', mudou:function(){ atualizarLabelQtdAdicional(); } },
  ae: { sel:'aeIngrediente',       busca:'aeIngBusca', sug:'aeIngSug', qtd:'aeQtd',          msg:'aeMsg', mudou:function(){ atualizarQtdAdEdit_(); } }
};
function cfAdIngSincronizar_(k){
  const c = CF_ADING_[k], sel = document.getElementById(c.sel), b = document.getElementById(c.busca), box = document.getElementById(c.sug);
  if(!sel || !b) return;
  const e = sel.value ? cfIngr_(sel.value) : null;
  b.value = e ? e.nome : ''; if(box) box.innerHTML = '';
}
function cfAdIngBuscar_(k){
  const c = CF_ADING_[k], sel = document.getElementById(c.sel), b = document.getElementById(c.busca), box = document.getElementById(c.sug);
  if(!sel || !b || !box) return;
  if(sel.value){ sel.value = ''; c.mudou(); }   // começou a digitar: desfaz a escolha até escolher outra da lista
  const q = cfNorm_(b.value);
  if(!q){ box.innerHTML = ''; return; }
  const ach = (estoque || []).filter(e => e.ativo !== false && cfNorm_(e.nome).indexOf(q) !== -1)
    .sort((a, z) => ((cfNorm_(a.nome).indexOf(q) === 0 ? 0 : 1) - (cfNorm_(z.nome).indexOf(q) === 0 ? 0 : 1)) || a.nome.localeCompare(z.nome)).slice(0, 8);
  box.innerHTML = ach.length
    ? ach.map(e => `<button type="button" class="cf-sug-item" onclick="cfAdIngEscolher_('${k}','${e.id}')">${escH(e.nome)} <span>${escH(e.unidade || 'un')}</span></button>`).join('')
    : '<div class="sub">Nenhum ingrediente com esse nome. Cadastre em Estoque.</div>';
}
function cfAdIngEscolher_(k, id){
  const c = CF_ADING_[k], sel = document.getElementById(c.sel), e = cfIngr_(id);
  if(!sel || !e) return;
  sel.value = id;
  if(sel.value !== id){ const m = document.getElementById(c.msg); if(m) showMsg(c.msg, 'Não foi possível escolher esse ingrediente. Feche e abra de novo.', 'warn'); return; }
  cfAdIngSincronizar_(k); c.mudou();
  const q = document.getElementById(c.qtd); if(q){ q.value = ''; try{ q.focus(); }catch(err){} cfUsoAtualizar_(k); }
}
function cfAdIngTecla_(ev, k){
  if(ev.key !== 'Enter') return;
  ev.preventDefault();
  const box = document.getElementById(CF_ADING_[k].sug), primeiro = box && box.querySelector('button');
  if(primeiro) primeiro.click();
}
/* digitou um nome mas não escolheu nenhum da lista */
function cfAdIngPendente_(k){
  const c = CF_ADING_[k], sel = document.getElementById(c.sel), b = document.getElementById(c.busca);
  return !!(sel && b && sel.value === '' && b.value.trim() !== '');
}
const CF_ADING_PENDENTE_MSG_ = 'Escolha o ingrediente na lista que aparece ao digitar (ou apague o campo para salvar sem vínculo com o estoque).';
/* ---------- CONFIRMAÇÃO ANTES DE SALVAR COM PREJUÍZO ---------- */
/* linhas: [{ forma, preco, custo }]; devolve true se pode salvar (sem prejuízo, ou o usuário confirmou) */
async function cfConfirmarPrejuizoLinhas_(nome, linhas, pctImp){
  pctImp = cfNum_(pctImp);
  const grupos = {};
  (linhas || []).forEach(l => {
    const pr = cfNum_(l.preco), cu = cfNum_(l.custo);
    if(!(cu > 0)) return;
    const m = Math.round((pr - cu - pr * pctImp / 100) * 100) / 100;
    if(m >= 0) return;
    const k = pr + '|' + cu;
    if(!grupos[k]) grupos[k] = { pr, cu, perda:-m, formas:[] };
    if(l.forma) grupos[k].formas.push(l.forma);
  });
  const lista = Object.keys(grupos).map(k => grupos[k]);
  if(!lista.length) return true;
  const txt = lista.map(g => '• Preço ' + formatarMoeda(g.pr) + ' · custo ' + formatarMoeda(g.cu) + ' → você perde ' + formatarMoeda(g.perda) + ' a cada venda'
    + (g.formas.length && g.formas.length <= 3 ? ' (' + g.formas.join(', ') + ')' : (g.formas.length > 3 ? ' (' + g.formas.length + ' formas de pagamento)' : ''))).join('\n');
  const imp = pctImp > 0 ? '\n\n(Já considerando o imposto de ' + String(pctImp).replace('.', ',') + '% sobre a venda.)' : '';
  return await confirmarTxt_('"' + nome + '" vai dar prejuízo com esse preço e esse custo:\n\n' + txt + imp + '\n\nSalvar mesmo assim?', 'Salvar mesmo assim', true, 'Você vai perder dinheiro', 'Voltar e corrigir');
}
/* produto ou combo: precos = resultado de montarPrecosComExcecoes (preço e custo por forma de pagamento) */
function cfConfirmarPrejuizo_(nome, precos){
  const pctImp = (typeof impostoPctHoje_ === 'function') ? impostoPctHoje_() : 0;
  const linhas = (precos || []).map(p => { const f = (typeof formasPagamento !== 'undefined' ? formasPagamento : []).find(x => x.id === p.formaPagamentoId); return { forma: f ? f.nome : '', preco:p.preco, custo:p.custo }; });
  /* se todas as formas têm o mesmo preço, não precisa listar uma por uma */
  const iguais = linhas.length > 1 && linhas.every(l => l.preco === linhas[0].preco && l.custo === linhas[0].custo);
  return cfConfirmarPrejuizoLinhas_(nome, iguais ? [{ preco:linhas[0].preco, custo:linhas[0].custo }] : linhas, pctImp);
}
/* adicional: custo = quantidade (na unidade do estoque) x custo do ingrediente */
function cfConfirmarPrejuizoAd_(nome, preco, ingredienteId, qtdEstoque){
  const e = ingredienteId ? cfIngr_(ingredienteId) : null;
  if(!e) return Promise.resolve(true);
  return cfConfirmarPrejuizoLinhas_(nome, [{ preco:preco, custo:cfNum_(qtdEstoque) * cfNum_(e.custo) }], 0);
}
/* aviso na lista de adicionais quando o custo do ingrediente passa do preço */
function cfUsoPerdaAd_(a){
  const e = a && a.ingredienteId ? cfIngr_(a.ingredienteId) : null; if(!e || !(cfNum_(e.custo) > 0)) return '';
  const c = cfNum_(a.quantidadeDesconto) * cfNum_(e.custo), p = cfNum_(a.preco);
  if(Math.round((p - c) * 100) >= 0) return '';
  return '<div class="cf-perda cf-uso-linha">PREJUÍZO de ' + formatarMoeda(c - p) + ' a cada venda (custo ' + formatarMoeda(c) + ', preço ' + formatarMoeda(p) + ')</div>';
}
function cfUsoAtualizar_(k){
  const c = CF_USO_[k]; if(!c) return;
  const $ = id => document.getElementById(id);
  const un = $(c.un), ch = $(c.chips), rs = $(c.resumo), inp = $(c.input), lb = $(c.label);
  const id = cfUsoIngId_(k), e = id ? cfIngr_(id) : null;
  if(!e){
    if(un) un.textContent = ''; if(ch){ ch.innerHTML = ''; delete ch.dataset.un; }
    if(rs) rs.innerHTML = '';
    if(lb) lb.textContent = c.alvo === 'adicional' ? 'Quanto vai em cada adicional' : 'Quantidade por unidade vendida';
    return;
  }
  const u = cfUnUso_(e.unidade);
  if(un) un.textContent = u;
  if(lb) lb.textContent = 'Quanto de ' + e.nome + ' vai em cada ' + c.alvo + ' (' + u + ')';
  if(inp) inp.placeholder = u === 'un' ? 'Ex: 1' : (u === 'ml' ? 'Ex: 50' : 'Ex: 30');
  if(ch && ch.dataset.un !== e.unidade + '|' + k){
    ch.dataset.un = e.unidade + '|' + k;
    ch.innerHTML = cfUsoChips_(e.unidade).map(v => `<button type="button" class="cf-chip" onclick="cfUsoChip_('${k}',${v})">${escH(cfQtdTxt_(v))} ${escH(u)}</button>`).join('');
  }
  const q = inp ? cfNum_(inp.value) : 0, pr = c.preco && $(c.preco) ? cfNum_($(c.preco).value) : 0;
  if(rs) rs.innerHTML = cfUsoResumo_(e, q, pr);
  if(ch) Array.from(ch.children).forEach((b, i) => b.classList.toggle('on', q > 0 && cfUsoChips_(e.unidade)[i] === q));
}
function cfUsoChip_(k, v){
  const c = CF_USO_[k], inp = c && document.getElementById(c.input); if(!inp) return;
  inp.value = String(v); cfUsoAtualizar_(k);
  try{ inp.focus(); }catch(err){}
}
/* valida e converte o campo para a unidade do estoque; devolve { ok, qtd } ou { ok:false, msg } */
function cfUsoLer_(k){
  const c = CF_USO_[k], id = cfUsoIngId_(k), e = id ? cfIngr_(id) : null;
  if(!e) return { ok:false, msg:'Escolha o ingrediente.' };
  const q = cfNum_(cfVal_(c.input));
  if(!(q > 0)) return { ok:false, msg:'Informe quanto de ' + e.nome + ' vai em cada ' + c.alvo + ' (em ' + cfUnUso_(e.unidade) + ').' };
  const qEst = cfUsoParaEst_(e.unidade, q);
  if(!(qEst > 0)) return { ok:false, msg:'Quantidade muito pequena para ' + e.nome + '. O mínimo é 1 ' + cfUnUso_(e.unidade) + '.' };
  return { ok:true, qtd:qEst };
}
function cfLista_(pre){ return pre === 'p' ? ingredientesProdutoNovo : ingredientesProdutoEdicao; }
function cfSetLista_(pre, v){ if(pre === 'p') ingredientesProdutoNovo = v; else ingredientesProdutoEdicao = v; }
function cfUsos_(estoqueId){
  const nomes = [];
  (produtoIngredientes || []).forEach(v => {
    if(v.ingredienteId !== estoqueId) return;
    const p = (produtos || []).find(x => x.id === v.produtoId);
    if(p && p.estoqueProprioIngredienteId !== estoqueId && nomes.indexOf(p.nome) === -1) nomes.push(p.nome);
  });
  return nomes;
}

/* ---------- TIPO DO PRODUTO ---------- */
function cfSetTipo(pre, t){
  if(pre === 'pp'){
    const p = (produtos || []).find(x => x.id === produtoEditandoId);
    if(p && p.estoqueProprioIngredienteId && t !== 'pronto'){ showMsg('ppMsg', 'Este produto tem estoque próprio, então continua como "Comprado pronto".', 'warn'); t = 'pronto'; }
  }
  CF_TIPO_[pre] = t;
  document.querySelectorAll('#' + pre + 'TipoBotoes [data-tipo]').forEach(b => b.classList.toggle('active', b.dataset.tipo === t));
  const aj = document.getElementById(pre + 'TipoAjuda'); if(aj) aj.textContent = CF_AJUDA_TIPO_[t] || '';
  const sr = document.getElementById(pre + 'SecReceita'), sp = document.getElementById(pre + 'SecPronto');
  if(sr) sr.style.display = t === 'receita' ? '' : 'none';
  if(sp) sp.style.display = t === 'pronto' ? '' : 'none';
  const chk = document.getElementById(pre + 'EstoqueProprioAtivo');
  if(chk){ chk.checked = (t === 'pronto'); toggleEstoqueProprioUI(pre); }
  cfAtualizarCusto(pre);
  if(pre === 'p') cfAdicionaisNovo_();
}
/* ADICIONAIS do produto novo: já vêm marcados os que a maioria dos produtos da mesma categoria tem.
   "Comprado pronto" (bebida/item pronto) vem sem nenhum. Se a pessoa mexer nos quadradinhos, vale a escolha dela. */
let _cfAdTocado_ = false;
function cfAdicionaisSugeridos_(categoria){
  const prods = (produtos || []).filter(p => p.categoria === categoria && p.ativo !== false && !p.estoqueProprioIngredienteId);
  if(!categoria || !prods.length) return [];
  const ids = {}; prods.forEach(p => { ids[p.id] = 1; });
  const cont = {};
  (produtoAdicionais || []).forEach(pa => { if(ids[pa.produtoId]) cont[pa.adicionalId] = (cont[pa.adicionalId] || 0) + 1; });
  const ativos = {}; (adicionais || []).forEach(a => { if(a.ativo !== false) ativos[a.id] = 1; });
  return Object.keys(cont).filter(id => ativos[id] && cont[id] * 2 >= prods.length);
}
function cfAdicionaisNovo_(){
  const nota = document.getElementById('pAdicionaisNota');
  if(_cfAdTocado_) return;
  const cat = (document.getElementById('pCategoria') || {}).value || '';
  const pronto = CF_TIPO_.p === 'pronto', ids = pronto ? [] : cfAdicionaisSugeridos_(cat);
  if(typeof renderAdicionaisChecklist === 'function') renderAdicionaisChecklist('pAdicionaisLista', ids);
  if(nota) nota.textContent = pronto ? 'Produto comprado pronto (ex.: bebida) vem sem adicionais.'
    : (ids.length ? ids.length + ' marcado(s) automaticamente: são os que os outros produtos desta categoria têm. Desmarque o que não vale para este.' : '');
}
(function(){
  const ligar = () => {
    const cat = document.getElementById('pCategoria'), box = document.getElementById('pAdicionaisLista');
    if(cat && !cat._cfAd){ cat._cfAd = 1; cat.addEventListener('change', cfAdicionaisNovo_); }
    if(box && !box._cfAd){ box._cfAd = 1; box.addEventListener('change', e => { if(e.target && e.target.type === 'checkbox'){ _cfAdTocado_ = true; const n = document.getElementById('pAdicionaisNota'); if(n) n.textContent = ''; } }); }
  };
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ligar); else ligar();
})();
function cfIniciarProduto(pre, p){
  let t = CF_TIPO_[pre] || 'receita';
  if(p){
    if(p.estoqueProprioIngredienteId) t = 'pronto';
    else if((produtoIngredientes || []).some(v => v.produtoId === p.id)) t = 'receita';
    else t = cfNum_(precoDisplayProduto(p.id).custo) > 0 ? 'manual' : 'receita';
    const e = p.estoqueProprioIngredienteId ? cfIngr_(p.estoqueProprioIngredienteId) : null;
    cfSet_(pre + 'PrValor', e && cfNum_(e.custo) > 0 ? cfNum_(e.custo) : '');
    cfSet_(pre + 'PrQtd', e && cfNum_(e.custo) > 0 ? 1 : '');
  }
  _cfEsc_[pre] = null; cfSet_(pre + 'RwBusca', ''); cfSet_(pre + 'RwQtd', '');
  if(!p){ try{ showMsg(pre + 'Msg', '', ''); }catch(err){} }
  if(pre === 'p' && !p) _cfAdTocado_ = false;
  const sug = document.getElementById(pre + 'RwSug'); if(sug) sug.innerHTML = '';
  cfRwMostrarEscolhido_(pre); cfRwPopularCopiar(pre); cfRwRender(pre); cfSetTipo(pre, t); cfCompleto_(pre);
}
/* custo da receita e do item pronto */
function cfCustoReceita_(pre){
  return Math.round(cfLista_(pre).reduce((s, it) => { const e = cfIngr_(it.ingredienteId); return s + cfNum_(it.quantidadePorUnidade) * (e ? cfNum_(e.custo) : 0); }, 0) * 100) / 100;
}
function cfCustoPronto_(pre){
  const v = cfNum_(cfVal_(pre + 'PrValor')), q = cfNum_(cfVal_(pre + 'PrQtd'));
  if(!(v > 0)) return 0;
  return Math.round((q > 0 ? v / q : v) * 10000) / 10000;
}
function cfAtualizarCusto(pre){
  const t = CF_TIPO_[pre], c = document.getElementById(pre + 'Custo'), nota = document.getElementById(pre + 'CustoNota');
  if(!c) return;
  if(t === 'receita'){
    c.value = cfLista_(pre).length ? cfCustoReceita_(pre).toFixed(2) : '';
    c.readOnly = true;
    if(nota) nota.textContent = cfLista_(pre).length ? 'Calculado pela receita. Muda sozinho quando o preço de um ingrediente muda.' : 'Monte a receita acima: o custo aparece aqui sozinho.';
  } else if(t === 'pronto'){
    const cu = cfCustoPronto_(pre);
    c.value = cu > 0 ? cu.toFixed(2) : ''; c.readOnly = true;
    if(nota) nota.textContent = cu > 0 ? ('Calculado pelo que você pagou: ' + cfMoeda4_(cu) + ' por unidade.') : 'Informe quanto pagou e por quantas unidades.';
  } else {
    c.readOnly = false;
    if(nota) nota.textContent = 'Sem receita: digite o custo se souber (em branco = custo não informado).';
  }
  cfAtualizarMargem(pre);
}
/* ---------- LUCRO OU PREJUÍZO EM TEXTO CLARO (produto, combo, adicional, lista) ---------- */
/* Fase 8.2: preço sugerido para ~50% de lucro (já descontado o imposto); só sugere, quem decide é o dono */
function cfPrecoSugerido_(custo, pctImp){
  custo = cfNum_(custo); pctImp = cfNum_(pctImp);
  const f = 1 - 0.5 - pctImp / 100; if(!(custo > 0) || !(f > 0.1)) return 0;
  return Math.ceil(custo / f * 2) / 2; /* arredonda para cima de 50 em 50 centavos */
}
function cfUsarPrecoSug_(pre, v){ cfSet_(pre + 'Preco', Number(v).toFixed(2)); cfAtualizarMargem(pre); }
function cfSugestaoHtml_(preco, custo, pctImp, pre){
  const sug = cfPrecoSugerido_(custo, pctImp); if(!sug || !pre) return '';
  const m = cfNum_(preco) - cfNum_(custo) - cfNum_(preco) * cfNum_(pctImp) / 100, pct = cfNum_(preco) > 0 ? m / cfNum_(preco) * 100 : -1;
  if(pct >= 40) return '';
  return ' <span class="sub">Sugestão: ' + formatarMoeda(sug) + ' para uns 50% de lucro.</span> <button type="button" class="ghost" style="min-height:32px;padding:2px 10px;" onclick="cfUsarPrecoSug_(\'' + pre + '\',' + sug + ')">Usar</button>';
}
function cfMargemHtml_(preco, custo, pctImp, pre){
  preco = cfNum_(preco); custo = cfNum_(custo); pctImp = cfNum_(pctImp);
  if(!(custo > 0)) return 'custo não informado';
  const m = Math.round((preco - custo - preco * pctImp / 100) * 100) / 100, pct = preco > 0 ? (m / preco * 100) : 0;
  const imp = pctImp > 0 ? ' · já tirado o imposto de ' + String(pctImp).replace('.', ',') + '%' : '';
  const sg = cfSugestaoHtml_(preco, custo, pctImp, pre);
  if(m < 0) return '<span class="cf-perda">PREJUÍZO de ' + formatarMoeda(-m) + ' a cada venda (' + pct.toFixed(0) + '%). Com esse preço você perde dinheiro: aumente o preço ou reduza o custo.</span>' + imp + sg;
  if(m === 0) return '<span class="cf-sem">sem lucro (R$ 0,00): você só cobre o custo</span>' + imp + sg;
  return 'lucro de <b>' + formatarMoeda(m) + '</b> (' + pct.toFixed(0) + '%)' + imp + sg;
}
function cfAtualizarMargem(pre){
  const el = document.getElementById(pre + 'MargemPreview'); if(!el) return;
  const preco = cfNum_(cfVal_(pre + 'Preco')), custo = cfNum_(cfVal_(pre + 'Custo'));
  /* imposto sobre a venda (alíquota do mês) sai da margem; o custo do produto continua só ingredientes/compra */
  const pctImp = (typeof impostoPctHoje_ === 'function') ? impostoPctHoje_() : 0;
  el.innerHTML = cfMargemHtml_(preco, custo, pctImp, pre);
  cfCompleto_(pre);
}
/* Fase 8.2: aviso "produto completo?" (só informa; nunca trava o salvar) */
function cfCompleto_(pre){
  const el = document.getElementById(pre + 'Completo'); if(!el) return;
  const falta = [];
  if(!cfVal_(pre + 'Nome').trim()) falta.push('nome');
  if(!(cfNum_(cfVal_(pre + 'Preco')) > 0)) falta.push('preço de venda');
  if(!(cfNum_(cfVal_(pre + 'Custo')) > 0)) falta.push('custo (a margem só aparece com ele)');
  const sf = document.getElementById(pre + 'Foto'); const temFoto = (sf && sf.files && sf.files[0]) || (pre === 'pp' && (produtos || []).some(x => x.id === produtoEditandoId && x.fotoUrl));
  el.innerHTML = falta.length ? '⚠️ Para ficar completo falta: ' + falta.join(', ') + '.' + (temFoto ? '' : ' Foto é opcional.') : '✅ Produto completo' + (temFoto ? '.' : ' (a foto é opcional).');
}
/* custo enviado junto com o estoque próprio ("Comprado pronto") */
function cfCustoEstoqueProprio(pre){ return cfCustoPronto_(pre); }

/* ---------- RECEITA: busca, criar, adicionar, copiar ---------- */
function cfRwBuscar(pre){
  const txt = cfVal_(pre + 'RwBusca').trim(), q = cfNorm_(txt), box = document.getElementById(pre + 'RwSug');
  _cfEsc_[pre] = null; cfRwMostrarEscolhido_(pre);
  if(!box) return;
  if(!q){ box.innerHTML = ''; return; }
  const lista = (estoque || []).filter(e => e.ativo !== false && !cfEhBebida_(e.id));
  const ach = lista.filter(e => cfNorm_(e.nome).indexOf(q) !== -1)
    .sort((a, b) => ((cfNorm_(a.nome).indexOf(q) === 0 ? 0 : 1) - (cfNorm_(b.nome).indexOf(q) === 0 ? 0 : 1)) || a.nome.localeCompare(b.nome)).slice(0, 6);
  const exato = lista.some(e => cfNorm_(e.nome) === q);
  box.innerHTML = ach.map(e => `<button type="button" class="cf-sug-item" onclick="cfRwEscolher('${pre}','${e.id}')">${escH(e.nome)} <span>${escH(e.unidade || 'un')}${cfNum_(e.custo) > 0 ? ' · ' + cfMoeda4_(e.custo) + '/' + escH(e.unidade || 'un') : ' · sem preço'}</span></button>`).join('')
    + (exato ? '' : `<button type="button" class="cf-sug-item cf-criar" onclick="cfRwNovo('${pre}')">+ criar “${escH(txt)}”</button>`);
}
function cfRwEscolher(pre, id){
  _cfEsc_[pre] = id; const e = cfIngr_(id);
  cfSet_(pre + 'RwBusca', e ? e.nome : '');
  const box = document.getElementById(pre + 'RwSug'); if(box) box.innerHTML = '';
  cfRwMostrarEscolhido_(pre);
  const q = document.getElementById(pre + 'RwQtd'); if(q){ q.value = ''; try{ q.focus(); }catch(err){} }
}
function cfRwMostrarEscolhido_(pre){
  const e = _cfEsc_[pre] ? cfIngr_(_cfEsc_[pre]) : null, lbl = document.getElementById(pre + 'RwQtdLbl'), q = document.getElementById(pre + 'RwQtd');
  if(lbl) lbl.textContent = e ? ('Quanto de ' + e.nome + ' vai em cada um (' + cfUnUso_(e.unidade) + ')') : 'Quantidade por unidade vendida';
  if(q) q.placeholder = e ? (cfUnUso_(e.unidade) === 'un' ? 'Ex: 1' : 'Ex: 150') : 'Qtd';
  try{ cfUsoAtualizar_(pre); }catch(err){}
}
function cfRwNovo(pre){
  const nome = cfVal_(pre + 'RwBusca').trim(), box = document.getElementById(pre + 'RwSug');
  if(!nome || !box) return;
  box.innerHTML = `<div class="cf-novo">
    <b>Novo ingrediente: ${escH(nome)}</b>
    <label for="${pre}NvUn">Como você compra</label>
    <select id="${pre}NvUn" onchange="cfRwNovoUn('${pre}')"><option value="kg">Por quilo (kg)</option><option value="un">Por unidade (un)</option><option value="l">Por litro (l)</option><option value="g">Por grama (g)</option><option value="ml">Por mililitro (ml)</option></select>
    <div class="row2">
      <div><label for="${pre}NvValor">Paguei (R$)</label><input type="number" id="${pre}NvValor" step="0.01" min="0" inputmode="decimal" placeholder="Ex: 40"></div>
      <div><label for="${pre}NvQtd" id="${pre}NvQtdLbl">por quantos kg</label><input type="number" id="${pre}NvQtd" step="0.001" min="0" inputmode="decimal" value="1"></div>
    </div>
    <div class="btnrow"><button type="button" class="small-gold" onclick="cfRwCriar('${pre}')">Criar e usar na receita</button><button type="button" class="ghost" onclick="document.getElementById('${pre}RwSug').innerHTML=''">Cancelar</button></div>
    <div class="msg" id="${pre}NvMsg"></div>
  </div>`;
}
function cfRwNovoUn(pre){ const l = document.getElementById(pre + 'NvQtdLbl'); if(l) l.textContent = 'por quantos ' + (CF_UN_NOME_[cfVal_(pre + 'NvUn')] || ''); }
async function cfRwCriar(pre){
  const nome = cfVal_(pre + 'RwBusca').trim(), unidade = cfVal_(pre + 'NvUn') || 'un';
  const v = cfNum_(cfVal_(pre + 'NvValor')), q = cfNum_(cfVal_(pre + 'NvQtd'));
  if(!nome){ showMsg(pre + 'NvMsg', 'Digite o nome do ingrediente.', 'warn'); return; }
  const custo = v > 0 ? Math.round((q > 0 ? v / q : v) * 10000) / 10000 : 0;
  try{
    const r = await apiCall('addIngrediente', { nome, quantidade:0, minimo:0, unidade, custo });
    if(r && r.estoque) estoque = r.estoque;
    if(r && r.movimentacoesEstoque) movimentacoesEstoque = r.movimentacoesEstoque;
    if(!r || !r.ok){ showMsg(pre + 'NvMsg', (r && r.message) || 'Não foi possível criar.', 'warn'); return; }
    salvarCache();
    const e = (estoque || []).find(x => cfNorm_(x.nome) === cfNorm_(nome));
    try{ renderEstoque(); popularSelectIngredientes('pIngredienteSelect'); popularSelectIngredientes('ppIngredienteSelect'); popularSelectAdicionalIngrediente(); }catch(err){}
    if(e) cfRwEscolher(pre, e.id);
    showMsg(pre + 'Msg', 'Ingrediente "' + nome + '" criado' + (custo > 0 ? '' : ' (sem preço: dê o preço depois em Estoque → Preços em lote)') + '. Agora informe a quantidade.', 'ok');
  }catch(err){ showMsg(pre + 'NvMsg', 'Sem conexão. Tente de novo.', 'warn'); }
}
function cfRwAdicionar(pre){
  const id = _cfEsc_[pre], e = id ? cfIngr_(id) : null;
  if(!e){ showMsg(pre + 'Msg', 'Escolha um ingrediente da lista (ou toque em "+ criar").', 'warn'); return; }
  const lido = cfUsoLer_(pre);
  if(!lido.ok){ showMsg(pre + 'Msg', lido.msg, 'warn'); return; }
  const qtdEst = lido.qtd;
  const lista = cfLista_(pre).slice(), ja = lista.find(x => x.ingredienteId === id);
  if(ja){ ja.quantidadePorUnidade = qtdEst; showMsg(pre + 'Msg', e.nome + ' já estava na receita: quantidade trocada.', 'ok'); }
  else lista.push({ ingredienteId:id, ingredienteNome:e.nome, quantidadePorUnidade:qtdEst, unidade:e.unidade || 'un' });
  cfSetLista_(pre, lista);
  _cfEsc_[pre] = null; cfSet_(pre + 'RwBusca', ''); cfSet_(pre + 'RwQtd', ''); cfRwMostrarEscolhido_(pre);
  cfRwRender(pre);
  const b = document.getElementById(pre + 'RwBusca'); if(b){ try{ b.focus(); }catch(err){} }
}
function cfRwRemover(pre, idx){ const l = cfLista_(pre).slice(); l.splice(idx, 1); cfSetLista_(pre, l); cfRwRender(pre); }
function cfRwRender(pre){
  const box = document.getElementById(pre + 'IngredientesLista'); if(!box) return;
  const lista = cfLista_(pre); let semPreco = 0;
  box.innerHTML = lista.map((it, idx) => {
    const e = cfIngr_(it.ingredienteId), un = (e && e.unidade) || it.unidade || 'un', custoU = e ? cfNum_(e.custo) : 0;
    const qUso = cfNum_(it.quantidadePorUnidade) * cfFatorUso_(un);
    if(!(custoU > 0)) semPreco++;
    const linha = custoU > 0 ? formatarMoeda(cfNum_(it.quantidadePorUnidade) * custoU) : '<span class="cf-sem">sem preço</span>';
    return `<div class="ingrediente-row"><span>${cfQtdTxt_(qUso)} ${escH(cfUnUso_(un))} de ${escH((e && e.nome) || it.ingredienteNome || '?')} · ${linha}</span><button type="button" class="rm-row" aria-label="Tirar da receita" onclick="cfRwRemover('${pre}',${idx})">✕</button></div>`;
  }).join('') || '<div class="notif-empty">Nenhum ingrediente na receita ainda.</div>';
  const tot = document.getElementById(pre + 'RwTotal');
  if(tot) tot.innerHTML = lista.length ? ('Custo da receita: <b>' + formatarMoeda(cfCustoReceita_(pre)) + '</b>' + (semPreco ? ' · <span class="cf-sem">' + semPreco + ' ingrediente(s) sem preço</span>' : '')) : '';
  cfAtualizarCusto(pre);
}
function cfRwPopularCopiar(pre){
  const sel = document.getElementById(pre + 'RwCopiar'); if(!sel) return;
  const atual = pre === 'pp' ? produtoEditandoId : null;
  const com = (produtos || []).filter(p => p.id !== atual && (produtoIngredientes || []).some(v => v.produtoId === p.id && v.ingredienteId !== p.estoqueProprioIngredienteId))
    .sort((a, b) => a.nome.localeCompare(b.nome));
  sel.innerHTML = '<option value="">📋 Copiar receita de outro produto…</option>' + com.map(p => `<option value="${p.id}">${escH(p.nome)}</option>`).join('');
  sel.style.display = com.length ? '' : 'none';
}
async function cfRwCopiar(pre, prodId){
  const sel = document.getElementById(pre + 'RwCopiar');
  if(!prodId) return;
  const p = (produtos || []).find(x => x.id === prodId);
  if(p && cfLista_(pre).length && !await confirmarTxt_('Trocar a receita atual pela de "' + p.nome + '"? Depois você ajusta o que for diferente.')){ if(sel) sel.value = ''; return; }
  const nova = (produtoIngredientes || []).filter(v => v.produtoId === prodId && (!p || v.ingredienteId !== p.estoqueProprioIngredienteId))
    .map(v => { const e = cfIngr_(v.ingredienteId); return { ingredienteId:v.ingredienteId, ingredienteNome:(e && e.nome) || v.ingredienteNome, quantidadePorUnidade:cfNum_(v.quantidadePorUnidade), unidade:(e && e.unidade) || 'un' }; });
  cfSetLista_(pre, nova); if(sel) sel.value = '';
  cfRwRender(pre);
  showMsg(pre + 'Msg', 'Receita copiada de "' + (p ? p.nome : '') + '". Ajuste o que for diferente.', 'ok');
}
/* o que vai para o servidor ao salvar o produto */
function cfIngredientesParaSalvar(pre){ return CF_TIPO_[pre] === 'receita' ? cfLista_(pre) : []; }

/* ---------- COMBO: custo = soma dos produtos ---------- */
function cfCustoCombo(pre){
  const lista = pre === 'ko' ? itensComboNovo : itensComboEdicao, c = document.getElementById(pre + 'Custo'); if(!c) return;
  let nota = document.getElementById(pre + 'CustoNota');
  if(!nota){ nota = document.createElement('p'); nota.className = 'sub'; nota.id = pre + 'CustoNota'; const row = c.closest('.row2') || c.parentNode; row.parentNode.insertBefore(nota, row.nextSibling); }
  if(lista && lista.length){
    const _q = pre === 'ko' ? escolhaQtdNovo : escolhaQtdEdicao, _cu = it => cfNum_(precoDisplayProduto(it.produtoId).custo);
    const v = lista.filter(it=>!it.escolha).reduce((s, it) => s + cfNum_(it.quantidade) * _cu(it), 0) + (_q||0) * Math.max(0, ...lista.filter(it=>it.escolha).map(_cu));
    c.value = (Math.round(v * 100) / 100).toFixed(2); c.readOnly = true;
    nota.textContent = 'Custo = soma dos produtos do combo. Muda sozinho quando o custo deles muda.';
  } else { c.readOnly = false; nota.textContent = ''; }
  if(pre === 'ko'){ try{ atualizarMargemPreviewCombo(); }catch(err){} }
}

/* ---------- INGREDIENTE: "paguei R$ X por N" ---------- */
function cfAbrirNovoIngrediente(){
  ['eNome','eCompraValor','eCompraQtd','eCusto','eQtd','eMin'].forEach(id => cfSet_(id, ''));
  cfSet_('eUnidade', 'un'); cfIngAtualizar('e'); showMsg('eMsg', '', '');
  abrirFormModal('ingredienteNovoModal');
}
function cfIngAtualizar(pre, digitouCusto){
  const un = cfVal_(pre + 'Unidade') || 'un';
  const lbl = document.getElementById(pre + 'CompraQtdLbl'); if(lbl) lbl.textContent = 'por quantos ' + (CF_UN_NOME_[un] || un);
  const cl = document.getElementById(pre + 'CustoLbl'); if(cl) cl.textContent = 'Custo por ' + un + ' (R$)';
  if(!digitouCusto){
    const v = cfNum_(cfVal_(pre + 'CompraValor')), q = cfNum_(cfVal_(pre + 'CompraQtd'));
    if(v > 0) cfSet_(pre + 'Custo', Math.round((q > 0 ? v / q : v) * 10000) / 10000);
    else if(pre === 'e') cfSet_('eCusto', '');
  }
  const c = cfNum_(cfVal_(pre + 'Custo')), nota = document.getElementById(pre + 'CustoNota');
  if(nota) nota.textContent = c > 0 ? ('Custo: ' + cfMoeda4_(c) + ' por ' + un + (un === 'kg' || un === 'l' ? ' (= ' + cfMoeda4_(c / 1000) + ' por ' + cfUnUso_(un) + ')' : '')) : 'Informe quanto pagou para o sistema calcular o custo.';
}
function cfEeAbrir(i){ _cfEeUnAntes_ = (i && i.unidade) || 'un'; cfSet_('eeCompraValor', ''); cfSet_('eeCompraQtd', ''); const a = document.getElementById('eeUnidadeAviso'); if(a) a.textContent = ''; cfIngAtualizar('ee', true); }
function cfEeUnidadeMudou(){
  const id = cfVal_('eeId'), novo = cfVal_('eeUnidade'), aviso = document.getElementById('eeUnidadeAviso');
  const antes = _cfEeUnAntes_ || 'un', f = cfFator_(antes, novo), usos = cfUsos_(id);
  if(novo === antes){ if(aviso) aviso.textContent = ''; }
  else if(f){
    // mostra os números já convertidos; ao salvar, o banco converte também as receitas
    const i = cfIngr_(id) || {};
    cfSet_('eeQtd', Math.round(cfNum_(i.quantidade) * f * 1000) / 1000);
    cfSet_('eeMin', Math.round(cfNum_(i.minimo) * f * 1000) / 1000);
    cfSet_('eeCusto', Math.round(cfNum_(i.custo) / f * 10000) / 10000);
    if(aviso) aviso.textContent = 'Convertido de ' + antes + ' para ' + novo + ': estoque, mínimo e custo já ajustados' + (usos.length ? '; as receitas serão convertidas ao salvar.' : '.');
  } else if(aviso){
    aviso.textContent = usos.length ? ('⚠️ Trocar de ' + antes + ' para ' + novo + ' não converte sozinho. Revise a quantidade deste ingrediente na receita de: ' + usos.join(', ') + '.') : ('Trocar de ' + antes + ' para ' + novo + ': confira "Tenho agora" e o custo.');
  }
  cfIngAtualizar('ee', true);
}
/* antes de salvar a edição: troca de unidade compatível vai primeiro pelo banco (converte receitas e estoque sem lançar "ajuste") */
async function cfEeAntesDeSalvar(){
  const id = cfVal_('eeId'), novo = cfVal_('eeUnidade'), antes = _cfEeUnAntes_ || 'un';
  if(novo === antes) return true;
  const f = cfFator_(antes, novo), usos = cfUsos_(id);
  if(!f){
    if(usos.length && !await confirmarTxt_('Este ingrediente está na receita de: ' + usos.join(', ') + '.\n\nTrocar de ' + antes + ' para ' + novo + ' NÃO converte as quantidades. Depois de salvar, abra essas receitas e confira.\n\nContinuar?', 'Trocar a unidade', false, 'Unidade sem conversão')) return false;
    return true;
  }
  const r = await apiCall('salvarPrecosLote', { itens:[{ id, unidade:novo, custo:cfNum_(cfVal_('eeCusto')) }] });
  if(!r || !r.ok){ showMsg('eeMsg', (r && r.message) || 'Não foi possível trocar a unidade.', 'warn'); return false; }
  cfAplicarRespostaCustos_(r);
  _cfEeUnAntes_ = novo;
  return true;
}
function cfAplicarRespostaCustos_(r){
  if(!r) return;
  if(r.estoque) estoque = r.estoque;
  if(r.produtoPrecos) produtoPrecos = r.produtoPrecos;
  if(r.comboPrecos) comboPrecos = r.comboPrecos;
  if(r.produtoIngredientes) produtoIngredientes = r.produtoIngredientes;
  if(r.adicionais) adicionais = r.adicionais;
  if(r.movimentacoesEstoque) movimentacoesEstoque = r.movimentacoesEstoque;
  salvarCache();
}
function cfRenderTudo_(){
  ['renderEstoque','renderProdutos','renderCombos','renderMovimentacoesEstoque','renderNotificacoes'].forEach(fn => { try{ if(typeof window[fn] === 'function') window[fn](); }catch(err){} });
  try{ popularSelectProdutos(); popularSelectCombos(); }catch(err){}
}

/* ---------- PREÇOS EM LOTE ---------- */
function cfLoteItens_(){ return (estoque || []).filter(e => e.ativo !== false && !cfEhBebida_(e.id)).slice().sort((a, b) => a.nome.localeCompare(b.nome)); }
function cfAbrirLote(){
  _cfLote_ = {};
  const chk = document.getElementById('plSoSemPreco');
  if(chk) chk.checked = cfLoteItens_().some(e => !(cfNum_(e.custo) > 0));
  cfSet_('plBusca', ''); showMsg('plMsg', '', '');
  cfLoteRender(); abrirFormModal('precosLoteModal');
}
function cfLoteRender(){
  const box = document.getElementById('plLista'); if(!box) return;
  const so = !!(document.getElementById('plSoSemPreco') || {}).checked, q = cfNorm_(cfVal_('plBusca'));
  const lista = cfLoteItens_().filter(e => (!so || !(cfNum_(e.custo) > 0) || _cfLote_[e.id]) && (!q || cfNorm_(e.nome).indexOf(q) !== -1));
  box.innerHTML = lista.length ? lista.map(e => {
    const st = _cfLote_[e.id] || { unidade:e.unidade || 'un', valor:'', qtd:'' };
    return `<div class="cf-lote-row">
      <div class="cf-lote-nome"><b>${escH(e.nome)}</b><span>${cfNum_(e.custo) > 0 ? 'hoje: ' + cfMoeda4_(e.custo) + ' por ' + escH(e.unidade || 'un') : '<span class="cf-sem">sem preço</span>'}</span></div>
      <div class="cf-lote-campos">
        <select aria-label="Como compra ${escH(e.nome)}" onchange="cfLoteMudar('${e.id}','unidade',this.value)">${['un','kg','g','l','ml'].map(u => `<option value="${u}"${u === st.unidade ? ' selected' : ''}>${u}</option>`).join('')}</select>
        <input type="number" min="0" step="0.01" inputmode="decimal" placeholder="Paguei R$" aria-label="Quanto pagou por ${escH(e.nome)}" value="${escH(st.valor)}" oninput="cfLoteMudar('${e.id}','valor',this.value)">
        <input type="number" min="0" step="0.001" inputmode="decimal" placeholder="por 1" aria-label="Por quanto de ${escH(e.nome)}" value="${escH(st.qtd)}" oninput="cfLoteMudar('${e.id}','qtd',this.value)">
      </div>
      <div class="cf-lote-res" id="plRes_${e.id}">${cfLoteRes_(e, st)}</div>
    </div>`;
  }).join('') : '<div class="notif-empty">' + (so ? 'Todos os ingredientes já têm preço. Desmarque "só sem preço" para ver todos.' : 'Nenhum ingrediente encontrado.') + '</div>';
}
function cfLoteMudar(id, campo, v){
  const e = cfIngr_(id); if(!e) return;
  const st = _cfLote_[id] || (_cfLote_[id] = { unidade:e.unidade || 'un', valor:'', qtd:'' });
  st[campo] = v;
  const el = document.getElementById('plRes_' + id); if(el) el.innerHTML = cfLoteRes_(e, st);
}
function cfLoteRes_(e, st){
  const v = cfNum_(st.valor), q = cfNum_(st.qtd) || 1, partes = [];
  if(v > 0) partes.push('= ' + cfMoeda4_(v / q) + ' por ' + st.unidade);
  if(st.unidade !== (e.unidade || 'un')){
    if(cfFator_(e.unidade, st.unidade)) partes.push('as receitas são convertidas de ' + (e.unidade || 'un') + ' para ' + st.unidade);
    else { const u = cfUsos_(e.id); partes.push(u.length ? '⚠️ revise a quantidade na receita de: ' + escH(u.join(', ')) : 'unidade trocada'); }
  }
  return partes.join(' · ');
}
async function cfLoteSalvar(){
  const itens = [];
  Object.keys(_cfLote_).forEach(id => {
    const e = cfIngr_(id); if(!e) return;
    const st = _cfLote_[id], it = { id }; let mudou = false;
    if(st.unidade && st.unidade !== (e.unidade || 'un')){ it.unidade = st.unidade; mudou = true; }
    const v = cfNum_(st.valor), q = cfNum_(st.qtd) || 1;
    if(v > 0){ it.custo = Math.round(v / q * 10000) / 10000; mudou = true; }
    if(mudou) itens.push(it);
  });
  if(!itens.length){ showMsg('plMsg', 'Nada para salvar: preencha "Paguei R$" de algum ingrediente.', 'warn'); return; }
  const revisar = itens.filter(it => it.unidade && !cfFator_((cfIngr_(it.id) || {}).unidade, it.unidade) && cfUsos_(it.id).length);
  if(revisar.length && !await confirmarTxt_('Alguns ingredientes trocaram de unidade sem conversão automática (ex.: un → kg):\n• ' + revisar.map(it => (cfIngr_(it.id) || {}).nome).join('\n• ') + '\n\nDepois de salvar, confira a quantidade deles nas receitas. Continuar?', 'Continuar', false, 'Confira as receitas')) return;
  const btn = document.getElementById('plBtn'); if(btn) btn.disabled = true;
  try{
    const r = await apiCall('salvarPrecosLote', { itens });
    if(r && r.ok){ cfAplicarRespostaCustos_(r); _cfLote_ = {}; cfLoteRender(); cfRenderTudo_(); showMsg('plMsg', r.message || 'Preços salvos.', 'ok'); }
    else showMsg('plMsg', (r && r.message) || 'Não foi possível salvar.', 'warn');
  }catch(err){ showMsg('plMsg', 'Sem conexão. Confira os preços antes de tentar de novo.', 'warn'); }
  finally{ if(btn) btn.disabled = false; }
}

/* ---------- ESTOQUE: Ingredientes × Bebidas e itens prontos ---------- */
function cfEstoqueAba(a){
  _cfEstAba_ = a === 'beb' ? 'beb' : 'ing';
  const bi = document.getElementById('estAbaIng'), bb = document.getElementById('estAbaBeb');
  if(bi) bi.classList.toggle('active', _cfEstAba_ === 'ing');
  if(bb) bb.classList.toggle('active', _cfEstAba_ === 'beb');
  const n = document.getElementById('estNovoIngBox'), h = document.getElementById('estBebAjuda');
  if(n) n.style.display = _cfEstAba_ === 'ing' ? '' : 'none';
  if(h) h.style.display = _cfEstAba_ === 'beb' ? '' : 'none';
  try{ renderEstoque(); }catch(err){}
}
function cfEstoqueFiltro(i){ return _cfEstAba_ === 'beb' ? cfEhBebida_(i.id) : !cfEhBebida_(i.id); }
function cfEstoqueContagem_(){
  const ing = (estoque || []).filter(i => !cfEhBebida_(i.id)).length, beb = (estoque || []).length - ing;
  const bi = document.getElementById('estAbaIng'), bb = document.getElementById('estAbaBeb');
  if(bi) bi.textContent = 'Ingredientes (' + ing + ')';
  if(bb) bb.textContent = 'Bebidas e itens prontos (' + beb + ')';
}
function cfCustoLinhaEstoque(i){
  return cfNum_(i.custo) > 0 ? (cfMoeda4_(i.custo) + ' por ' + escH(i.unidade || 'un')) : '<span class="cf-sem">sem preço</span>';
}

/* ---------- AVISO DE CADASTRO INCOMPLETO ---------- */
function cfProdutosSemCusto_(){ return (produtos || []).filter(p => p.ativo !== false && !(cfNum_(precoDisplayProduto(p.id).custo) > 0)); }
function cfAvisos(){
  const ingSem = (estoque || []).filter(e => e.ativo !== false && !cfEhBebida_(e.id) && !(cfNum_(e.custo) > 0)).length;
  const bebSem = (estoque || []).filter(e => e.ativo !== false && cfEhBebida_(e.id) && !(cfNum_(e.custo) > 0)).length;
  const prodSem = cfProdutosSemCusto_().length;
  const ap = document.getElementById('cfAvisoProdutos');
  if(ap) ap.innerHTML = (prodSem || ingSem) ? `<div class="cf-aviso">⚠️ <b>Cadastro incompleto:</b> ${prodSem} produto(s) sem custo${ingSem ? ' · ' + ingSem + ' ingrediente(s) sem preço' : ''}. Sem custo, a margem e o lucro dos relatórios ficam errados.
    <div class="btnrow">${ingSem ? '<button type="button" class="small-gold" onclick="cfAbrirLote()">💲 Dar preço aos ingredientes</button>' : ''}${prodSem ? '<button type="button" class="ghost" onclick="cfProximoSemCusto()">Abrir o próximo produto sem custo</button>' : ''}</div></div>` : '';
  const ae = document.getElementById('cfAvisoEstoque');
  if(ae) ae.innerHTML = (ingSem || bebSem) ? `<div class="cf-aviso">⚠️ ${ingSem ? ingSem + ' ingrediente(s) sem preço' : ''}${ingSem && bebSem ? ' · ' : ''}${bebSem ? bebSem + ' bebida(s)/item(ns) pronto(s) sem custo' : ''}.
    ${ingSem ? '<div class="btnrow"><button type="button" class="small-gold" onclick="cfAbrirLote()">💲 Dar preço agora</button></div>' : ''}</div>` : '';
  cfEstoqueContagem_();
}
function cfProximoSemCusto(){ const p = cfProdutosSemCusto_()[0]; if(p) abrirEditarProduto(p.id); }

/* ---------- VENDA COM CUSTO ALTERADO ----------
   O banco confere o custo de cada item com o cadastro. Se o custo mudou com a tela aberta (preço de ingrediente, compra recebida),
   a venda é recusada com "O custo de ... não confere". Aqui a tela busca os custos novos e tenta de novo UMA vez. O preço nunca é trocado. */
function cfCustoMudou(r){ return !!(r && r.ok === false && /O custo de .* não confere com o cadastro/i.test(r.message || '')); }
async function cfAtualizarCustosItens(lista){
  try{
    const r = await apiCall('getDadosGrupo', { grupo:'cad' });
    if(!r || r.ok === false) return false;
    if(r.produtoPrecos) produtoPrecos = r.produtoPrecos;
    if(r.comboPrecos) comboPrecos = r.comboPrecos;
    salvarCache();
  }catch(err){ return false; }
  (lista || []).forEach(it => {
    if(it.produtoId) it.custoUnitario = cfNum_(precoDisplayProduto(it.produtoId).custo);
    else if(it.comboId) it.custoUnitario = custoComboComEscolha_(it.comboId, it.escolhas, cfNum_(precoDisplayCombo(it.comboId).custo));
  });
  return true;
}

/* estado inicial do formulário de novo produto */
(function(){
  function iniciar(){ try{ cfIniciarProduto('p', null); }catch(err){} try{ cfIngAtualizar('e'); }catch(err){} }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
})();

/* Fase 8.2: duplicar produto = abre o "Novo produto" já preenchido (nada é salvo até tocar em Cadastrar; foto e preços próprios não vão) */
async function duplicarProduto_(id){
  const p = (produtos || []).find(x => x.id === id); if(!p) return;
  abrirFormModal('produtoNovoModal'); window._cfSemRascunho_ = true; cfIniciarProduto('p', null); window._cfSemRascunho_ = false;
  cfSet_('pNome', p.nome + ' (cópia)'); cfSet_('pDescricao', p.descricao || ''); cfSet_('pCategoria', p.categoria || '');
  const d = precoDisplayProduto(p.id); cfSet_('pPreco', cfNum_(d.preco) > 0 ? cfNum_(d.preco) : '');
  const tinhaReceita = (produtoIngredientes || []).some(v => v.produtoId === p.id && v.ingredienteId !== p.estoqueProprioIngredienteId);
  if(tinhaReceita){ cfSetTipo('p', 'receita'); await cfRwCopiar('p', id); }
  else if(p.estoqueProprioIngredienteId){ cfSetTipo('p', 'pronto'); }
  else { cfSetTipo('p', 'manual'); cfSet_('pCusto', cfNum_(d.custo) > 0 ? cfNum_(d.custo) : ''); }
  cfAtualizarMargem('p');
  showMsg('pMsg', 'Cópia de "' + p.nome + '" aberta. Troque o nome e ajuste o que for diferente; só salva quando você tocar em Cadastrar.', 'ok');
}


/* ---------- Rascunho automático do "Novo produto" + ajuste de preços em lote (18/10/2026) ---------- */
var CF_RASC_CHAVE_ = 'tb_rascunho_produto_v1';
var CF_RASC_CAMPOS_ = ['pNome','pDescricao','pCategoria','pPreco','pCusto','pPrValor','pPrQtd','pEstoqueQtd','pEstoqueMin'];
function cfRascunhoLer_(){ try{ const v = JSON.parse(localStorage.getItem(CF_RASC_CHAVE_) || 'null'); return v && v.c && v.c.pNome ? v : null; }catch(e){ return null; } }
function cfRascunhoLimpar_(){ try{ localStorage.removeItem(CF_RASC_CHAVE_); }catch(e){} }
function cfRascunhoSalvar_(){
  try{
    const c = {}; CF_RASC_CAMPOS_.forEach(id => { const el = document.getElementById(id); if(el) c[id] = el.value; });
    if(!String(c.pNome || '').trim()){ cfRascunhoLimpar_(); return; }
    const adic = Array.from(document.querySelectorAll('#pAdicionaisLista input[type=checkbox]:checked')).map(x => x.value);
    const prec = {}; document.querySelectorAll('#pPrecosProprios input[data-forma]').forEach(i => { if(i.value !== '') prec[i.dataset.forma] = i.value; });
    const dest = document.getElementById('pDestaque');
    localStorage.setItem(CF_RASC_CHAVE_, JSON.stringify({ c, tipo: CF_TIPO_.p, ing: ingredientesProdutoNovo || [], adic, prec, dest: !!(dest && dest.checked), em: Date.now() }));
  }catch(e){}
}
(function(){
  const orig = cfIniciarProduto;
  cfIniciarProduto = function(pre, p){
    orig.apply(this, arguments);
    if(pre !== 'p' || p || window._cfSemRascunho_) return;
    const m = document.getElementById('produtoNovoModal'); if(!m || !m.classList.contains('open')) return;
    const r = cfRascunhoLer_(); if(!r || typeof confirmarTxt_ !== 'function') return;
    confirmarTxt_('Você deixou o produto "' + r.c.pNome + '" sem terminar. Continuar de onde parou?', 'Continuar', false, 'Rascunho salvo').then(ok => {
      if(!ok){ cfRascunhoLimpar_(); return; }
      CF_RASC_CAMPOS_.forEach(id => cfSet_(id, r.c[id]));
      if(r.tipo) cfSetTipo('p', r.tipo);
      try{
        ingredientesProdutoNovo = Array.isArray(r.ing) ? r.ing : []; cfRwRender('p');
        renderAdicionaisChecklist('pAdicionaisLista', r.adic || []);
        renderPrecosExcecoes('p', r.prec || {});
        const d = document.getElementById('pDestaque'); if(d) d.checked = !!r.dest;
        cfAtualizarCusto('p');
      }catch(e){}
      try{ cfAtualizarMargem('p'); }catch(e){}
    });
  };
  const ra = cfRwAdicionar, rr = cfRwRemover;
  cfRwAdicionar = function(pre){ ra.apply(this, arguments); if(pre === 'p') cfRascunhoSalvar_(); };
  cfRwRemover = function(pre){ rr.apply(this, arguments); if(pre === 'p') cfRascunhoSalvar_(); };
  document.addEventListener('change', function(e){
    const m = document.getElementById('produtoNovoModal');
    if(m && m.classList.contains('open') && m.contains(e.target)) cfRascunhoSalvar_();
  });
  document.addEventListener('input', function(e){
    const m = document.getElementById('produtoNovoModal');
    if(m && m.classList.contains('open') && m.contains(e.target)) cfRascunhoSalvar_();
  });
})();

/* Ajuste de preços em lote: percentual para todos os produtos ativos ou só de uma categoria */
function cfAjustarPrecosAbrir(){
  let m = document.getElementById('ajustePrecosModal');
  if(!m){
    m = document.createElement('div'); m.className = 'modal-overlay'; m.id = 'ajustePrecosModal';
    m.innerHTML = '<div class="modal-box"><div class="modal-header"><h2>Ajustar preços (%)</h2><button class="close-btn" onclick="fecharFormModal(\'ajustePrecosModal\')" aria-label="Fechar">✕</button></div>' +
      '<p class="hint">Sobe ou baixa o preço de vários produtos de uma vez. O custo não muda. Use negativo para baixar (ex.: -5).</p>' +
      '<label>Percentual (%)</label><input type="number" id="apPct" step="0.1" placeholder="Ex.: 8">' +
      '<label>Categoria</label><select id="apCat"></select>' +
      '<div class="msg" id="apMsg"></div>' +
      '<div class="btn-row"><button type="button" class="small-gold" id="apBtn" onclick="cfAjustarPrecosAplicar()">Aplicar</button><button type="button" class="ghost" onclick="fecharFormModal(\'ajustePrecosModal\')">Cancelar</button></div></div>';
    document.body.appendChild(m);
  }
  const esc = t => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  const cats = Array.from(new Set((produtos || []).filter(x => x.ativo !== false && x.categoria).map(x => (typeof nomeCategoria === 'function' ? nomeCategoria(x.categoria) : x.categoria) || '').filter(Boolean))).sort((a, b) => a.localeCompare(b));
  document.getElementById('apCat').innerHTML = '<option value="">Todas as categorias</option>' + cats.map(c => '<option value="' + esc(c) + '">' + esc(c) + '</option>').join('');
  document.getElementById('apPct').value = ''; document.getElementById('apMsg').textContent = '';
  abrirFormModal('ajustePrecosModal');
}
async function cfAjustarPrecosAplicar(){
  const pct = Number(document.getElementById('apPct').value), cat = document.getElementById('apCat').value;
  if(!pct || pct < -50 || pct > 100){ showMsg('apMsg', 'Informe um percentual entre -50 e 100.', 'warn'); return; }
  const ok = await confirmarTxt_('Ajustar em ' + (pct > 0 ? '+' : '') + pct + '% os preços de ' + (cat ? 'todos os produtos da categoria "' + cat + '"' : 'TODOS os produtos ativos') + '? Fica registrado na auditoria.', 'Ajustar', true);
  if(!ok) return;
  const b = document.getElementById('apBtn'); b.disabled = true;
  try{
    const r = await apiCall('ajustarPrecosProdutosLote', { percentual: pct, categoria: cat });
    if(r && r.ok){
      if(r.produtos) produtos = r.produtos; if(r.produtoPrecos) produtoPrecos = r.produtoPrecos; if(r.comboPrecos) comboPrecos = r.comboPrecos; salvarCache();
      fecharFormModal('ajustePrecosModal'); try{ renderProdutos(); }catch(e){ if(window.erroTela_) erroTela_(e); } showMsg('pMsgLista', r.message, 'ok');
    } else showMsg('apMsg', (r && r.message) || 'Não foi possível ajustar.', 'warn');
  }catch(e){ showMsg('apMsg', 'Não foi possível ajustar agora. Tente de novo.', 'warn'); }
  finally { b.disabled = false; }
}


/* Mostrar/esconder vários produtos do cardápio de uma vez */
function cfVisLoteAbrir(){
  let m = document.getElementById('visLoteModal');
  if(!m){
    m = document.createElement('div'); m.className = 'modal-overlay'; m.id = 'visLoteModal';
    m.innerHTML = '<div class="modal-box"><div class="modal-header"><h2>Mostrar ou esconder produtos</h2><button class="close-btn" onclick="fecharFormModal(\'visLoteModal\')" aria-label="Fechar">✕</button></div>' +
      '<p class="hint">Marque os produtos e escolha mostrar ou esconder no cardápio. Nada é apagado: os produtos escondidos continuam cadastrados.</p>' +
      '<label>Categoria</label><select id="vlCat" onchange="cfVisLoteRender()"></select>' +
      '<div class="btn-row"><button type="button" class="ghost small" onclick="cfVisLoteMarcar(true)">Marcar todos</button><button type="button" class="ghost small" onclick="cfVisLoteMarcar(false)">Desmarcar</button></div>' +
      '<div id="vlLista" style="max-height:45vh;overflow:auto;margin:8px 0;"></div><div class="msg" id="vlMsg"></div>' +
      '<div class="btn-row"><button type="button" class="small-gold" onclick="cfVisLoteAplicar(true)">Mostrar marcados</button><button type="button" class="ghost" onclick="cfVisLoteAplicar(false)">Esconder marcados</button></div></div>';
    document.body.appendChild(m);
  }
  const esc = t => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const cats = Array.from(new Set((produtos || []).map(x => x.categoria).filter(Boolean)));
  document.getElementById('vlCat').innerHTML = '<option value="">Todas as categorias</option>' + cats.map(c => '<option value="' + esc(c) + '">' + esc(typeof nomeCategoria === 'function' ? nomeCategoria(c) : c) + '</option>').join('');
  document.getElementById('vlMsg').textContent = ''; cfVisLoteRender(); abrirFormModal('visLoteModal');
}
function cfVisLoteRender(){
  const cat = document.getElementById('vlCat').value, esc = t => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const l = (produtos || []).filter(x => !cat || x.categoria === cat).sort((a, b) => String(a.nome).localeCompare(String(b.nome)));
  document.getElementById('vlLista').innerHTML = l.map(x => '<label class="d-flex ai-centro gap-2 fs-sm"><input type="checkbox" class="largura-auto" value="' + x.id + '"> ' + esc(x.nome) + ' <span class="txt-muted fs-xs">' + (x.ativo === false ? '· escondido' : '· visível') + '</span></label>').join('') || '<span class="txt-muted fs-xs">Nenhum produto.</span>';
}
function cfVisLoteMarcar(v){ document.querySelectorAll('#vlLista input[type=checkbox]').forEach(i => { i.checked = v; }); }
async function cfVisLoteAplicar(ativo){
  const ids = Array.from(document.querySelectorAll('#vlLista input[type=checkbox]:checked')).map(i => i.value);
  if(!ids.length){ showMsg('vlMsg', 'Marque pelo menos um produto.', 'warn'); return; }
  if(!await confirmarTxt_((ativo ? 'Mostrar ' : 'Esconder ') + ids.length + ' produto(s) no cardápio?', ativo ? 'Mostrar' : 'Esconder', !ativo)) return;
  try{
    const r = await apiCall('visibilidadeLoteProdutos', { ids, ativo });
    if(r && r.ok){ if(r.produtos) produtos = r.produtos; salvarCache(); fecharFormModal('visLoteModal'); try{ renderProdutos(); renderProdutoCuradoria(); }catch(e){ if(window.erroTela_) erroTela_(e); } showMsg('pMsgLista', r.message, 'ok'); }
    else showMsg('vlMsg', (r && r.message) || 'Não foi possível alterar.', 'warn');
  }catch(e){ showMsg('vlMsg', 'Não foi possível alterar agora. Tente de novo.', 'warn'); }
}
