#!/bin/bash
export JAVA_OPTS="-Xmx8g -Xms8g -XX:+UseG1GC"
# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ]; then
    echo "Error: command line argument must be one of {'', 'tuned'}"
    exit 1
elif [ ! -z "$1" ]; then
    export JAVA_OPTS="-Xmx8g -Xms8g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
    SUFFIX="-$1"
fi
PINOT_VERSION=1.3.0

# Install dependencies & install pinot in pinot-keeper-01
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
echo 0 | sudo update-alternatives --config java

wget --continue --progress=dot:giga https://downloads.apache.org/pinot/apache-pinot-$PINOT_VERSION/apache-pinot-$PINOT_VERSION-bin.tar.gz
tar -zxvf apache-pinot-$PINOT_VERSION-bin.tar.gz

nohup ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh StartZookeeper > zookeeper.log 2>&1 &
sleep 60
nohup ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh StartController -zkAddress pinot-keeper-01:2181 > controller.log 2>&1 &
sleep 30
nohup ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh StartBroker -zkAddress pinot-keeper-01:2181 > broker.log 2>&1 &

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "pinot-server-01" << EOF
    # Exit immediately if a command exits with a non-zero status
    set -e
    
    # Set JAVA_OPTS based on the same logic as the main script
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:+UseG1GC -XX:MaxDirectMemorySize=16384M"
    if [ "$1" != "" ] && [ "$1" = "tuned" ]; then
        export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational -XX:MaxDirectMemorySize=16384M"
    fi
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
    echo 0 | sudo update-alternatives --config java
    
    wget --continue --progress=dot:giga https://downloads.apache.org/pinot/apache-pinot-$PINOT_VERSION/apache-pinot-$PINOT_VERSION-bin.tar.gz
    tar -zxvf apache-pinot-$PINOT_VERSION-bin.tar.gz

    nohup ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh StartServer -zkAddress pinot-keeper-01:2181 > server.log 2>&1 &
EOF

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "pinot-server-02" << EOF
    # Exit immediately if a command exits with a non-zero status
    set -e
    
    # Set JAVA_OPTS based on the same logic as the main script
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:+UseG1GC -XX:MaxDirectMemorySize=16384M"
    if [ "$1" != "" ] && [ "$1" = "tuned" ]; then
        export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational -XX:MaxDirectMemorySize=16384M"
    fi
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
    echo 0 | sudo update-alternatives --config java
    
    wget --continue --progress=dot:giga https://downloads.apache.org/pinot/apache-pinot-$PINOT_VERSION/apache-pinot-$PINOT_VERSION-bin.tar.gz
    tar -zxvf apache-pinot-$PINOT_VERSION-bin.tar.gz

    nohup ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh StartServer -zkAddress pinot-keeper-01:2181 > server.log 2>&1 &
EOF

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
sed -i "s|PWD_DIR_PLACEHOLDER|$PWD|g" splitted-distributed.yaml

# Load data
echo -n "Load time: "
command time -f '%e' ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted-distributed.yaml

# After upload it shows 94465149 rows instead of 99997497 in the dataset

# Run the queries
./run-distributed.sh

echo -n "Data size: "
du -bcs ./batch | grep total