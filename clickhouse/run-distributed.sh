#!/bin/bash

# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "1S-2R" ] && [ "$1" != "2S-1R" ]; then
    echo "Error: command line argument must be one of {'', '1S-2R', '2S-1R'}"
    exit 1
elif [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi

TRIES=3
QUERY_NUM=1
cat queries-tuned-"$SUFFIX".sql | while read -r query; do
    [ -z "$FQDN" ] && sync
    [ -z "$FQDN" ] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null --query="$query" --progress 0 2>&1 ||:)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
