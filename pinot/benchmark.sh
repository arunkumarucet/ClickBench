#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y openjdk-21-jdk jq
sudo update-alternatives --config java

# Install

export JAVA_OPTS="-Xmx16g -Xms16g -XX:+UseG1GC"
# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ]; then
    echo "Error: command line argument must be one of {'', 'tuned'}"
    exit 1
elif [ ! -z "$1" ]; then
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
    SUFFIX="-$1"
fi
git clone https://github.com/apache/pinot.git
cd pinot
./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
cd ..
./pinot/build/bin/pinot-admin.sh QuickStart -type batch &
sleep 60
export JAVA_OPTS="-Xmx1g -Xms1g"
./pinot/build/bin/pinot-admin.sh AddTable -tableConfigFile offline_table"$SUFFIX".json -schemaFile schema"$SUFFIX".json -exec

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz

split -d --additional-suffix .tsv -n l/100 hits.tsv parts

sed parts93.tsv -e 's/"tatuirovarki_redmond/tatuirovarki_redmond/g' -i

# Fix path to local directory
sed -i "s|PWD_DIR_PLACEHOLDER|$PWD|g" splitted.yaml
sed -i "s|PWD_DIR_PLACEHOLDER|$PWD|g" local.yaml

export JAVA_OPTS="-Xmx8g -Xms8g -XX:+UseG1GC"
# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ]; then
    echo "Error: command line argument must be one of {'', 'tuned'}"
    exit 1
elif [ ! -z "$1" ]; then
    export JAVA_OPTS="-Xmx8g -Xms8g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
    SUFFIX="-$1"
fi
# Load data
echo -n "Load time: "
command time -f '%e' ./pinot/build/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted.yaml

# Run the queries
./run.sh

# stop Pinot services
#kill %1

echo -n "Data size: "
du -bcs ./batch | grep total
