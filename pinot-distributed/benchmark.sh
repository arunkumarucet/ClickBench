#!/bin/bash

# Install dependencies & install pinot in pinot-keeper-01
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq unzip
echo 0 | sudo update-alternatives --config java

# Build and install Pinot
git clone https://github.com/apache/pinot.git
cd pinot
./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
cd ..

# Start Zookeeper
export JAVA_OPTS="-Xmx1g -Xms1g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
nohup ./pinot/build/bin/pinot-admin.sh StartZookeeper > zookeeper.log 2>&1 &
sleep 60

# Start Controller
export JAVA_OPTS="-Xmx2g -Xms2g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
nohup ./pinot/build/bin/pinot-admin.sh StartController -zkAddress pinot-keeper-01:2181 > controller.log 2>&1 &
sleep 30

# Start Broker
export JAVA_OPTS="-Xmx2g -Xms2g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
nohup ./pinot/build/bin/pinot-admin.sh StartBroker -zkAddress pinot-keeper-01:2181 > broker.log 2>&1 &

# Start Server on pinot-server-01
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "pinot-server-01" << EOF
    # Exit immediately if a command exits with a non-zero status
    set -e
    
    # Set JAVA_OPTS based on the same logic as the main script. Adjust based on machine size
    export JAVA_OPTS="-Xmx32g -Xms32g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
    
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
    
    # Set JAVA_OPTS based on the same logic as the main script. Adjust based on machine size
    export JAVA_OPTS="-Xmx32g -Xms32g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk jq
    echo 0 | sudo update-alternatives --config java
    
    git clone https://github.com/apache/pinot.git
    cd pinot
    ./mvnw clean install -DskipTests -Pbin-dist -Pbuild-shaded-jar
    cd ..

    nohup ./pinot/build/bin/pinot-admin.sh StartServer -zkAddress pinot-keeper-01:2181 > server.log 2>&1 &
EOF

# Add table
./pinot/build/bin/pinot-admin.sh AddTable -tableConfigFile offline_table-tuned.json -schemaFile schema-tuned.json -exec

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Install DuckDB to convert binary to string and merge parquet files
curl -L -o duckdb.zip https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip
unzip -o duckdb.zip && chmod +x duckdb

mkdir -p duck_temp

parts=30 # Adjust/Increase based on machine size if available memory is low
rows_total=$(./duckdb -csv -c "SELECT count(*) FROM read_parquet('hits_*.parquet');" | tail -n1)
rows_per_part=$(( (rows_total + parts - 1) / parts ))

for i in $(seq 0 $((parts-1))); do
  offset=$(( i * rows_per_part ))
  ./duckdb -c "PRAGMA memory_limit='6GB'; PRAGMA threads=8; PRAGMA temp_directory='duck_temp';
    COPY (
      SELECT
        * REPLACE (
          CAST(URL AS VARCHAR)                AS URL,
          CAST(Title AS VARCHAR)              AS Title,
          CAST(Referer AS VARCHAR)            AS Referer,
          CAST(SearchPhrase AS VARCHAR)       AS SearchPhrase,
          CAST(UserAgentMinor AS VARCHAR)     AS UserAgentMinor,
          CAST(MobilePhoneModel AS VARCHAR)   AS MobilePhoneModel,
          CAST(Params AS VARCHAR)             AS Params,
          CAST(PageCharset AS VARCHAR)        AS PageCharset,
          CAST(BrowserLanguage AS VARCHAR)    AS BrowserLanguage,
          CAST(BrowserCountry AS VARCHAR)     AS BrowserCountry,
          CAST(SocialNetwork AS VARCHAR)      AS SocialNetwork,
          CAST(SocialAction AS VARCHAR)       AS SocialAction,
          CAST(OriginalURL AS VARCHAR)        AS OriginalURL,
          CAST(HitColor AS VARCHAR)           AS HitColor,
          CAST(SocialSourcePage AS VARCHAR)   AS SocialSourcePage,
          CAST(ParamOrderID AS VARCHAR)       AS ParamOrderID,
          CAST(ParamCurrency AS VARCHAR)      AS ParamCurrency,
          CAST(OpenstatServiceName AS VARCHAR) AS OpenstatServiceName,
          CAST(OpenstatCampaignID AS VARCHAR)  AS OpenstatCampaignID,
          CAST(OpenstatAdID AS VARCHAR)        AS OpenstatAdID,
          CAST(OpenstatSourceID AS VARCHAR)    AS OpenstatSourceID,
          CAST(UTMSource AS VARCHAR)          AS UTMSource,
          CAST(UTMMedium AS VARCHAR)          AS UTMMedium,
          CAST(UTMCampaign AS VARCHAR)        AS UTMCampaign,
          CAST(UTMContent AS VARCHAR)         AS UTMContent,
          CAST(UTMTerm AS VARCHAR)            AS UTMTerm,
          CAST(FromTag AS VARCHAR)            AS FromTag,
          CAST(FlashMinor2 AS VARCHAR)        AS FlashMinor2
        )
      FROM read_parquet('hits_*.parquet')
      LIMIT $rows_per_part OFFSET $offset
    ) TO 'part_hits-$i.parquet' (FORMAT PARQUET);"
done

# Fix path to local directory
sed -i "s|PWD_DIR_PLACEHOLDER|$PWD|g" splitted.yaml

# Load data
export JAVA_OPTS="-Xmx16g -Xms16g -XX:-UseG1GC -XX:+UseZGC -XX:+ZGenerational"
echo -n "Load time: "
command time -f '%e' ./pinot/build/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted.yaml

# Run the queries
./run.sh

echo -n "Data size: "
du -bcs ./batch | grep total