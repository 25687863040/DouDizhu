<?php
/**
 * 斗地主联机服务端（单文件版）
 *
 * 部署：把本文件和 data/ 目录一起传到任意支持 PHP 7.4+ 的空间。
 * 需要 data/ 目录可写。
 *
 * 接口（POST，JSON 返回）：
 *   action=create                建房   -> room / token / seat / state
 *   action=join&room=xxx         加入   -> room / token / seat / state
 *   action=ready&room&token      准备 / 再来一局
 *   action=bid&value=            叫分（0/1/2/3，3=抢地主）
 *   action=play&cards=           出牌，cards="14-1,17-5,15-0"
 *   action=pass                  不出
 *   action=poll&since=N          长轮询，版本变化即返回
 *
 * ⚠️ 长轮询绝不持锁睡眠：只瞬时加锁读版本，随即释放，避免堵住其他玩家操作。
 */

declare(strict_types=1);

const MAX_POLL_SECONDS = 25;
const POLL_INTERVAL_US  = 250000; // 250ms
const ROOM_TTL          = 7200;   // 闲置 2 小时回收

// ComboKind rawValue，与 Swift 端严格一致
const K_SINGLE = 0;  const K_PAIR = 1;  const K_TRIPLE = 2;
const K_TRIPLE_ONE = 3;  const K_TRIPLE_PAIR = 4;
const K_STRAIGHT = 5;  const K_DOUBLE_STRAIGHT = 6;
const K_TRIPLE_STRAIGHT = 7;
const K_AIRPLANE_SINGLES = 8;  const K_AIRPLANE_PAIRS = 9;
const K_FOUR_TWO_SINGLES = 10; const K_FOUR_TWO_PAIRS = 11;
const K_BOMB = 12; const K_ROCKET = 13;

// ---------------------------------------------------------------- 基础设施

function data_dir(): string {
    $d = __DIR__ . '/data';
    if (!is_dir($d)) { @mkdir($d, 0775, true); }
    return $d;
}

function room_file(string $code): string {
    return data_dir() . '/room_' . $code . '.json';
}

