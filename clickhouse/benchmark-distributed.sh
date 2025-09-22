#!/bin/bash

# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "1S-2R" ] && [ "$1" != "2S-1R" ]; then
    echo "Error: command line argument must be one of {'', '1S-2R', '2S-1R'}"
    exit 1
elif [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi

# Install clickhouse-server on the local host (clickhouse-01)
echo "--- (Local) Step 1: Installing prerequisite packages... ---"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

echo "--- (Local) Step 2: Adding the ClickHouse GPG key... ---"
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

echo "--- (Local) Step 3: Adding the ClickHouse APT repository... ---"
ARCH=$(dpkg --print-architecture)
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list

echo "--- (Local) Step 4: Updating package lists... ---"
sudo apt-get update

echo "--- (Local) Step 5: Installing clickhouse-keeper... ---"
sudo apt-get install -y clickhouse-server clickhouse-client

echo "--- (Local) Installation complete! ---"

sudo cp config-${SUFFIX}/server-01.xml /etc/clickhouse-server/config.xml
sudo cp config-${SUFFIX}/users.xml /etc/clickhouse-server/users.xml

# Install clickhouse-server on the remote host (clickhouse-02)
ssh "clickhouse-02" << 'EOF'
    # Exit immediately if a command exits with a non-zero status
    set -e

    echo "--- (Remote) Step 1: Installing prerequisite packages... ---"
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

    echo "--- (Remote) Step 2: Adding the ClickHouse GPG key... ---"
    curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

    echo "--- (Remote) Step 3: Adding the ClickHouse APT repository... ---"
    ARCH=$(dpkg --print-architecture)
    echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list

    echo "--- (Remote) Step 4: Updating package lists... ---"
    sudo apt-get update

    echo "--- (Remote) Step 5: Installing clickhouse-server... ---"
    sudo apt-get install -y clickhouse-server clickhouse-client

    echo "--- (Remote) Installation complete! ---"
EOF

sudo scp config-${SUFFIX}/server-02.xml "clickhouse-02":/etc/clickhouse-server/config.xml
sudo scp config-${SUFFIX}/users.xml "clickhouse-02":/etc/clickhouse-server/users.xml

# Install clickhouse-keeper on the remote host (clickhouse-keeper-01)
ssh "clickhouse-keeper-01" << 'EOF'
    # Exit immediately if a command exits with a non-zero status
    set -e

    echo "--- (Remote) Step 1: Installing prerequisite packages... ---"
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

    echo "--- (Remote) Step 2: Adding the ClickHouse GPG key... ---"
    curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

    echo "--- (Remote) Step 3: Adding the ClickHouse APT repository... ---"
    ARCH=$(dpkg --print-architecture)
    echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list

    echo "--- (Remote) Step 4: Updating package lists... ---"
    sudo apt-get update

    echo "--- (Remote) Step 5: Installing clickhouse-keeper... ---"
    sudo apt-get install -y clickhouse-keeper

    echo "--- (Remote) Installation complete! ---"
EOF

sudo scp config-${SUFFIX}/keeper-01.xml "clickhouse-keeper-01":/etc/clickhouse-keeper/keeper_config.xml

# Start clickhouse-server on the local host (clickhouse-01)
sudo systemctl start clickhouse-server

# Start clickhouse-server on the remote host (clickhouse-02)
ssh "clickhouse-02" << 'EOF'
    sudo systemctl start clickhouse-server
EOF

# Start clickhouse-keeper on the remote host (clickhouse-keeper-01)
ssh "clickhouse-keeper-01" << 'EOF'
    sudo systemctl start clickhouse-keeper
EOF

for _ in {1..300}
do
    clickhouse-client --query "SELECT 1" && break
    sleep 1
done

# Load the data

clickhouse-client < create-tuned-"$SUFFIX".sql

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
sudo mv hits_*.parquet /var/lib/clickhouse/user_files/
sudo chown clickhouse:clickhouse /var/lib/clickhouse/user_files/hits_*.parquet

echo -n "Load time: "
clickhouse-client --time --query "INSERT INTO hits SELECT * FROM file('hits_*.parquet')" --max-insert-threads $(( $(nproc) / 4 ))

# Run the queries

./run-distributed.sh "$1"

echo -n "Data size: "
clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
