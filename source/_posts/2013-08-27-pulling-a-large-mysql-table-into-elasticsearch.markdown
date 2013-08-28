---
layout: post
title: "Pulling a Large MySQL Table into elasticsearch"
date: 2013-08-27 23:47
comments: true
categories:
  - elasticsearch
  - MySQL
---

If you need to perform realtime queries against a huge MySQL table, but are no longer able to due to 
the size of the table, read on to find out how to make elasticsearch do the heavy lifting for you!  

This solution includes the ability to perform regular updates to elasticsearch of new data that gets pushed
to the table in MySQL.

<!-- more -->

## Requirements

  * A MySQL table with an AUTO\_INCREMENT primary key which receives only INSERTs
  * A running elasticsearch cluster
  * The [Elasticsearch JDBC River](https://github.com/jprante/elasticsearch-river-jdbc) plugin installed 

## Why not use the [simple](https://github.com/jprante/elasticsearch-river-jdbc/wiki/Strategies) or [table](https://github.com/jprante/elasticsearch-river-jdbc/wiki/Strategies) strategy?

For the [simple](https://github.com/jprante/elasticsearch-river-jdbc/wiki/Strategies) strategy, you need an 
immutable SQL Statement to poll data.  Choosing a query that can survive downtime but preserve recent data
is all but impossible to guarantee.

Does this make sense using a one hour polling period, assuming that we want to keep the index current to within
the last hour?

```
SELECT id AS _id, domain, ts FROM mysql_table WHERE ts >= DATE_SUB(NOW(), INTERVAL 1 HOUR); 
```

As long as we are telling elasticsearch that the primary key is the _id field, elasticsearch will only 
update existing entries from the last run, so no issues there.

This, though, is a huge waste of resources and provides no reliability.  If a poll fails for whatever reason, 
data is more than likely lost if the time since last poll is greater than one hour (or more if the INTERVAL is
increased).  There is no way to recover the lost data without repopulating the river from a known point by
replacing the river with a oneshot strategy query and then restoring the original river.

For the [table](https://github.com/jprante/elasticsearch-river-jdbc/wiki/Strategies) strategy, you have to alter
the table to add new columns for tracking.   For most production environments, this is a non-option.

## Get on with it!

So, considering the above issues, I decided to use the oneshot strategy.

### The Tracking Table

I used a table in MySQL to track each run of new data into elasticsearch.  As you'll see later, I use
this table to determine the start and stop key of each oneshot run of data.  This is the schema I used:

```
CREATE TABLE `elastic_river_meta`
  ( `id` NOT NULL AUTO_INCREMENT,
    `next_index_id` bigint(20) NOT NULL,
    `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`) );
```

### Creating the Mapping for the elasticsearch Index

Before we get into starting the river, first lets generate a sensible mapping for table.  You can skip this
and the plugin will sensibly determine the defaults for you.  I found, though, that there were subtle 
changes I needed to make to run terms facet queries against string fields which required reindexing.

Assuming that the `domain` column in the SELECT example above is a domain name, I want to both index the
field for keywords using the standard token analyzer (which will tokenize on the '.'s in the domain name) and
I want the entire domain name to be indexed as a single keyword.  Doing so requires a
[Multi Field](http://www.elasticsearch.org/guide/reference/mapping/multi-field-type/) type in the mapping.

```
curl -XPOST http://localhost:9200/mysql_table -d '
{
  "mappings" : {
    "mysql_row": {
      "properties" : {
        "domain" : {
          "type" : "multi_field",
          "fields" : {
            "domain" : {
              "type" : "string",
              "index" : "analyzed"
            },
            "exact" : {
              "type" : "string",
              "index" : "not_analyzed"
            }
          }
        },
        "sent_date" : {
          "type" : "date",
          "format" : "dateOptionalTime"
        }
      }
    }
  }
}'
```

### Preloading the meta table to specify the start point and end point for the first run

Let's go ahead and put an entry in the `elastic_river_meta` table to specify the starting and ending
point for the initial run.  This would run for a while, depending on how much data you have.

```
INSERT INTO `elastic_river_meta` SET `next_index_id` = 0;
INSERT INTO `elastic_river_meta` SELECT MAX(id) from `mysql_table`;
```

### Loading the existing data into elasticsearch

Now we can yank everything within the `id`'s populated in the `elastic_river_meta` table with
our first run of the oneshot strategy.

If you're not sure everything is going to work, or you want to do some testing, just lower the
value of the second row you populated in the `elastic_river_meta` table.  
        
This is the query we'll be running against MySQL:

```
select id as _id, 
       domain, 
       ts 
from mysql_table 
where 
  id > (select next_index_id 
        from elastic_river_meta
        order by id desc limit 1,1) 
  and 
  id <= (select next_index_id 
         from elastic_river_meta 
         order by id desc limit 1);
```

And this is the command that will run it.

```
/usr/bin/curl -XPUT 'localhost:9200/_river/mysql_table/_meta' -d '{
    "type" : "jdbc",
    "jdbc" : {
        "driver" : "com.mysql.jdbc.Driver",
        "url" : "jdbc:mysql://<host>:3306/<DB>",
        "user" : "<user>",
        "password" : "<password>",
        "strategy": "oneshot",
        "sql" : "select id as _id, domain, ts from mysql_table where id > (select next_index_id from elastic_river_meta order by id desc limit 1,1) and id <= (select next_index_id from elastic_river_meta order by id desc limit 1);"
    },
    "index" : {
        "index" : "mysql_table",
        "type" : "mysql_row",
        "bulk_size": 500
    }
}' 
```

Watch the log to keep an eye on when this finishes.

### Ok, my data is loaded and [looks](http://three.kibana.org) OK!

Now that the prepwork is finished, here is a script that will:

  * insert a new `MAX(id)` into the `elastic_river_meta` table
  * remove the existing river
  * add a new river with updated params for the ID range

{% include_code update_index_to_latest.sh %}

You can run that script as an executable as much as you want, and 
it will always pull the latest data.

### Put it in a cronjob

All that is left to do now is run this script in a cronjob.  Here
is an example that runs it every hour:

```
00 *    * * *   root    /home/user/update_index_to_latest.sh > /dev/null 2>&1
```

## Still missing

I don't want to perform an update if the current jdbc river is still pulling data,
but there is no way of getting this information from elasticsearch.  As such, the
best way I see to do this is by Running a query against elasticsearch to see if the 
`LATEST\_ID`  exists in elasticsearch before performing an update.

My script also doesn't check if there is actually any new data.  The consequences
of this are minimal, insofar that what the query ends up returning is one row of
the most recent id.  Regardless, I would like to add this check.


