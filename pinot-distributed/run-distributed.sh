#!/bin/bash

TRIES=3
while IFS= read -r query || [ -n "$query" ]; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    echo -n "["
    for i in $(seq 1 $TRIES); do
        jq -n --arg sql "$query" --arg opts "timeoutMs=300000" '{"sql": $sql, "queryOptions": $opts}' > query.json
        RES=$(curl -s -XPOST -H'Content-Type: application/json' http://pinot-keeper-01:8099/query/sql/ -d @query.json | jq 'if .exceptions == [] then .timeUsedMs/1000 else "-" end' )
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
done < queries.sql
