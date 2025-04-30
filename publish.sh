#!/bin/bash


## agent framework

agent=$(mktemp -d)

cp -r ./crates/blitzagent/* "$agent"/.
cp -r LICENSE "$agent"/.

cd $denk && cargo publish

## blitzdenk chat

denk=$(mktemp -d)

cp -r ./crates/blitzdenk/* "$denk"/.
cp -r LICENSE README.md "$denk"/.

version=$(grep "^version" ./crates/blitzagent/Cargo.toml | sed 's/version = "\(.*\)"/\1/')
sed -i '/^blitzagent/c\blitzagent="'${version}'"' "$denk"/Cargo.toml

cd $denk && cargo publish

## cleanup

rm -rf $agent
rm -rf $denk
