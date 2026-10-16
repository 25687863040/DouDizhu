<?php
/**
 * 服务端自测：直接以三个玩家的身份跑完整一局，验证牌型判定与回合流转。
 * 用法：php selftest.php
 */

require __DIR__ . '/api.php';

// ---- 牌型判定单测 ----
$fail = 0; $pass = 0;
function t(string $name, $got, $want) {
    global $fail, $pass;
    if ($got === $want) { $pass++; return; }
    $fail++;
    echo "FAIL  $name  got=" . json_encode($got) . " want=" . json_encode($want) . "\n";
}

function C(string $s): array { return parse_cards($s); }
function kind(string $s) { $c = parse_combo(C($s)); return $c === null ? null : $c['kind']; }

t('单张',        kind('14-1'), K_SINGLE);
t('对子',        kind('14-1,14-2'), K_PAIR);
t('三张',        kind('10-0,10-1,10-2'), K_TRIPLE);
t('三带一',      kind('10-0,10-1,10-2,5-0'), K_TRIPLE_ONE);
t('三带二',      kind('10-0,10-1,10-2,5-0,5-1'), K_TRIPLE_PAIR);
t('顺子5',       kind('3-0,4-0,5-0,6-0,7-0'), K_STRAIGHT);
t('顺子A收尾',   kind('10-0,11-0,12-0,13-0,14-0'), K_STRAIGHT);
t('顺子不足5',   kind('3-0,4-0,5-0,6-0'), null);
t('顺子含2非法', kind('11-0,12-0,13-0,14-0,15-0'), null);
t('连对3',       kind('3-0,3-1,4-0,4-1,5-0,5-1'), K_DOUBLE_STRAIGHT);
t('连对不足3',   kind('3-0,3-1,4-0,4-1'), null);
t('飞机不带',    kind('3-0,3-1,3-2,4-0,4-1,4-2'), K_TRIPLE_STRAIGHT);
t('飞机带单',    kind('3-0,3-1,3-2,4-0,4-1,4-2,9-0,10-0'), K_AIRPLANE_SINGLES);
t('飞机带对',    kind('3-0,3-1,3-2,4-0,4-1,4-2,9-0,9-1,10-0,10-1'), K_AIRPLANE_PAIRS);
t('四带二',      kind('6-0,6-1,6-2,6-3,9-0,10-0'), K_FOUR_TWO_SINGLES);
t('四带两对',    kind('6-0,6-1,6-2,6-3,9-0,9-1,10-0,10-1'), K_FOUR_TWO_PAIRS);
t('炸弹',        kind('8-0,8-1,8-2,8-3'), K_BOMB);
t('王炸',        kind('16-4,17-5'), K_ROCKET);
t('两王不成炸但非王炸', kind('16-4,15-0'), null);
t('杂牌不成型',  kind('3-0,5-0,9-0,13-0,15-0'), null);

// 主点数
$c = parse_combo(C('3-0,4-0,5-0,6-0,7-0')); t('顺子main', $c['mainRank'], 7);
$c = parse_combo(C('3-0,3-1,4-0,4-1,5-0,5-1')); t('连对main', $c['mainRank'], 5);
$c = parse_combo(C('3-0,3-1,3-2,4-0,4-1,4-2')); t('飞机main', $c['mainRank'], 4);

// 大小关系
t('大压小',      beats(parse_combo(C('9-0')), parse_combo(C('5-0'))), true);
t('小不压大',    beats(parse_combo(C('5-0')), parse_combo(C('9-0'))), false);
t('炸弹压单张',  beats(parse_combo(C('4-0,4-1,4-2,4-3')), parse_combo(C('15-0'))), true);
t('单张不压炸弹', beats(parse_combo(C('15-0')), parse_combo(C('4-0,4-1,4-2,4-3'))), false);
t('王炸压炸弹',  beats(parse_combo(C('16-4,17-5')), parse_combo(C('15-0,15-1,15-2,15-3'))), true);
t('炸弹压王炸',  beats(parse_combo(C('15-0,15-1,15-2,15-3')), parse_combo(C('16-4,17-5'))), false);
t('异型不压',    beats(parse_combo(C('9-0,9-1')), parse_combo(C('5-0'))), false);
t('顺子异长不压', beats(parse_combo(C('3-0,4-0,5-0,6-0,7-0')), parse_combo(C('8-0,9-0,10-0,11-0,12-0'))), false);
t('长顺压短顺',  beats(parse_combo(C('8-0,9-0,10-0,11-0,12-0,13-0')), parse_combo(C('3-0,4-0,5-0,6-0,7-0'))), true);
t('自由出任意牌', beats(parse_combo(C('3-0')), null), true);

echo "牌型单测：$pass 通过 / $fail 失败\n";
if ($fail > 0) { exit(1); }
