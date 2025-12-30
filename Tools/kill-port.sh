#!/bin/bash
# Kill processes using a specific port
# Usage: ./kill-port.sh <port>

if [ -z "$1" ]; then
    echo "Usage: $0 <port>"
    echo "Example: $0 8080"
    exit 1
fi

PORT=$1
PIDS=$(lsof -ti:$PORT 2>/dev/null)

if [ -z "$PIDS" ]; then
    echo "No processes found using port $PORT"
    exit 0
fi

echo "Found processes using port $PORT:"
ps -p $PIDS -o pid,command

read -p "Kill these processes? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kill -9 $PIDS 2>/dev/null
    echo "Processes terminated"
else
    echo "Cancelled"
fi
