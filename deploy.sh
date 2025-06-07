#!/bin/bash
set -e
# on 147.182.233.57

echo "running pre-deploy builder.cr..."
crystal run builder.cr
echo "finished running predeploy"

# from https://crystal-lang.org/reference/1.4/guides/static_linking.html
echo "starting to build static binary..."

docker run --rm -it -v $(pwd):/workspace -w /workspace crystallang/crystal:latest-alpine  \
  crystal build server.cr --static
echo "finished building static binary"

echo "copying binary to server..."
# builds a "server" binary, now copy it to the server & run it
scp ./server tweet6:/var/www/tweet6/next_server_binary
echo "finished copying binary to server"

echo "restarting"
ssh -A tweet6 "bash -l /var/www/tweet6/restart.sh"
echo "finished restarting"
