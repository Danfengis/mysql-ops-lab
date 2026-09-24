## Day1 环境搭建
- payment行数差异：COUNT(*) = 16044，information_schema.table_rows = 16086;
> 原因：在InnoDB引擎下，information_schema.tables.table_rows是来自InnoDB的统计信息，它随机采样若干索引页，按照索引页数等比放大而得到的结果，由于每页的行数取决于存储数据的长度，页内行数是不均匀的，所以这个结果只能是一个近似值，不是精确值。甚至重新ANALYZE一下表，再次抽样又会分析出不同的结果；而COUNT(*)会进行扫表，得到的永远是精确值；
