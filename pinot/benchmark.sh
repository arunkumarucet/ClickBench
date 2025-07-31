#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y openjdk-21-jdk jq
sudo update-alternatives --config java

# Install

PINOT_VERSION=1.3.0

wget --continue --progress=dot:giga https://downloads.apache.org/pinot/apache-pinot-$PINOT_VERSION/apache-pinot-$PINOT_VERSION-bin.tar.gz
tar -zxvf apache-pinot-$PINOT_VERSION-bin.tar.gz
export JAVA_OPTS="-Xmx16g -Xms16g -XX:+UseG1GC -XX:MaxDirectMemorySize=16384M"
# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ]; then
    echo "Error: command line argument must be one of {'', 'tuned'}"
    exit 1
elif [ ! -z "$1" ]; then
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational -XX:MaxDirectMemorySize=16384M"
    SUFFIX="-$1"
fi
./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh QuickStart -type batch &
sleep 30
./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh AddTable -tableConfigFile offline_table"$SUFFIX".json -schemaFile schema"$SUFFIX".json -exec

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz

# Since the uncompressed hits.tsv size is ~75GB, heap size is not sufficient to handle this. Hence, we have to split the data
echo -n "File Split time: "
command time -f '%e' split -d --additional-suffix .tsv -n l/100 hits.tsv parts

# Pinot can't load value '"tatuirovarki_redmond' so we need to fix this row to make it work
echo -n "File Cleanup time: "
command time -f '%e' sed parts93.tsv -e 's/"tatuirovarki_redmond/tatuirovarki_redmond/g' -i

# Fix path to local directory
sed splitted.yaml 's/PWD_DIR_PLACEHOLDER/'$PWD'/g' -i
sed local.yaml 's/PWD_DIR_PLACEHOLDER/'$PWD'/g' -i

# Load data
echo -n "Load time: "
command time -f '%e' ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted.yaml

# After upload it shows 94465149 rows instead of 99997497 in the dataset

# Run the queries
./run.sh

# stop Pinot services
kill %1

echo -n "Data size: "
du -bcs ./batch | grep total
