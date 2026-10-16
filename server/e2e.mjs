// 端到端联机测试：三个玩家通过真实 HTTP 接口打完整一局。
// 用法：node e2e.mjs [baseUrl]
const BASE = process.argv[2] || 'http://127.0.0.1:8731/api.php';

async function api(params) {
  const r = await fetch(BASE, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
  });
  return r.json();
}

let fails = 0, passes = 0;
function check(name, cond, extra) {
  if (cond) { passes++; }
  else { fails++; console.log(`FAIL  ${name}`, extra !== undefined ? JSON.stringify(extra) : ''); }
}

// ---- 牌型工具（与 Swift 端对齐）
function parseCards(s) {
  if (!s) return [];
  return s.split(',').filter(Boolean).map(x => {
    const [rank, suit] = x.split('-');
    return { rank: +rank, suit: +suit };
  });
}
function countsOf(cards) {
  const m = {};
  for (const c of cards) m[c.rank] = (m[c.rank] || 0) + 1;
  return m;
}
function comboKey(table) { return table ? `${table.kind}/${table.chain}` : 'null'; }

// 用服务端自己的规则挑一手能压的牌：直接暴力试所有子集太慢，
// 改为从 table 里挑：这里只做「跟牌」，用简单启发式。
function pickPlay(hand, table) {
  const cs = hand.map(c => `${c.rank}-${c.suit}`);
  const byRank = {};
  for (const c of hand) (byRank[c.rank] ||= []).push(c);

  const tryIt = async (cards) => {
    const r = await api({ action: 'play', room: ROOM, token: tokOf(SEAT), seat: String(SEAT), cards });
    return r;
  };

  return { tryIt, byRank, cs };
}

let ROOM = '', SEAT = 0;
const toks = {};

// 暴力：从小到大尝试所有合法组合。用一个简化的本地枚举器（与服务端规则一致）。
function parseCombo(cards) {
  const n = cards.length;
  if (n === 0 || n > 20) return null;
  const counts = countsOf(cards);
  const ranks = Object.keys(counts).map(Number).sort((a, b) => a - b);
  const k = ranks.length;
  if (n === 2 && counts[16] && counts[17] && k === 2) return { kind: 13, mainRank: 17, chain: 1 };
  if (n === 4 && k === 1 && counts[ranks[0]] === 4) return { kind: 12, mainRank: ranks[0], chain: 1 };
  if (n === 1) return { kind: 0, mainRank: cards[0].rank, chain: 1 };
  if (n === 2) return k === 1 ? { kind: 1, mainRank: ranks[0], chain: 1 } : null;
  if (n === 3) return k === 1 ? { kind: 2, mainRank: ranks[0], chain: 1 } : null;
  if (n === 4) {
    const t = ranks.find(r => counts[r] === 3);
    return t !== undefined ? { kind: 3, mainRank: t, chain: 1 } : null;
  }
  if (n === 5) {
    const t = ranks.find(r => counts[r] === 3);
    if (t !== undefined) {
      const rest = ranks.filter(r => r !== t);
      if (rest.length === 1 && counts[rest[0]] === 2) return { kind: 4, mainRank: t, chain: 1 };
    }
  }
  const f = ranks.find(r => counts[r] === 4);
  if (f !== undefined) {
    const rest = ranks.filter(r => r !== f);
    const sum = rest.reduce((a, r) => a + counts[r], 0);
    if (n === 6 && sum === 2) return { kind: 10, mainRank: f, chain: 1 };
    if (n === 8 && rest.length === 2 && rest.every(r => counts[r] === 2)) return { kind: 11, mainRank: f, chain: 1 };
  }
  if (n >= 5 && k === n) {
    const cs = consecutiveGroupsExact(ranks, 5);
    if (cs) return { kind: 5, mainRank: cs[cs.length - 1], chain: cs.length };
  }
  if (n >= 6 && n % 2 === 0 && ranks.every(r => counts[r] === 2)) {
    const g = consecutiveGroupsExact(ranks, 3);
    if (g) return { kind: 6, mainRank: g[g.length - 1], chain: g.length };
  }
  const body = consecutiveGroupsMulti(counts, 3, 2);
  if (body) {
    const kk = body.length;
    const main = body[kk - 1];
    const restRanks = ranks.filter(r => !body.includes(r));
    const sum = restRanks.reduce((a, r) => a + counts[r], 0);
    if (sum === 0 && n === kk * 3) return { kind: 7, mainRank: main, chain: kk };
    if (n === kk * 4 && sum === kk) return { kind: 8, mainRank: main, chain: kk };
    if (n === kk * 5 && restRanks.length === kk && restRanks.every(r => counts[r] === 2)) {
      return { kind: 9, mainRank: main, chain: kk };
    }
  }
  return null;
}
function consecutiveGroupsExact(ranks, minN) {
  if (ranks.length < minN) return null;
  if (ranks.some(r => r >= 15)) return null;
  for (let i = 1; i < ranks.length; i++) if (ranks[i] !== ranks[i - 1] + 1) return null;
  return ranks;
}
function consecutiveGroupsMulti(counts, size, minN) {
  const c = Object.keys(counts).map(Number).filter(r => counts[r] >= size && r < 15).sort((a, b) => a - b);
  if (c.length < minN) return null;
  let best = null, cur = [c[0]];
  for (let i = 1; i < c.length; i++) {
    if (c[i] === c[i - 1] + 1) cur.push(c[i]);
    else { if (cur.length >= minN && (!best || cur.length > best.length)) best = cur; cur = [c[i]]; }
  }
  if (cur.length >= minN && (!best || cur.length > best.length)) best = cur;
  return best;
}
function beats(a, b) {
  if (!a) return false;
  if (!b) return true;
  if (a.kind === 13) return b.kind !== 13;
  if (b.kind === 13) return false;
  if (a.kind === 12) return b.kind === 12 ? a.mainRank > b.mainRank : true;
  if (b.kind === 12) return false;
  if (a.kind !== b.kind) return false;
  if ([5, 6, 7, 8, 9].includes(a.kind)) {
    if (a.chain !== b.chain) return a.chain > b.chain;
  }
  return a.mainRank > b.mainRank;
}

