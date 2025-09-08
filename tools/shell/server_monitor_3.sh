#!/bin/bash

# Set log file
log_file="server_stats_3.log"

# Function to handle signals (like Ctrl+C)
function cleanup {
  echo "Stopping server resource monitoring..."
  exit 0
}

# Trap signals like SIGINT and SIGTERM
trap cleanup SIGINT SIGTERM

while true
do
  cpu_line=$(top -bn1 | grep "Cpu(s)")
  load_avg=$(cat /proc/loadavg | awk '{print $1}')
  mem_usage=$(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2 }')

  user=$(echo "$cpu_line" | awk '{print $2}')
  system=$(echo "$cpu_line" | awk '{print $4}')
  iowait=$(echo "$cpu_line" | awk '{print $10}')
  idle=$(echo "$cpu_line" | awk '{print $8}')

  cpu_total=$(echo "scale=2; 100 - $idle" | bc)

  echo "$(date) | CPU: ${cpu_total}% (User: ${user}%, System: ${system}%, I/O Wait: ${iowait}%) | Load Avg: ${load_avg} | Mem: ${mem_usage}" >> $log_file

  sleep 1
done

