#!/bin/bash
set -e

# Start Redis
redis-server /etc/redis/redis.conf --daemonize yes
sleep 2

# Check if required files exist
if [ ! -f "/app/distributed_lock.py" ]; then
    echo "ERROR: /app/distributed_lock.py not found"
    echo "0.0" > /app/reward.txt
    exit 1
fi

if [ ! -f "/app/test_lock.py" ]; then
    echo "ERROR: /app/test_lock.py not found"
    echo "0.0" > /app/reward.txt
    exit 1
fi

# Run tests
cd /app
python test_lock.py || true

# Ensure reward directory exists
mkdir -p /logs/verifier

# Check test report and calculate score
if [ -f "/app/test_report.txt" ]; then
    PASSED=$(grep -c "PASSED" /app/test_report.txt || echo "0")
    TOTAL=$(grep -c "PASSED\|FAILED" /app/test_report.txt || echo "0")
    
    if [ "$TOTAL" -gt 0 ]; then
        SCORE=$(python3 -c "print($PASSED / $TOTAL)")
        echo "$SCORE" > /logs/verifier/reward.txt
        echo "Score: $SCORE ($PASSED/$TOTAL)"
        echo "REWARD: $SCORE"
        
        if [ "$PASSED" -eq "$TOTAL" ]; then
            echo "TEST: PASS"
            exit 0
        else
            echo "TEST: PARTIAL"
            exit 0
        fi
    fi
fi

# If we get here, something went wrong
echo "0.0" > /logs/verifier/reward.txt
echo "REWARD: 0.0"
echo "TEST: FAIL"
exit 1