// 枚举所有能压过 table 的出牌（子集规模可控：手牌 <=20）
function allSubsets(cards) {
  const out = [];
  const n = cards.length;
  for (let mask = 1; mask < (1 << n); mask++) {
    const pick = [];
    for (let i = 0; i < n; i++) if (mask & (1 << i)) pick.push(cards[i]);
    out.push(pick);
  }
  return out;
}
function findBeating(hand, table) {
  const cands = [];
  for (const s of allSubsets(hand)) {
    const c = parseCombo(s);
    if (c && beats(c, table)) cands.push({ cards: s, combo: c });
  }
  if (!cands.length) return null;
  // 非炸弹优先，其次最小主点数
  cands.sort((x, y) => {
    const bx = x.combo.kind === 12 || x.combo.kind === 13 ? 1 : 0;
    const by = y.combo.kind === 12 || y.combo.kind === 13 ? 1 : 0;
    if (bx !== by) return bx - by;
    if (x.combo.mainRank !== y.combo.mainRank) return x.combo.mainRank - y.combo.mainRank;
    return x.cards.length - y.cards.length;
  });
  return cands[0];
}

// ---- 主流程
const t0 = Date.now();

// 建房
const c = await api({ action: 'create', nick: '甲' });
check('create 成功', c.ok === true, c);
ROOM = c.room; toks[0] = c.token; SEAT = 0;
check('房间号 6 位', /^[A-Z0-9]{6}$/.test(ROOM), ROOM);
check('房主 seat=0', c.seat === 0);
check('房主看到 17 张牌', c.state.hands[0].length === 17, c.state.hands[0].length);
check('房主看不到别人手牌', c.state.hands[1].length === 0 && c.state.hands[2].length === 0);
check('别人的 counts 是 17', c.state.counts[1] === 17 && c.state.counts[2] === 17);
check('初始 phase=idle', c.state.phase === 'idle');
check('seatsFilled 1/3', JSON.stringify(c.state.seatsFilled) === '[true,false,false]');
check('底牌 3 张', c.state.bottom.length === 3);

