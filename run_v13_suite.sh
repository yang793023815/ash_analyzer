#!/bin/bash
#=====================================================================
# run_v13_suite.sh -- ash_analyzer v1.3 全套复盘 (10.10.180.201 / panjf1)
# 分析对象: WFY.M_ASH_20260929 (源库 DBID=4216175765, 6 实例 RAC)
# 用法: su - oracle 后执行; 已配映射表时末尾三条自动启用
#=====================================================================
A=/home/oracle/ash_analyzer/ash_analyzer
W1="-i WFY.M_ASH_20260929 -s panjf1"
T_PEAK="-t '2026-09-29 17:20:00' -T '2026-09-29 17:45:00'"
T_BASE="-t '2026-09-29 15:00:00' -T '2026-09-29 15:30:00'"
T_RISE="-t '2026-09-29 16:45:00' -T '2026-09-29 17:15:00'"

echo "########## 1. info (全表体检) ##########"
$A info $W1

echo "########## 2. trend (15:00-18:00) ##########"
$A trend $W1 -t "2026-09-29 15:00:00" -T "2026-09-29 18:00:00" -n 20

echo "########## 3. events 峰值窗口 ##########"
$A events $W1 $T_PEAK -n 20

echo "########## 4. sql 峰值窗口 (长执行) ##########"
$A sql $W1 $T_PEAK -n 20

echo "########## 5. blockers 峰值窗口 (根阻塞者) ##########"
$A blockers $W1 $T_PEAK -n 15 -p 4

echo "########## 6. chain 核心窗口 (17:25-17:28) ##########"
$A chain $W1 -t "2026-09-29 17:25:00" -T "2026-09-29 17:28:00" -p 4

echo "########## 7. detail 关键持有者 ##########"
$A detail $W1 -S 5593  $T_PEAK
$A detail $W1 -S 10501 $T_PEAK

echo "########## 8. 映射表版本 (配好映射表后解开注释) ##########"
# $A obj      $W1 -objmap  system.t_obj_20260929   $T_PEAK -n 15
# $A text -q 9yk0xbwxru5d3 -sqlmap system.t_sqltext_20260929
# $A sessions $W1 -usermap system.t_users_20260929 $T_PEAK -n 12
echo "done."
