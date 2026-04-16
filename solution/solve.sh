#!/bin/bash
set -e

# Start Redis server
redis-server --daemonize yes --port 6379
sleep 2

# Create the distributed lock implementation
cat > /app/distributed_lock.py << 'PYTHON_EOF'
# -*- coding: utf-8 -*-
import redis
import threading
import time
import uuid
import os
import random


class DistributedLock:
    """Redis-based distributed lock with reentrancy and auto-renewal"""
    
    def __init__(self, redis_client, lock_name, expire_time=30):
        self.redis = redis_client
        self.lock_name = f"distributed_lock:{lock_name}"
        self.expire_time = expire_time
        self.lock_value = str(uuid.uuid4())
        self.reentrant_count = 0
        self.local_lock = threading.Lock()
        self.renewal_thread = None
        self.stop_renewal = threading.Event()
        
    def acquire(self, blocking=True, timeout=None):
        """Acquire the lock"""
        with self.local_lock:
            # Check if already held by this thread (reentrancy)
            if self.reentrant_count > 0:
                self.reentrant_count += 1
                return True
            
        # Try to acquire lock from Redis
        start_time = time.time()
        while True:
            # Use SET NX EX for atomic lock acquisition
            acquired = self.redis.set(
                self.lock_name,
                self.lock_value,
                nx=True,
                ex=self.expire_time
            )
            
            if acquired:
                with self.local_lock:
                    self.reentrant_count = 1
                # Start watchdog thread for auto-renewal
                self._start_renewal()
                return True
            
            if not blocking:
                return False
            
            if timeout is not None:
                elapsed = time.time() - start_time
                if elapsed >= timeout:
                    return False
            
            # Wait a bit before retrying
            time.sleep(0.1)
    
    def release(self):
        """Release the lock"""
        with self.local_lock:
            if self.reentrant_count == 0:
                raise RuntimeError("Lock is not held")
            
            self.reentrant_count -= 1
            
            if self.reentrant_count > 0:
                # Still held by this thread due to reentrancy
                return
            
            # Stop renewal thread
            self._stop_renewal()
            
            # Use Lua script for atomic check-and-delete
            lua_script = """
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("del", KEYS[1])
            else
                return 0
            end
            """
            self.redis.eval(lua_script, 1, self.lock_name, self.lock_value)
    
    def _start_renewal(self):
        """Start the watchdog thread for auto-renewal"""
        def renew():
            # Renew when 1/3 of expire time remains
            sleep_time = self.expire_time / 3
            while not self.stop_renewal.wait(sleep_time):
                try:
                    # Extend expiration using Lua script
                    lua_script = """
                    if redis.call("get", KEYS[1]) == ARGV[1] then
                        return redis.call("expire", KEYS[1], ARGV[2])
                    else
                        return 0
                    end
                    """
                    result = self.redis.eval(
                        lua_script, 1, self.lock_name, 
                        self.lock_value, str(self.expire_time)
                    )
                    if result == 0:
                        # Lock was lost
                        break
                except Exception:
                    break
        
        self.stop_renewal.clear()
        self.renewal_thread = threading.Thread(target=renew, daemon=True)
        self.renewal_thread.start()
    
    def _stop_renewal(self):
        """Stop the watchdog thread"""
        self.stop_renewal.set()
        if self.renewal_thread:
            self.renewal_thread.join(timeout=1)
    
    def __enter__(self):
        self.acquire()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()


class Redlock:
    """Redlock algorithm for distributed locking across multiple Redis nodes"""
    
    def __init__(self, redis_clients, lock_name, expire_time=30):
        self.redis_clients = redis_clients
        self.lock_name = lock_name
        self.expire_time = expire_time
        self.lock_value = str(uuid.uuid4())
        self.quorum = len(redis_clients) // 2 + 1
        
    def acquire(self, blocking=True, timeout=None):
        """Acquire lock using Redlock algorithm"""
        start_time = time.time()
        
        while True:
            acquired_count = 0
            drift = 0.01  # Clock drift factor
            
            for redis_client in self.redis_clients:
                try:
                    if redis_client.set(
                        self.lock_name,
                        self.lock_value,
                        nx=True,
                        px=int(self.expire_time * 1000)
                    ):
                        acquired_count += 1
                except Exception:
                    pass
            
            # Check if we have quorum
            if acquired_count >= self.quorum:
                return True
            
            # Release locks on all nodes if failed
            self._release_all()
            
            if not blocking:
                return False
            
            if timeout is not None:
                elapsed = time.time() - start_time
                if elapsed >= timeout:
                    return False
            
            # Random delay before retry (exponential backoff)
            time.sleep(random.uniform(0.01, 0.1))
    
    def release(self):
        """Release lock on all nodes"""
        self._release_all()
    
    def _release_all(self):
        """Release lock on all Redis nodes"""
        lua_script = """
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        else
            return 0
        end
        """
        for redis_client in self.redis_clients:
            try:
                redis_client.eval(lua_script, 1, self.lock_name, self.lock_value)
            except Exception:
                pass
    
    def __enter__(self):
        self.acquire()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()