// 加入
const j1 = await api({ action: 'join', room: ROOM, nick: '乙' });
check('join 成功', j1.ok === true, j1);
check('第二人 seat=1', j1.seat === 1);
toks[1] = j1.token;
const j2 = await api({ action: 'join', room: ROOM, nick: '丙' });
check('第三人 seat=2', j2.seat === 2, j2);
toks[2] = j2.token;

// 第四人应被拒
const j3 = await api({ action: 'join', room: ROOM, nick: '丁' });
check('第 4 人被拒', j3.ok === false && /已满/.test(j3.msg || ''), j3);

// 三人准备 -> 应该有牌局
let st = (await api({ action: 'ready', room: ROOM, token: toks[0], seat: '0' })).state;
check('准备1后仍 idle（人数不足）', st.phase === 'idle', st.phase);
st = (await api({ action: 'ready', room: ROOM, token: toks[1], seat: '1' })).state;
check('准备2后仍 idle', st.phase === 'idle', st.phase);
st = (await api({ action: 'ready', room: ROOM, token: toks[2], seat: '2' })).state;
check('准备3后进入 bidding', st.phase === 'bidding', st.phase);
check('bidding 阶段自己能看到 17 张牌', st.hands[2].length === 17, st.hands[2].length);
check('bidding 阶段看不到别人手牌', st.hands[0].length === 0 && st.hands[1].length === 0);

// 错误 token
const bad = await api({ action: 'bid', room: ROOM, token: 'deadbeef', seat: '0', value: '1' });
check('错误 token 被拒', bad.ok === false, bad);

// 乱出牌（非当前回合）
const wrongTurn = await api({ action: 'bid', room: ROOM, token: toks[1], seat: '1', value: '1' });
check('非当前回合叫分被拒', wrongTurn.ok === false && /还没轮到你/.test(wrongTurn.msg || ''), wrongTurn);

// 依次叫分：current 从 0 开始
st = (await api({ action: 'bid', room: ROOM, token: toks[0], seat: '0', value: '1' })).state;
check('0 号叫 1 分后 current=1', st.current === 1, st.current);
check('bids 记录 1', st.bids[0] === 1, st.bids);
st = (await api({ action: 'bid', room: ROOM, token: toks[1], seat: '1', value: '0' })).state;
check('1 号不叫后 current=2', st.current === 2, st.current);
st = (await api({ action: 'bid', room: ROOM, token: toks[2], seat: '2', value: '2' })).state;
check('2 号叫 2 分后定地主', st.landlord === 2, st.landlord);
check('地主进入 playing', st.phase === 'playing', st.phase);
check('地主 current=2', st.current === 2, st.current);
check('地主手牌 20 张', st.counts[2] === 20, st.counts);
check('地主倍数 >=2', st.mult >= 2, st.mult);

// 地主必须先出，不能过牌
const firstPass = await api({ action: 'pass', room: ROOM, token: toks[2], seat: '2' });
check('首出不能过牌', firstPass.ok === false && /必须出牌/.test(firstPass.msg || ''), firstPass);

// 打完这一局
let guard = 0;
let plays = 0;
let finished = false;
let lastState = st;
while (guard++ < 4000) {
  const state = (await api({ action: 'poll', room: ROOM, token: toks[0], seat: '0', since: '-1' })).state;
  if (!state) { check('poll 有返回', false); break; }
  if (state.phase === 'finished') { finished = true; lastState = state; break; }

  const cur = state.current;
  const hand = state.hands[cur] || [];
  // 非本人视角拿不到手牌（只有轮到自己才有），这里轮询用的是 seat 0
  // 所以模拟时统一用 seat 0 的 token 驱动 2 号需要单独处理：
  break;
}

