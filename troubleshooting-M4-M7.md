# 踩坑记录（M4 至 M7）

> 本文件承接 `troubleshooting.md`（Day1 至 Day2），记录 M4 DDL 变更、M5 时间点恢复、M6 主从复制、M7 从库故障演练四组实操中遇到的问题。
> 每条按现象、原因、解法、可迁移的认知四段写。

## Day6（2026-10-08）M4 DDL 变更

### 1. `SHOW TABLE STATUS` 的 `Rows` 与 `COUNT(*)` 不一致

**现象**：`SELECT COUNT(*) FROM ddl_test;` 返回 32000，`SHOW TABLE STATUS` 的 `Rows` 显示 31833。

**原因**：`Rows` 是 InnoDB 的采样估算值，与 `information_schema.TABLES.TABLE_ROWS` 同源。InnoDB 不做全表扫描数行，而是从索引树叶子页随机取样（`innodb_stats_persistent_sample_pages` 默认 20），算出每页平均行数后按页数外推。误差来自采样页的行密度不均、统计信息过期、删行留下的空洞。

**解法**：真实行数用 `COUNT(*)`。想让估算值更准执行 `ANALYZE TABLE`，但仍不是精确值。

**可迁移的认知**：InnoDB 的行数类指标一律是估算。同一机制在 `payment` 表行数、`EXPLAIN` 的 `rows`、`SHOW TABLE STATUS` 三处出现。

### 2. `SHOW TABLE STATUS` 没有列数信息

**现象**：原稿称该命令输出含 `Columns` 一项，实测没有。

**原因**：把 `information_schema.COLUMNS` 错记成 `SHOW TABLE STATUS` 的字段。

**解法**：查列数用 `information_schema.COLUMNS`，DDL 前后对比结构用 `SHOW CREATE TABLE`。

**可迁移的认知**：验证 DDL 是否生效只能用 `SHOW CREATE TABLE`。`SHOW TABLE STATUS` 面向运行时状态，不面向结构定义。

### 3. `time mysql -u root -p -e "..."` 测出来的是打字速度

**现象**：三条 `ALTER` 用 `time` 计时，结果均为 2.7 秒左右，而 `user` 与 `sys` 加起来仅 8 毫秒。

**原因**：`-p` 后未跟密码值，客户端停下等手输。`Enter password:` 的等待被算进 `real`，测出的是敲键盘的耗时。

**解法**：用 mysql 客户端内部计时。

```sql
SET profiling = 1;
ALTER TABLE ddl_test ADD COLUMN c2 INT, ALGORITHM=INSTANT;
SHOW PROFILES;
```

**可迁移的认知**：`real` 远大于 `user + sys` 时，先怀疑在等 IO 或等输入，而不是程序算得慢。

### 4. `SHOW PROFILES` 在 8.0 已弃用

**现象**：执行后提示 `'SHOW PROFILES' is deprecated ... Please use Performance Schema instead`。

**解法**：改用 `performance_schema.events_statements_history_long`，`TIMER_WAIT` 单位为皮秒，除以 10 亿得毫秒。当前命令仍可用，warning 不影响结果。

**可迁移的认知**：面试提到 `SHOW PROFILES` 时主动补一句它已弃用，比只答命令名更能体现看过版本变更。

### 5. Navicat 不显示单条语句的服务器端耗时

**现象**：在 Navicat 执行 `ALTER`，结果面板只有「执行成功」与影响行数，无耗时。

**原因**：Navicat 面向结果集与数据编辑，不做单语句性能剖析。

**可迁移的认知**：图形客户端与命令行是分工关系。图形客户端看数据与结构，命令行做计时、批处理、脚本化。

### 6. 误解「不写 ALGORITHM 就没有算法」

**现象**：质疑真实工作中不会写 `ALGORITHM`，为何指定不同算法会有耗时差别。

**原因**：把因果弄反了。耗时差别来自操作本身要碰多少数据，算法是结果的映射。加列天生有 INSTANT 的解法，改类型天生只能 COPY。

**解法**：不写算法时 MySQL 自选，顺序是能改元数据就用 INSTANT，不能就试 INPLACE，都不行才 COPY。