function fail(string $msg, int $code = 400): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['ok' => false, 'msg' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

function ok(array $payload): void {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(array_merge(['ok' => true], $payload), JSON_UNESCAPED_UNICODE);
    exit;
}

function gen_code(int $len = 6): string {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 去掉易混淆的 I O 0 1
    $out = '';
    for ($i = 0; $i < $len; $i++) { $out .= $chars[random_int(0, strlen($chars) - 1)]; }
    return $out;
}

function gen_token(): string { return bin2hex(random_bytes(16)); }

/**
 * 持锁执行一次对房间的读写。返回 $cb 的返回值。
 * $cb 收到 &$room（null 表示房间不存在）、$fh（已加锁的句柄）。
 * ⚠️ Windows 上 rename() 无法覆盖仍打开的文件，所以必须「持锁直接覆写」，
 *    不能用临时文件 + rename。
 */
function room_tx(string $code, callable $cb) {
    $file = room_file($code);
    $fh = @fopen($file, 'c+');
    if (!$fh) fail('无法访问房间文件，请检查 data 目录写权限', 500);
    if (!flock($fh, LOCK_EX)) { fclose($fh); fail('服务器忙，请重试', 503); }
    $raw = stream_get_contents($fh);
    $room = ($raw !== '' && $raw !== false) ? json_decode($raw, true) : null;
    if (!is_array($room)) $room = null;
    try {
        return $cb($room, $fh);
    } finally {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

/** 在已加锁的句柄上覆写房间内容 */
function save_room($fh, array $room): void {
    $room['updatedAt'] = time();
    $json = json_encode($room, JSON_UNESCAPED_UNICODE);
    rewind($fh);
    ftruncate($fh, 0);
    fwrite($fh, $json);
    fflush($fh);
}

/** 只读一次房间状态（瞬时加锁）。返回 null 表示不存在。 */
function room_read(string $code): ?array {
    $file = room_file($code);
    $fh = @fopen($file, 'r');
    if (!$fh) return null;
    flock($fh, LOCK_SH);
    $raw = stream_get_contents($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
    if ($raw === '' || $raw === false) return null;
    $r = json_decode($raw, true);
    return is_array($r) ? $r : null;
}

function seat_of(array $room, string $token): ?int {
    foreach ($room['seats'] as $i => $s) {
        if ($s !== null && $s['token'] === $token) return $i;
    }
    return null;
}

function require_seat($room, string $token): int {
    if ($room === null) fail('房间不存在或已过期', 404);
    if (time() - (int)$room['updatedAt'] > ROOM_TTL) fail('房间已过期，请重新建房', 404);
    $s = seat_of($room, $token);
    if ($s === null) fail('你已不在这个房间里，请重新加入', 403);
    return $s;
}

/** 加入房间时用：房间不存在直接报错 */
function require_room($room): void {
    if ($room === null) fail('房间不存在或已过期', 404);
}

// ---------------------------------------------------------------- 牌 / 牌型

function parse_cards(string $s): array {
    $s = trim($s);
    if ($s === '') return [];
    $out = [];
    foreach (explode(',', $s) as $item) {
        $item = trim($item);
        if ($item === '' || strpos($item, '-') === false) continue;
        $p = explode('-', $item, 2);
        if (!is_numeric($p[0])) continue;
        $out[] = ['rank' => (int)$p[0], 'suit' => isset($p[1]) ? (int)$p[1] : 0];
    }
    return $out;
}

function cards_str(array $cards): string {
    return implode(',', array_map(fn($c) => $c['rank'] . '-' . $c['suit'], $cards));
}

function counts_of(array $cards): array {
    $m = [];
    foreach ($cards as $c) { $m[$c['rank']] = ($m[$c['rank']] ?? 0) + 1; }
    ksort($m);
    return $m;
}

function all_of(array $counts, int $v): bool {
    foreach ($counts as $c) if ($c !== $v) return false;
    return true;
}

function triple_rank(array $counts): ?int {
    foreach ($counts as $r => $c) if ($c === 3) return $r;
    return null;
}

function four_rank(array $counts): ?int {
    foreach ($counts as $r => $c) if ($c === 4) return $r;
    return null;
}

/** 取连续组（每组 $size 张），返回组点位数组或 null */
function consecutive_groups(array $counts, int $size, int $minGroups): ?array {
    $g = [];
    foreach ($counts as $r => $c) if ($c === $size) $g[] = $r;
    sort($g);
    if (count($g) < $minGroups) return null;
    foreach ($g as $r) if ($r >= 15) return null;   // 不含 2 和王
    for ($i = 1; $i < count($g); $i++) {
        if ($g[$i] !== $g[$i - 1] + 1) return null;
    }
    return $g;
}

/** 识别牌型 -> ['kind'=>int,'mainRank'=>int,'chain'=>int] 或 null */
function parse_combo(array $cards): ?array {
    $n = count($cards);
    if ($n === 0 || $n > 20) return null;
    $counts = counts_of($cards);
    $ranks = array_keys($counts);
    sort($ranks);
    $k = count($ranks);

    // 王炸
    if ($n === 2 && isset($counts[16], $counts[17]) && $k === 2) {
        return ['kind' => K_ROCKET, 'mainRank' => 17, 'chain' => 1];
    }
    // 炸弹
    if ($n === 4 && $k === 1 && $counts[$ranks[0]] === 4) {
        return ['kind' => K_BOMB, 'mainRank' => $ranks[0], 'chain' => 1];
    }

    // 1~4 张：结构固定，直接判定
    if ($n === 1) return ['kind' => K_SINGLE, 'mainRank' => $cards[0]['rank'], 'chain' => 1];
    if ($n === 2) return $k === 1 ? ['kind' => K_PAIR, 'mainRank' => $ranks[0], 'chain' => 1] : null;
    if ($n === 3) return $k === 1 ? ['kind' => K_TRIPLE, 'mainRank' => $ranks[0], 'chain' => 1] : null;
    if ($n === 4) {
        $t = triple_rank($counts);
        return $t !== null ? ['kind' => K_TRIPLE_ONE, 'mainRank' => $t, 'chain' => 1] : null;
    }

    // 注意：5 张也可能是顺子，所以这里不能无条件 return null
    if ($n === 5) {
        $t = triple_rank($counts);
        if ($t !== null) {
            $wing = array_filter($counts, fn($r) => $r !== $t, ARRAY_FILTER_USE_KEY);
            if (count($wing) === 1 && reset($wing) === 2) {
                return ['kind' => K_TRIPLE_PAIR, 'mainRank' => $t, 'chain' => 1];
            }
        }
        // 落到下面的顺子判定
    }

    // 四带二（4 + 2 单）/ 四带两对（4 + 2 对）
    $f = four_rank($counts);
    if ($f !== null) {
        $rest = array_filter($counts, fn($r) => $r !== $f, ARRAY_FILTER_USE_KEY);
        if ($n === 6 && array_sum($rest) === 2) {
            return ['kind' => K_FOUR_TWO_SINGLES, 'mainRank' => $f, 'chain' => 1];
        }
        if ($n === 8 && count($rest) === 2 && all_of($rest, 2)) {
            return ['kind' => K_FOUR_TWO_PAIRS, 'mainRank' => $f, 'chain' => 1];
        }
    }

    // 顺子：>=5 连单
    if ($n >= 5 && $k === $n && consecutive_groups($counts, 1, 5) !== null) {
        $chain = $ranks;  // 全部都是单张且连续
        return ['kind' => K_STRAIGHT, 'mainRank' => end($chain), 'chain' => count($chain)];
    }
    // 连对：>=3 组连对
    if ($n >= 6 && $n % 2 === 0 && all_of($counts, 2)) {
        $g = consecutive_groups($counts, 2, 3);
        if ($g !== null) return ['kind' => K_DOUBLE_STRAIGHT, 'mainRank' => end($g), 'chain' => count($g)];
    }
    // 飞机：先在「有 >=3 张」的点数里找连续 >=2 组的主体，剩余牌当翅膀
    $body = consecutive_groups_multi($counts, 3, 2);
    if ($body !== null) {
        $kk = count($body);
        $main = end($body);
        $rest = array_filter($counts, fn($r) => !in_array($r, $body, true), ARRAY_FILTER_USE_KEY);
        $restN = array_sum($rest);
        // 纯飞机
        if ($restN === 0 && $n === $kk * 3) {
            return ['kind' => K_TRIPLE_STRAIGHT, 'mainRank' => $main, 'chain' => $kk];
        }
        // 带 k 张单牌（翅膀不能与主体同点，且必须正好 k 张）
        if ($n === $kk * 4 && $restN === $kk) {
            return ['kind' => K_AIRPLANE_SINGLES, 'mainRank' => $main, 'chain' => $kk];
        }
        // 带 k 个对子
        if ($n === $kk * 5 && count($rest) === $kk && all_of($rest, 2)) {
            return ['kind' => K_AIRPLANE_PAIRS, 'mainRank' => $main, 'chain' => $kk];
        }
    }
    return null;
}

/**
 * 在「每组至少 $size 张」的点数里找最长的一段连续组（>= $minGroups 组）。
 * 例如 3,3,3,4,4,4,9 -> [3,4]（9 是翅膀，不参与连续性）。
 * 点数 15(2) 和王不参与连续。
 */
function consecutive_groups_multi(array $counts, int $size, int $minGroups): ?array {
    $cands = [];
    foreach ($counts as $r => $c) {
        if ($c >= $size && $r < 15) $cands[] = $r;
    }
    if (count($cands) < $minGroups) return null;
    sort($cands);

    $best = null;
    $cur = [$cands[0]];
    for ($i = 1; $i < count($cands); $i++) {
        if ($cands[$i] === $cands[$i - 1] + 1) {
            $cur[] = $cands[$i];
        } else {
            if (count($cur) >= $minGroups && ($best === null || count($cur) > count($best))) $best = $cur;
            $cur = [$cands[$i]];
        }
    }
    if (count($cur) >= $minGroups && ($best === null || count($cur) > count($best))) $best = $cur;
    return $best;
}

/** $a 能否压过 $b（$b 为 null 表示自由出） */
function beats(?array $a, ?array $b): bool {
    if ($a === null) return false;
    if ($b === null) return true;
    $ak = $a['kind'];
    if ($ak === K_ROCKET) return $b['kind'] !== K_ROCKET;
    if ($b['kind'] === K_ROCKET) return false;
    if ($ak === K_BOMB) return $b['kind'] === K_BOMB ? $a['mainRank'] > $b['mainRank'] : true;
    if ($b['kind'] === K_BOMB) return false;
    if ($ak !== $b['kind']) return false;
    // 连牌型（顺子/连对/飞机）：先比长度，长的一定压短的
    if (in_array($ak, [K_STRAIGHT, K_DOUBLE_STRAIGHT, K_TRIPLE_STRAIGHT,
                       K_AIRPLANE_SINGLES, K_AIRPLANE_PAIRS], true)) {
        if ($a['chain'] !== $b['chain']) return $a['chain'] > $b['chain'];
    }
    return $a['mainRank'] > $b['mainRank'];
}

// ---------------------------------------------------------------- 房间生命周期

function new_room(string $code): array {
    $deck = [];
    foreach ([3,4,5,6,7,8,9,10,11,12,13,14,15] as $r) {
        foreach ([0,1,2,3] as $s) $deck[] = ['rank' => $r, 'suit' => $s];
    }
    $deck[] = ['rank' => 16, 'suit' => 4];
    $deck[] = ['rank' => 17, 'suit' => 5];
    for ($i = count($deck) - 1; $i > 0; $i--) {          // Fisher-Yates
        $j = random_int(0, $i);
        [$deck[$i], $deck[$j]] = [$deck[$j], $deck[$i]];
    }
    return [
        'code' => $code, 'v' => 1,
        'seats' => [null, null, null],
        'hands' => [array_slice($deck, 0, 17), array_slice($deck, 17, 17), array_slice($deck, 34, 17)],
        'bottom' => array_slice($deck, 51, 3),
        'played' => [[], [], []],
        'counts' => [17, 17, 17],
        'phase' => 'idle', 'landlord' => null, 'current' => 0,
        'base' => 1, 'mult' => 1,
        'table' => null, 'tableOwner' => null,
        'bids' => [-1, -1, -1], 'bidsLeft' => 3, 'highest' => null,
        'winner' => null, 'landlordWon' => null,
        'message' => '等待玩家加入',
        'createdAt' => time(), 'updatedAt' => time(),
    ];
}

function all_ready(array $room): bool {
    foreach ($room['seats'] as $s) if ($s === null || !$s['ready']) return false;
    return true;
}

/** 三人都准备 -> 发牌进入叫分。叫分从「第一个有牌的座位」开始（固定为 0 号所在座位轮转起点） */
function maybe_deal(array $room, int $startSeat): array {
    if ($room['phase'] !== 'idle' || !all_ready($room)) return $room;
    $fresh = new_room($room['code']);
    $fresh['seats'] = $room['seats'];
    $fresh['phase'] = 'bidding';
    // 叫分起点固定：房主座位（seats[0] 的持有者）所在座位轮转起点。
    // 为避免「谁最后加入谁先叫」的怪异体验，这里用第一个非空座位的索引。
    $first = null;
    foreach ($fresh['seats'] as $i => $s) { if ($s !== null) { $first = $i; break; } }
    $fresh['current'] = $first === null ? 0 : $first;
    $fresh['message'] = '叫地主中';
    $fresh['v'] = $room['v'] + 1;
    return $fresh;
}

function settle_landlord(array &$room): void {
    if ($room['highest'] === null) {
        $fresh = new_room($room['code']);
        $fresh['seats'] = $room['seats'];
        $fresh['phase'] = 'bidding';
        $fresh['current'] = 0;
        $fresh['message'] = '无人叫地主，重新发牌';
        $fresh['v'] = $room['v'] + 1;
        $room = $fresh;
        return;
    }
    $ld = $room['highest'];
    $room['landlord'] = $ld;
    $room['hands'][$ld] = array_merge($room['hands'][$ld], $room['bottom']);
    $room['counts'][$ld] = count($room['hands'][$ld]);
    $room['phase'] = 'playing';
    $room['current'] = $ld;
    $room['table'] = null;
    $room['tableOwner'] = null;
    $room['base'] = max($room['base'], max($room['bids']));
    $room['mult'] = max(1, max($room['bids']));
    $room['message'] = '地主出牌';
    $room['v']++;
}

function do_bid(array &$room, int $seat, int $value): void {
    $prevMax = max($room['bids']);
    $room['bids'][$seat] = $value;
    if ($value > 0 && $value >= $prevMax) $room['highest'] = $seat;
    if ($value === 3) { $room['highest'] = $seat; $room['mult'] = 3; }
    $room['bidsLeft']--;

    $allBid = count(array_filter($room['bids'], fn($b) => $b >= 0)) >= 3;
    if ($allBid || $value === 3 || $room['bidsLeft'] <= 0) {
        settle_landlord($room);
    } else {
        $room['current'] = ($seat + 1) % 3;
        $room['message'] = '等待叫分';
        $room['v']++;
    }
}

function finish_game(array &$room, int $winnerSeat): void {
    $ld = $room['landlord'];
    $room['phase'] = 'finished';
    $room['winner'] = $winnerSeat;
    $room['landlordWon'] = ($winnerSeat === $ld);

    $base = max(1, $room['base']);
    $mult = max(1, $room['mult']);
    $playedCount = 0;
    foreach ($room['played'] as $p) $playedCount += count($p);
    if ($room['landlordWon'] && $playedCount <= 2) $mult *= 2;                        // 春天
    if (!$room['landlordWon'] && count($room['played'][$ld]) <= 2) $mult *= 2;       // 反春
    $room['mult'] = $mult;

    $room['message'] = $room['landlordWon'] ? '地主获胜' : '农民获胜';
    $room['v']++;
}

/** 从「我」视角算分数 */
function score_for(array $room, int $seat): int {
    $ld = $room['landlord'];
    $delta = $room['base'] * max(1, $room['mult']);
    $iAmLandlord = ($ld === $seat);
    $iWon = ($room['winner'] === $seat);
    if ($room['landlordWon']) {
        return $iAmLandlord ? $delta * 2 : ($iWon ? $delta : -$delta);
    }
    return $iAmLandlord ? -$delta * 2 : ($iWon ? $delta : -$delta);
}

function do_play(array &$room, int $seat, array $cards): ?string {
    if ($room['phase'] !== 'playing') return '现在不能出牌';
    if ($room['current'] !== $seat) return '还没轮到你';

    foreach ($cards as $c) {
        $found = false;
        foreach ($room['hands'][$seat] as $h) {
            if ($h['rank'] === $c['rank'] && $h['suit'] === $c['suit']) { $found = true; break; }
        }
        if (!$found) return '你没有这张牌';
    }
    $combo = parse_combo($cards);
    if ($combo === null) return '不是合法牌型';
    if (!beats($combo, $room['table'])) return '管不过上家';

    // 扣牌（按 rank+suit 精确移除）
    $want = $cards;
    $remain = [];
    foreach ($room['hands'][$seat] as $h) {
        $used = false;
        foreach ($want as $i => $c) {
            if (!$used && $h['rank'] === $c['rank'] && $h['suit'] === $c['suit']) {
                unset($want[$i]);
                $used = true;
            }
        }
        if (!$used) $remain[] = $h;
    }
    $room['hands'][$seat] = $remain;
    $room['counts'][$seat] = count($remain);
    $room['played'][$seat] = array_merge($room['played'][$seat], $cards);
    $room['table'] = ['kind' => $combo['kind'], 'mainRank' => $combo['mainRank'],
                      'chain' => $combo['chain'], 'cards' => $cards];
    $room['tableOwner'] = $seat;
    $room['v']++;

    if (count($remain) === 0) {
        finish_game($room, $seat);
    } else {
        $room['current'] = ($seat + 1) % 3;
        $room['message'] = '等待出牌';
    }
    return null;
}

function do_pass(array &$room, int $seat): ?string {
    if ($room['phase'] !== 'playing') return '现在不能过牌';
    if ($room['current'] !== $seat) return '还没轮到你';
    if ($room['table'] === null) return '你是首出，必须出牌';

    // 一圈过完 -> 轮到上一手出牌者，他重新自由出牌
    if (($seat + 1) % 3 === $room['tableOwner']) {
        $room['table'] = null;
        $room['tableOwner'] = null;
        $room['current'] = ($seat + 1) % 3;
        $room['message'] = '新一轮，自由出牌';
    } else {
        $room['current'] = ($seat + 1) % 3;
        $room['message'] = '等待出牌';
    }
    $room['v']++;
    return null;
}

// ---------------------------------------------------------------- 快照

/** 生成给某座位看的快照：只把「我」的手牌完整下发 */
function snapshot_for(array $room, int $seat): array {
    $hands = [];
    for ($s = 0; $s < 3; $s++) $hands[$s] = ($s === $seat) ? $room['hands'][$s] : [];
    $filled = [];
    for ($s = 0; $s < 3; $s++) $filled[] = $room['seats'][$s] !== null;

    return [
        'v' => $room['v'],
        'started' => $room['phase'] !== 'idle',
        'seatsFilled' => $filled,
        'phase' => $room['phase'],
        'hands' => $hands,
        'counts' => $room['counts'],
        'landlord' => $room['landlord'],
        'bottom' => $room['bottom'],
        'current' => $room['current'],
        'base' => $room['base'],
        'mult' => $room['mult'],
        'table' => $room['table'],
        'tableOwner' => $room['tableOwner'],
        'played' => $room['played'],
        'bids' => $room['bids'],
        'bidsLeft' => $room['bidsLeft'],
        'highest' => $room['highest'],
        'winner' => $room['winner'],
        'scoreDelta' => $room['phase'] === 'finished' ? score_for($room, $seat) : 0,
        'landlordWon' => $room['landlordWon'],
        'message' => $room['message'],
        'mySeat' => $seat,
    ];
}

// ---------------------------------------------------------------- 路由
// 仅当本文件被直接访问时运行；被 selftest.php 等 include 时只暴露函数与常量。

function route(): void {

$action = $_POST['action'] ?? '';
$code   = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $_POST['room'] ?? ''));
$token  = $_POST['token'] ?? '';
$nick   = trim($_POST['nick'] ?? '玩家');
if (function_exists('mb_substr')) $nick = mb_substr($nick, 0, 8); else $nick = substr($nick, 0, 8);

if ($action === 'create') {
    $newCode = null;
    for ($i = 0; $i < 30; $i++) {
        $c = gen_code(6);
        if (!file_exists(room_file($c))) { $newCode = $c; break; }
    }
    if ($newCode === null) fail('服务器繁忙，请稍后重试', 503);

    $tok = gen_token();
    $st = room_tx($newCode, function (&$room, $fh) use ($newCode, $tok, $nick) {
        $room = new_room($newCode);
        $room['seats'][0] = ['token' => $tok, 'nick' => $nick, 'ready' => false];
        $room['message'] = '房间 ' . $newCode . ' 已创建，等待玩家加入（1/3）';
        save_room($fh, $room);
        return snapshot_for($room, 0);
    });
    ok(['room' => $newCode, 'token' => $tok, 'seat' => 0, 'state' => $st]);
}

if ($action === 'join') {
    if ($code === '') fail('房间号不能为空');
    $tok = gen_token();
    $seat = -1;
    $st = room_tx($code, function (&$room, $fh) use ($tok, $nick, &$seat) {
        require_room($room);
        if (time() - (int)$room['updatedAt'] > ROOM_TTL) fail('房间已过期，请重新建房', 404);

        $seat = -1;
        foreach ($room['seats'] as $i => $s) { if ($s === null) { $seat = $i; break; } }
        if ($seat < 0) fail('房间已满', 409);

        $room['seats'][$seat] = ['token' => $tok, 'nick' => $nick, 'ready' => false];
        $n = count(array_filter($room['seats'], fn($s) => $s !== null));
        $room['message'] = "{$nick} 加入（$n/3）";
        $room['v']++;
        $room = maybe_deal($room, $seat);
        save_room($fh, $room);
        return snapshot_for($room, $seat);
    });
    ok(['room' => $code, 'token' => $tok, 'seat' => $seat, 'state' => $st]);
}

if ($action === 'ready') {
    $st = room_tx($code, function (&$room, $fh) use ($token) {
        $seat = require_seat($room, $token);
        $room['seats'][$seat]['ready'] = true;
        if ($room['phase'] === 'finished') {
            $fresh = new_room($room['code']);
            $fresh['seats'] = $room['seats'];
            $fresh['phase'] = 'bidding';
            $fresh['current'] = 0;
            $fresh['message'] = '新一局，叫地主';
            $fresh['v'] = $room['v'] + 1;
            $room = $fresh;
        } else {
            $room['message'] = ($room['seats'][$seat]['nick'] ?? '玩家') . ' 已准备';
            $room['v']++;
            $room = maybe_deal($room, $seat);
        }
        save_room($fh, $room);
        return snapshot_for($room, $seat);
    });
    ok(['state' => $st]);
}

if ($action === 'bid') {
    $value = (int)($_POST['value'] ?? 0);
    $st = room_tx($code, function (&$room, $fh) use ($token, $value) {
        $seat = require_seat($room, $token);
        if ($room['phase'] !== 'bidding') fail('现在不是叫地主阶段');
        if ($room['current'] !== $seat) fail('还没轮到你叫分');
        do_bid($room, $seat, $value);
        save_room($fh, $room);
        return snapshot_for($room, $seat);
    });
    ok(['state' => $st]);
}

if ($action === 'play') {
    $cards = parse_cards($_POST['cards'] ?? '');
    $st = room_tx($code, function (&$room, $fh) use ($token, $cards) {
        $seat = require_seat($room, $token);
        $err = do_play($room, $seat, $cards);
        if ($err !== null) fail($err);
        save_room($fh, $room);
        return snapshot_for($room, $seat);
    });
    ok(['state' => $st]);
}

if ($action === 'pass') {
    $st = room_tx($code, function (&$room, $fh) use ($token) {
        $seat = require_seat($room, $token);
        $err = do_pass($room, $seat);
        if ($err !== null) fail($err);
        save_room($fh, $room);
        return snapshot_for($room, $seat);
    });
    ok(['state' => $st]);
}

/**
 * 长轮询：反复「瞬时加锁读版本 -> 释放 -> 睡 250ms」，
 * 版本一变就带锁取快照返回。绝不持锁睡眠。
 */
if ($action === 'poll') {
    if ($code === '') fail('房间号不能为空');
    $since = (int)($_POST['since'] ?? -1);
    $deadline = microtime(true) + MAX_POLL_SECONDS;

    while (true) {
        $room = room_read($code);
        if ($room === null) fail('房间不存在或已过期', 404);
        if (time() - (int)$room['updatedAt'] > ROOM_TTL) fail('房间已过期，请重新建房', 404);
        $seat = seat_of($room, $token);
        if ($seat === null) fail('你已不在这个房间里，请重新加入', 403);

        if ((int)$room['v'] !== $since) {
            // 版本已变 -> 重新加锁取一份一致的快照
            $st = room_tx($code, function (&$r2, $file) use ($token) {
                $s = require_seat($r2, $token);
                return snapshot_for($r2, $s);
            });
            ok(['state' => $st]);
        }
        if (microtime(true) >= $deadline) { ok(['wait' => 1]); }
        usleep(POLL_INTERVAL_US);
    }
}

fail('未知 action: ' . $action, 400);
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === realpath(__FILE__)) {
    route();
}