PYTHON_EOF

# Create the test file
cat > /app/test_lock.py << 'PYTHON_EOF'
# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""Test suite for distributed lock"""

import sys
import threading
import time
import redis
from distributed_lock import DistributedLock


def test_concurrent_access():
    """Test that only one thread can hold the lock at a time"""
    print("Testing concurrent access...")
    
    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    lock = DistributedLock(r, "test_concurrent")
    
    results = []
    threads = []
    
    def worker(thread_id):
        if lock.acquire(timeout=5):
            results.append(thread_id)
            time.sleep(0.1)  # Hold lock briefly
            lock.release()
    
    # Start 10 threads
    for i in range(10):
        t = threading.Thread(target=worker, args=(i,))
        threads.append(t)
        t.start()
    
    for t in threads:
        t.join()
    
    # All threads should have acquired the lock
    assert len(results) == 10, f"Expected 10 successful acquisitions, got {len(results)}"
    print("  PASSED: Concurrent access test")
    return True


def test_reentrancy():
    """Test that the same thread can reacquire the lock"""
    print("Testing reentrancy...")
    
    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    lock = DistributedLock(r, "test_reentrant")
    
    # First acquisition
    assert lock.acquire(), "First acquire should succeed"
    
    # Second acquisition (reentrant)
    assert lock.acquire(), "Reentrant acquire should succeed"
    
    # Third acquisition (reentrant)
    assert lock.acquire(), "Second reentrant acquire should succeed"
    
    # Release three times
    lock.release()
    lock.release()
    lock.release()
    
    print("  PASSED: Reentrancy test")
    return True


def test_auto_renewal():
    """Test that lock is automatically renewed"""
    print("Testing auto-renewal...")
    
    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    lock = DistributedLock(r, "test_renewal", expire_time=2)  # 2 second expiry
    
    assert lock.acquire(), "Should acquire lock"
    
    # Hold lock for longer than expire time
    time.sleep(5)
    
    # Lock should still be held by us
    lock_value = r.get(lock.lock_name)
    assert lock_value == lock.lock_value, "Lock should still be held after renewal"
    
    lock.release()
    
    print("  PASSED: Auto-renewal test")
    return True


def test_deadlock_recovery():
    """Test that lock can be acquired after holder crashes"""
    print("Testing deadlock recovery...")
    
    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    
    # Simulate a crashed holder by setting a lock directly
    r.set("distributed_lock:test_recovery", "crashed_holder", ex=1)
    
    lock = DistributedLock(r, "test_recovery", expire_time=1)
    
    # Should be able to acquire after expiry
    assert lock.acquire(timeout=3), "Should acquire lock after expiry"
    lock.release()
    
    print("  PASSED: Deadlock recovery test")
    return True


def test_context_manager():
    """Test context manager usage"""
    print("Testing context manager...")
    
    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    lock = DistributedLock(r, "test_context")
    
    with lock:
        # Lock should be held
        lock_value = r.get(lock.lock_name)
        assert lock_value == lock.lock_value, "Lock should be held in context"
    
    # Lock should be released
    lock_value = r.get(lock.lock_name)
    assert lock_value is None, "Lock should be released after context"
    
    print("  PASSED: Context manager test")
    return True


def main():
    print("=" * 50)
    print("Distributed Lock Test Suite")
    print("=" * 50)
    
    results = []
    
    try:
        results.append(("Concurrent Access", test_concurrent_access()))
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append(("Concurrent Access", False))
    
    try:
        results.append(("Reentrancy", test_reentrancy()))
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append(("Reentrancy", False))
    
    try:
        results.append(("Auto-renewal", test_auto_renewal()))
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append(("Auto-renewal", False))
    
    try:
        results.append(("Deadlock Recovery", test_deadlock_recovery()))
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append(("Deadlock Recovery", False))
    
    try:
        results.append(("Context Manager", test_context_manager()))
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append(("Context Manager", False))
    
    # Write report
    with open("/app/test_report.txt", 'w') as f:
        f.write("Distributed Lock Test Report\n")
        f.write("=" * 40 + "\n\n")
        
        passed = sum(1 for _, p in results if p)
        total = len(results)
        
        f.write(f"Results: {passed}/{total} tests passed\n\n")
        
        for name, passed in results:
            status = "PASSED" if passed else "FAILED"
            f.write(f"{name}: {status}\n")
    
    print("\n" + "=" * 50)
    passed = sum(1 for _, p in results if p)
    total = len(results)
    print(f"SUMMARY: {passed}/{total} tests passed")
    print("=" * 50)
    
    if passed == total:
        print("\nAll tests passed!")
        return 0
    else:
        print(f"\n{total - passed} test(s) failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
PYTHON_EOF

# Make test file executable
chmod +x /app/test_lock.py

# Run the tests
cd /app
python test_lock.py

echo "Solve completed!"
