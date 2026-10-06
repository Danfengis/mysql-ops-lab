-- insp.sql：每日巡检脚本
-- 用法一（Linux命令行执行）：mysql -u root -p < ~/mysql-ops-lab/insp.sql
-- 用法二（进Mysql后执行）：SOURCE /home/wang/mysql-ops-lab/insp.sql;
--   SOURCE 后面写绝对路径，mysql 客户端不展开 ~

SELECT NOW() AS 巡检时间, @@hostname AS 主机, VERSION() AS 版本;
-- 抬头：什么时候、在哪台机器、哪个版本上做的巡检

SHOW GLOBAL STATUS LIKE 'Threads_connected';
-- ① 当前连接数（与 max_connections 比，看是否接近上限）

SHOW GLOBAL STATUS LIKE 'Slow_queries';
-- ② 慢查询累计数（与昨天对比看增量）

SHOW GLOBAL STATUS LIKE 'Uptime';
-- ③ 实例存活时长（异常变小说明实例重启过）

SELECT table_schema AS 库名,
       ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 大小MB
FROM information_schema.tables
GROUP BY table_schema
ORDER BY 大小MB DESC
LIMIT 5;
-- ④ 各库大小 TOP5（看增长趋势，做容量规划）

SELECT t.table_schema AS 库名, t.table_name AS 表名
FROM information_schema.tables t
WHERE t.table_schema = 'sakila' AND t.table_type = 'BASE TABLE'
  AND NOT EXISTS (SELECT 1 FROM information_schema.statistics s
                  WHERE s.table_schema = t.table_schema
                    AND s.table_name   = t.table_name
                    AND s.index_name   = 'PRIMARY');
-- ⑤ 无主键表检查（无主键的表在主从复制里回放会变慢）

SELECT id, user, host, db, command, time,
       LEFT(IFNULL(info, ''), 60) AS 语句片段
FROM information_schema.processlist
WHERE command != 'Daemon' AND time > 60
ORDER BY time DESC;
-- ⑥ 长连接与长事务排查（超过 60 秒的连接）

SHOW REPLICA STATUS\G
-- ⑦ 主从状态（未配置主从时返回空集，不报错;）

SELECT ROUND(SUM(data_length) / 1024 / 1024, 1)  AS 数据MB,
       ROUND(SUM(index_length) / 1024 / 1024, 1) AS 索引MB,
       ROUND((SUM(data_length + index_length)) / 1024 / 1024, 1) AS 合计MB
FROM information_schema.tables
WHERE table_schema = 'sakila';
-- ⑧ 数据量与索引量占比（索引占比过高说明存在冗余索引）