// 由于快照只把「我」的手牌下发，上面的轮转模拟改用「每座位各自轮询」
let iter = 0;
let done = false;
let finalState = null;
while (iter++ < 3000 && !done) {
  // 逐座位同步：先看 0 号视角
  const s0 = (await api({ action: 'poll', room: ROOM, token: toks[0], seat: '0', since: '-1' })).state;
  if (!s0) { check('poll 返回 state', false, s0); break; }
  if (s0.phase === 'finished') { done = true; finalState = s0; break; }
  if (s0.current === 0) {
    const hand = s0.hands[0];
    const pick = findBeating(hand, s0.table);
    if (pick) {
      const r = await api({ action: 'play', room: ROOM, token: toks[0], seat: '0',
                            cards: pick.cards.map(c => `${c.rank}-${c.suit}`).join(',') });
      if (!r.ok) { check('合法出牌被接受', false, r); break; }
      plays++;
    } else {
      const r = await api({ action: 'pass', room: ROOM, token: toks[0], seat: '0' });
      if (!r.ok && !/必须出牌/.test(r.msg || '')) { check('pass 被接受', false, r); break; }
      else if (r.ok) plays++;
    }
  } else {
    // 轮不到 0 号：用对应座位的 token 驱动
    const s = (await api({ action: 'poll', room: ROOM, token: toks[s0.current], seat: String(s0.current), since: '-1' })).state;
    if (s.current !== s0.current) { continue; }
    const hand = s.hands[s.current] || [];
    const pick = findBeating(hand, s.table);
    if (pick) {
      const r = await api({ action: 'play', room: ROOM, token: toks[s.current], seat: String(s.current),
                            cards: pick.cards.map(c => `${c.rank}-${c.suit}`).join(',') });
      if (!r.ok) { check('合法出牌被接受', false, r); break; }
      plays++;
    } else {
      const r = await api({ action: 'pass', room: ROOM, token: toks[s.current], seat: String(s.current) });
      if (!r.ok && !/必须出牌/.test(r.msg || '')) { check('pass 被接受', false, r); break; }
      else if (r.ok) plays++;
    }
  }
}

check('对局能打到结束', done, { iter, phase: finalState?.phase });
if (done) {
  check('有赢家', finalState.winner !== null, finalState.winner);
  check('地主标识存在', finalState.landlord !== null);
  check('landlordWon 是布尔', typeof finalState.landlordWon === 'boolean', finalState.landlordWon);
  check('只有赢家手牌为 0', finalState.counts[finalState.winner] === 0, finalState.counts);
  check('非赢家仍有余牌', finalState.counts.filter((_, i) => i !== finalState.winner)
        .every(v => v > 0), finalState.counts);
  check('得分非 0', Math.abs(finalState.scoreDelta) > 0, finalState.scoreDelta);
  check('出牌次数 > 10', plays > 10, plays);
  const total = finalState.played.flat().length;
  check('出牌总数在合理区间 (0,54]', total > 0 && total <= 54, total);
  check('已出牌 + 剩余手牌 = 54（底牌已并入地主手牌）',
        total + finalState.counts.reduce((a, b) => a + b, 0) === 54,
        { total, counts: finalState.counts });
}

// 再来一局
const again = await api({ action: 'ready', room: ROOM, token: toks[finalState.winner], seat: String(finalState.winner) });
check('再来一局回到 bidding', again.state.phase === 'bidding', again.state.phase);
check('新局叫分前三人各 17 张（底牌另计）', again.state.counts.join() === '17,17,17', again.state.counts);
check('新局底牌 3 张单独存放', again.state.bottom.length === 3, again.state.bottom.length);

// 版本号必须递增
const v1 = again.state.v;
const ready2 = await api({ action: 'ready', room: ROOM, token: toks[0], seat: '0' });
check('版本号递增', ready2.state.v > v1, { v1, v2: ready2.state.v });

// 房间不存在
const noRoom = await api({ action: 'poll', room: 'ZZZZZZ', token: 'x', seat: '0', since: '-1' });
check('不存在的房间被拒', noRoom.ok === false, noRoom);

// 长轮询不持锁：房主 poll 时另一人仍能操作
const pollP = fetch(BASE, { method: 'POST',
  body: new URLSearchParams({ action: 'poll', room: ROOM, token: toks[0], seat: '0', since: String(ready2.state.v) }).toString() });
await new Promise(r => setTimeout(r, 600));
const concurrent = await api({ action: 'ready', room: ROOM, token: toks[1], seat: '1' });
check('有人 poll 时其他人仍可操作（不持锁）', concurrent.ok === true, concurrent);
await pollP;

console.log(`\nE2E: ${passes} 通过 / ${fails} 失败   房间=${ROOM} 出牌=${plays} 耗时=${Date.now() - t0}ms`);
process.exit(fails > 0 ? 1 : 0);
