#!/bin/bash

HOST='127.0.0.1'
USER='user'
PASS='pass'
DB='db'
MYSQL_CMD="mysql -u $USER -p$PASS -h$HOST $DB"
ELST_HOST='127.0.0.1'
CURL=/usr/bin/curl
INDEX='mysql_table'

function update_elastic_to_latest {
  $MYSQL_CMD <<END
INSERT INTO elastic_river_meta (next_index_id)
SELECT MAX(index_id) from mysql_table;
END
}

function get_latest_index_id {
  LATEST_ID=$($MYSQL_CMD -N -B <<END
SELECT next_index_id from elastic_river_meta order by id desc limit 1;
END
)
}

function get_second_latest_index_id {
  SECOND_LATEST_ID=$($MYSQL_CMD -N -B <<END
SELECT next_index_id from elastic_river_meta order by id desc limit 1,1;
END
)
}

function delete_jdbc_river {
  $CURL -XDELETE ${ELST_HOST}:9200/_river/${INDEX}
}

function install_jdbc_river {
  get_latest_index_id
  get_second_latest_index_id
  read -r -d '' _QRY <<EOF
SELECT 
  id as _id, 
  domain, ts
FROM mysql_table
WHERE
  id > ${SECOND_LATEST_ID}
  AND
  id <= ${LATEST_ID}
EOF
  read -r -d '' _DTA <<EOF
{
  "type" : "jdbc",
  "jdbc" : {
      "driver" : "com.mysql.jdbc.Driver",
      "url" : "jdbc:mysql://${HOST}:3306/${DB}",
      "user" : "${USER}",
      "password" : "${PASS}",
      "strategy": "oneshot",
      "sql" : "$(echo ${_QRY})"
  },
  "index" : {
      "index" : "${INDEX}",
      "type" : "mysql_row",
      "bulk_size": 500
  }
}
EOF

  $CURL -XPUT ${ELST_HOST}:9200/_river/${INDEX}/_meta -d "${_DTA}"

}

delete_jdbc_river
update_elastic_to_latest
install_jdbc_river

