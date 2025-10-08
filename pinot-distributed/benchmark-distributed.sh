#!/bin/bash
export JAVA_OPTS="-Xmx1g -Xms1g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
# Install dependencies & install pinot in pinot-keeper-01
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
echo 0 | sudo update-alternatives --config java

git clone https://github.com/apache/pinot.git
cd pinot
./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
cd ..
nohup ./pinot/build/bin/pinot-admin.sh StartZookeeper > zookeeper.log 2>&1 &
sleep 60
export JAVA_OPTS="-Xmx2g -Xms2g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
nohup ./pinot/build/bin/pinot-admin.sh StartController -zkAddress pinot-keeper-01:2181 > controller.log 2>&1 &
sleep 30
nohup ./pinot/build/bin/pinot-admin.sh StartBroker -zkAddress pinot-keeper-01:2181 > broker.log 2>&1 &

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "pinot-server-01" << EOF
    # Exit immediately if a command exits with a non-zero status
    set -e
    
    # Set JAVA_OPTS based on the same logic as the main script
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational -XX:MaxDirectMemorySize=16384M"
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
    echo 0 | sudo update-alternatives --config java
    
    git clone https://github.com/apache/pinot.git
    cd pinot
    ./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
    cd ..

    nohup ./pinot/build/bin/pinot-admin.sh StartServer -zkAddress pinot-keeper-01:2181 > server.log 2>&1 &
EOF

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "pinot-server-02" << EOF
    # Exit immediately if a command exits with a non-zero status
    set -e
    
    # Set JAVA_OPTS based on the same logic as the main script
    export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational -XX:MaxDirectMemorySize=16384M"
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
    echo 0 | sudo update-alternatives --config java
    
    git clone https://github.com/apache/pinot.git
    cd pinot
    ./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
    cd ..

    nohup ./pinot/build/bin/pinot-admin.sh StartServer -zkAddress pinot-keeper-01:2181 > server.log 2>&1 &
EOF

./pinot/build/bin/pinot-admin.sh AddTable -tableConfigFile offline_table-tuned.json -schemaFile schema-tuned.json -exec

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz

split -d --additional-suffix .tsv -n l/100 hits.tsv parts

sed parts93.tsv -e 's/"tatuirovarki_redmond/tatuirovarki_redmond/g' -i

# Fix path to local directory
sed -i "s|PWD_DIR_PLACEHOLDER|$PWD|g" splitted-distributed.yaml

export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
# Load data
echo -n "Load time: "
command time -f '%e' ./pinot/build/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted-distributed.yaml

# After upload it shows 94465149 rows instead of 99997497 in the dataset

# Run the queries
./run-distributed.sh

echo -n "Data size: "
du -bcs ./batch | grep total