```sql
-- 查实际使用的算法
ALTER TABLE ddl_test ADD COLUMN c3 INT;
SELECT * FROM performance_schema.events_stages_history_long LIMIT 5;
-- 或看 SHOW CREATE TABLE 的变化
```

**可迁移的认知**：生产上写 `ALGORITHM` 的目的是当护栏。真实风险在于不写时，MySQL 可能因条件不满足静默降级成 COPY 锁表，这叫隐式锁表。显式写 `ALGORITHM=INPLACE, LOCK=NONE` 的潜台词是做不到就报错，不要偷偷降级。

**实测数字**（256000 行）：INSTANT 0.0617 秒，COPY 0.9756 秒，INPLACE 0.4095 秒。COPY 是 INSTANT 的约 16 倍。

---

## Day7（2026-10-09）M5 时间点恢复

### 7. `grep "CHANGE REPLICATION SOURCE"` 在备份文件里匹配不上

**现象**：按新语法检索备份文件，无输出。

**原因**：服务端 8.0.26 起为 `CHANGE REPLICATION SOURCE TO`，但 `mysqldump` 输出的仍是旧写法 `CHANGE MASTER TO`。本机 `mysqldump` 输出版本为 10.13 Distrib 8.0.46。

**解法**：用跨版本关键字检索。

```bash
grep -n -i "change" ~/backup/shop_full.sql
```

**可迁移的认知**：服务端语法改了，不代表客户端工具的输出也改了。检索一律用跨版本的稳定关键字。

### 8. `--databases` 写成 `--database` 直接报错

**现象**：`mysqldump: [ERROR] unknown option '--database'.`

**原因**：只有复数形式 `--databases`，语义是后面可跟一个或多个库。

**解法**：带库名限定用 `--databases shop`，备份文件里会含 `CREATE DATABASE`，恢复时自动建库。

**可迁移的认知**：报 `unknown option` 先怀疑单复数与拼写。

### 9. 管道里两个密码提示互相打架

**现象**：`sudo mysqlbinlog ... | mysql -u root -p` 的两个提示挤在同一行，三次密码失败后命令中止，终端输入缓冲被破坏。

**原因**：管道两侧进程同时启动，`sudo` 要系统密码、`mysql -p` 要数据库密码，两个提示从同一终端读输入，互相抢占。

**解法**：拆两步。

```bash
sudo -v
sudo mysqlbinlog 文件 --start-position=N --stop-position=M > /tmp/replay.sql
mysql -u root -p < /tmp/replay.sql
```

拆两步的额外好处是执行前可以先 `grep` 检查区间内有无破坏性语句。

**可迁移的认知**：管道里不要同时出现两个需要交互输入的命令。这是 shell 层面的限制。

### 10. `--base64-output=decode-rows` 的输出不能执行

**现象**：用该参数生成重放脚本，执行静默成功但数据无变化。

**原因**：该参数把 ROW 事件解码成注释，输出里所有数据变更都是 `#` 开头，mysql 当注释忽略。文件只剩 `SET` 与 `BEGIN` / `COMMIT`。

**解法**：找位点用 `--base64-output=decode-rows -v`，重放不加该参数。判断脚本能否执行看 `BINLOG` 不看 `INSERT`。

```bash
# 找位点
sudo mysqlbinlog --base64-output=decode-rows -v /var/lib/mysql/binlog.000007 > /tmp/bt.txt

# 重放
sudo mysqlbinlog /var/lib/mysql/binlog.000007 --start-position=N --stop-position=M > /tmp/replay.sql
grep -c "BINLOG" /tmp/replay.sql   # 预期 > 0
```

**可迁移的认知**：ROW 格式下 binlog 里没有 `INSERT` 这个词，插入写成 `Table_map` 加 `Write_rows` 两个事件。重放的本质是重放二进制，不是重放 SQL 文本。

### 11. `/tmp` 目录在重启后清空

**现象**：之前生成的 `bt.txt` 消失。

**原因**：`/tmp` 是临时目录，系统或 WSL 会话重启后清空。

**解法**：需要跨会话保留的中间产物写到用户目录。

**可迁移的认知**：`/tmp` 只适合放用完即弃的产物。

### 12. 误以为「位点确定后可以从已保存的文件直接恢复」

