#!/bin/sh
set -exu

curl \
    --fail \
    --retry 10 \
    --retry-delay 2 \
    --retry-connrefused \
    -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0", false],"id":1}' \
    https://eth-goerli.g.alchemy.com/v2/R0A--xdegVWOzgm8OF_HQbzhLT4LFpBV

exec op-batcher
