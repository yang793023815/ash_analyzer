#!/bin/bash
#=====================================================================
# make_maps.sh -- 在【源库】(DBID=4216175765) 创建 ash_analyzer 映射表
# 用法: 在源库任意能连 sysdba 的主机上执行  sh make_maps.sh
# 产物: system.t_obj_20260929 / system.t_sqltext_20260929 / system.t_users_20260929
#=====================================================================
export ORACLE_HOME=${ORACLE_HOME:?请先设置 ORACLE_HOME}
export ORACLE_SID=${ORACLE_SID:?请先设置 ORACLE_SID}
sqlplus -S "/ as sysdba" <<'EOF'
whenever sqlerror exit 1
create table system.t_obj_20260929 as
  select object_id, owner, object_name, object_type from dba_objects;

create table system.t_sqltext_20260929 as
  select sql_id, sql_text, sql_fulltext, dbid from dba_hist_sqltext
  where dbid = 4216175765;

create table system.t_users_20260929 as
  select user_id, username from dba_users;

create table system.t_ash_expdir_obj (dummy number);
drop table system.t_ash_expdir_obj purge;
prompt MAP_TABLES_READY
exit
EOF

echo "== 导出三张映射表 =="
expdp \"/ as sysdba\" tables=system.t_obj_20260929,system.t_sqltext_20260929,system.t_users_20260929 \
  directory=DATA_PUMP_DIR dumpfile=maps_20260929.dmp logfile=maps_20260929.log
echo "完成: \$ORACLE_HOME/admin/${ORACLE_SID}/dpdump/maps_20260929.dmp (以实际 directory 路径为准)"