**现象**：终端崩溃重启后判断位点已定、SQL 都在 `bt.txt` 里，直接取出来执行即可。

**原因**：把两件事合并了。位点确定是对的，数据库仍停在增量重放前，确实不用重做前置步骤；但 `bt.txt` 是带 `###` 注释的可读文本，不是合法 SQL。

**解法**：确认状态后直接从重放那一步接上。

**可迁移的认知**：中断后先确认数据库处于流程的第几步，再决定从哪里接上，判断依据不是「哪些文件生成过」。

**实测数字**：`binlog.000007`，第一遍 1194 至 1631，第二遍 5028 至 5465，均恢复 8 条零丢失。

---

## Day8（2026-10-10）M6 主从复制与 M7 从库故障演练

### 13. 演练步骤顺序错误：设置只读后无法删除脏数据

**现象**：演练 A 第 4 步设置 `super_read_only=ON`，第 5 步要在从库删测试数据，报 `ERROR 1290`。

**原因**：步骤顺序有缺陷，清理动作排在收紧约束之后，被自己刚设的护栏挡住。

**解法**：先关只读、执行清理、再恢复只读。

**可迁移的认知**：设计演练步骤时先排写动作再排锁动作，会收紧权限的操作放在所有需要写入的动作之后。

### 14. 误把从库实例的前台日志当成主库报错

**现象**：在主库执行 `INSERT` 返回 `Query OK`，紧接着同一终端出现 `[ERROR] [MY-010584] [Repl] Replica SQL for channel ''` 报错。

**原因**：从库实例以前台方式启动，日志直接输出到启动它的终端，而执行主库写入的又是同一终端。

**解法**：按行首特征区分。客户端返回带 `Query OK` 或结果集边框，实例日志带 ISO 时间戳与 `[ERROR] [MY-NNNNNN]` 标记。出现 `Replica SQL` 的行属于从库。

**可迁移的认知**：同一终端混着客户端返回与服务端日志时，先看行首特征再下判断。生产服务以 daemon 方式运行，不会有这个问题。

### 15. `STOP REPLICA SQL_THREAD` 与 `SQL_SLAVE_SKIP_COUNTER` 各带一个 warning

**现象**：两条命令都返回 `1 warning`，但操作生效。

**原因**：都是弃用提醒。`SQL_SLAVE_SKIP_COUNTER` 在 8.0 已弃用，官方推荐用 GTID 或静态参数 `replica_skip_errors` 替代。

**解法**：用 `SHOW WARNINGS;` 看内容确认是弃用提醒。

**可迁移的认知**：看到 `1 warning` 不要当成失败。跳过事务会造成不可逆的数据分叉，面试时能说出官方不推荐跳过、建议修数据或重建从库，比只会背命令更完整。

### 16. 从库错误日志里的 `ANONYMOUS` 意味着什么

**现象**：日志写 `failed executing transaction 'ANONYMOUS' at source log binlog.000009, end_log_pos 2482`。

**原因**：`ANONYMOUS` 表示位点复制，事务没有 GTID 编号，只能靠文件名加字节位置定位。

**解法**：要精确到事务的排障用 GTID 复制。GTID 下出错会显示具体编号，不用人工回查 binlog。

**可迁移的认知**：这是 GTID 相对位点复制的实际优势，不只是「更先进」这种空话。

---

## 实测校正汇总

| 模块 | 原稿 | 实测校正 |
|---|---|---|
| M4 | 放大行数 32000 | 改为 256000，拉开算法差距 |
| M4 | shell `time` 计时 | 改为 `SHOW PROFILES` |
| M4 | `SHOW TABLE STATUS` 对比结构 | 改为 `SHOW CREATE TABLE` |
| M5 | grep 关键字 `CHANGE` | 改为 `change` 或 `MASTER_LOG` |
| M5 | 重放未说明参数 | 补「重放不加 `--base64-output`」 |
| M5 | 管道一步执行 | 改为拆两步并加安全检查 |
| M5 | 检查项用 `INSERT` | 改为 `BINLOG` |
| M6 | 从库配置无 `socket` | 补 `socket` 与 `mysqlx=OFF` |
| M7 | 演练 A 步骤顺序 | 清理排在设置只读之前 |
